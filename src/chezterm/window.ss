;;; Wayland window: connection, globals, xdg-shell toplevel, shm buffers,
;;; input devices, clipboard / primary selection and pointer cursors.
;;;
;;; Events are delivered to the application through a single procedure
;;; (sink type arg ...), with these types:
;;;   configure width height      new logical size (0 = choose)
;;;   close                       the compositor asked us to close
;;;   scale n                     integer output scale changed
;;;   focus bool held             keyboard focus; HELD lists the evdev keycodes
;;;                               held when it arrives ('() when it leaves)
;;;   key-press key-event keycode  (key-event #f while composing)
;;;   key-release keycode key-event
;;;   modifiers                   the keyboard's modifiers changed
;;;   pointer-enter x y / pointer-leave / pointer-motion x y
;;;   pointer-button button pressed?
;;;   scroll axis amount discrete?   (axis 0 vertical, 1 horizontal)
;;;   paste which text tag        clipboard data arrived (TEXT #f: there is
;;;                               none), for a request with TAG
;;;   frame                       the compositor is ready for a new frame
(library (chezterm window)
  (export open-window window? window-display-fd window-flush! window-dispatch!
          window-prepare-read! window-read-events! window-cancel-read!
          window-present! window-can-present? window-configured?
          window-set-title! window-set-cursor! window-hide-cursor! window-toggle-fullscreen!
          window-set-clipboard! window-request-paste! window-poll-fds window-fd-ready!
          window-keyboard window-repeat-rate window-repeat-delay window-scale
          window-width window-height window-owns-selection? window-set-min-size!
          window-set-urgent! window-close!)
  (import (chezscheme) (chezterm ffi) (chezterm cutil) (chezterm wayland)
          (chezterm protocols) (chezterm keyboard))

  ;; STALE lists the (y0 . y1) row ranges where the buffer differs from the
  ;; renderer's image, or is 'all for a buffer that was never filled.
  (define-record-type shm-buffer
    (fields proxy data size width height (mutable busy) (mutable stale)))

  (define-record-type window
    (fields display sink
            (mutable globals)            ; alist iface-name -> proxy
            (mutable outputs)            ; alist proxy -> scale
            (mutable surface-outputs)    ; outputs the surface is on
            (mutable surface) (mutable xdg-surface) (mutable toplevel) (mutable decoration)
            (mutable configured) (mutable pending-size) (mutable width) (mutable height)
            (mutable scale) (mutable preferred-scale)
            (mutable frame-pending)
            (mutable buffers)
            (mutable fullscreen)
            (mutable seat) (mutable keyboard-proxy) (mutable pointer)
            (mutable keyboard)
            (mutable repeat-rate) (mutable repeat-delay)
            (mutable serial)             ; latest input serial
            (mutable pointer-serial)
            (mutable cursor-shape-device) (mutable cursor-theme) (mutable cursor-surface)
            (mutable cursor-name)
            (mutable cursor-hidden)      ; the pointer is hidden (window-hide-cursor!)
            (mutable axis-discrete)      ; accumulated wheel steps for the frame
            (mutable axis-value) (mutable axis-source)
            (mutable data-device) (mutable primary-device)
            (mutable clipboard-offer) (mutable primary-offer)
            (mutable offer-mimes)        ; offer proxy -> list of mime types
            (mutable clipboard-source) (mutable primary-source)
            (mutable clipboard-text) (mutable primary-text)
            (mutable reads)              ; list of #(fd which bytes tag)
            (mutable urgency-token)      ; the pending activation token (window-set-urgent!)
            app-id title))

  (define (global w name) (let ([e (assoc name (window-globals w))]) (and e (cdr e))))

  (define (emit w . args) (apply (window-sink w) args))

  ;;; Setup ----------------------------------------------------------------------

  (define (open-window sink title app-id width height decorations?)
    (let ([d (wl_display_connect #f)])
      (when (ptr-null? d)
        (error 'chezterm "cannot connect to a Wayland display (is WAYLAND_DISPLAY set?)"))
      (let ([w (make-window d sink '() '() '() #f #f #f #f #f #f width height 1 #f #f '() #f
                            #f #f #f (make-keyboard) 25 600 0 0 #f #f #f #f #f
                            0 0.0 #f #f #f #f #f (make-eqv-hashtable) #f #f #f #f '() #f
                            app-id title)])
        (let ([reg (wl_display_get_registry d)])
          (wl-listen! reg wl_registry
            (lambda (ev . args)
              (case ev
                [(global) (apply bind-global! w reg args)]
                [else (void)])))
          (wl_display_roundtrip d)
          (wl-check-callback-error!)
          (for-each (lambda (need)
                      (unless (global w need)
                        (errorf 'chezterm "compositor lacks required interface ~a" need)))
                    '("wl_compositor" "wl_shm" "xdg_wm_base"))
          (create-surface! w decorations?)
          ;; second roundtrip: seat capabilities, output scales
          (wl_display_roundtrip d)
          (wl-check-callback-error!)
          w))))

  (define (bind-global! w reg name iface version)
    (define (bind interface max-version)
      (let ([p (wl_registry_bind reg name interface (min version max-version))])
        (window-globals-set! w (cons (cons iface p) (window-globals w)))
        p))
    (cond
      [(string=? iface "wl_compositor") (bind wl_compositor 6)]
      [(string=? iface "wl_shm") (bind wl_shm 1)]
      [(string=? iface "xdg_wm_base")
       (let ([p (bind xdg_wm_base 5)])
         (wl-listen! p xdg_wm_base
           (lambda (ev serial) (when (eq? ev 'ping) (xdg_wm_base_pong p serial)))))]
      [(and (string=? iface "wl_seat") (not (global w "wl_seat")))
       (let ([p (bind wl_seat 7)])
         (window-seat-set! w p)
         (wl-listen! p wl_seat
           (lambda (ev . args)
             (when (eq? ev 'capabilities) (seat-capabilities! w (car args))))))]
      [(string=? iface "wl_output")
       (let ([p (wl_registry_bind reg name wl_output (min version 4))])
         (window-outputs-set! w (cons (cons p 1) (window-outputs w)))
         (wl-listen! p wl_output
           (lambda (ev . args)
             (when (eq? ev 'scale)
               (let ([e (assv p (window-outputs w))])
                 (when e (set-cdr! e (car args))))
               (update-scale! w)))))]
      [(string=? iface "wl_data_device_manager") (bind wl_data_device_manager 3)]
      [(string=? iface "zwp_primary_selection_device_manager_v1")
       (bind zwp_primary_selection_device_manager_v1 1)]
      [(string=? iface "zxdg_decoration_manager_v1") (bind zxdg_decoration_manager_v1 1)]
      [(string=? iface "wp_cursor_shape_manager_v1") (bind wp_cursor_shape_manager_v1 1)]
      [(string=? iface "xdg_activation_v1") (bind xdg_activation_v1 1)]
      [else (void)]))

  (define (create-surface! w decorations?)
    (let* ([surface (wl_compositor_create_surface (global w "wl_compositor"))]
           [xs (xdg_wm_base_get_xdg_surface (global w "xdg_wm_base") surface)]
           [top (xdg_surface_get_toplevel xs)])
      (window-surface-set! w surface)
      (window-xdg-surface-set! w xs)
      (window-toplevel-set! w top)
      (wl-listen! surface wl_surface
        (lambda (ev . args)
          (case ev
            [(enter) (window-surface-outputs-set! w (cons (car args) (window-surface-outputs w)))
                     (update-scale! w)]
            [(leave) (window-surface-outputs-set! w (remv (car args) (window-surface-outputs w)))
                     (update-scale! w)]
            [(preferred_buffer_scale) (window-preferred-scale-set! w (car args)) (update-scale! w)]
            [else (void)])))
      (wl-listen! xs xdg_surface
        (lambda (ev serial)
          (when (eq? ev 'configure)
            (xdg_surface_ack_configure xs serial)
            (let ([size (window-pending-size w)])
              (window-configured-set! w #t)
              (emit w 'configure (car size) (cdr size))))))
      (wl-listen! top xdg_toplevel
        (lambda (ev . args)
          (case ev
            [(configure)
             (let ([states (let loop ([bv (caddr args)] [i 0] [acc '()])
                             (if (>= i (bytevector-length bv))
                                 acc
                                 (loop bv (+ i 4) (cons (bytevector-u32-native-ref bv i) acc))))])
               (window-fullscreen-set! w (and (memv XDG_TOPLEVEL_STATE_FULLSCREEN states) #t))
               (window-pending-size-set! w (cons (car args) (cadr args))))]
            [(close) (emit w 'close)]
            [else (void)])))
      (xdg_toplevel_set_title top (window-title w))
      (xdg_toplevel_set_app_id top (window-app-id w))
      (when (and decorations? (global w "zxdg_decoration_manager_v1"))
        (let ([deco (zxdg_decoration_manager_v1_get_toplevel_decoration
                     (global w "zxdg_decoration_manager_v1") top)])
          (window-decoration-set! w deco)
          (zxdg_toplevel_decoration_v1_set_mode deco ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE)))
      (window-pending-size-set! w (cons 0 0))
      (wl_surface_commit surface)))

  (define (update-scale! w)
    (let* ([from-outputs (fold-left (lambda (m o)
                                      (let ([e (assv o (window-outputs w))])
                                        (if e (max m (cdr e)) m)))
                                    1 (window-surface-outputs w))]
           [s (or (window-preferred-scale w) from-outputs)])
      (unless (= s (window-scale w))
        (window-scale-set! w s)
        (emit w 'scale s))))

  (define (window-set-min-size! w width height)
    (xdg_toplevel_set_min_size (window-toplevel w) width height))

  (define (window-set-title! w title)
    (xdg_toplevel_set_title (window-toplevel w) title))

  ;; Ask the compositor to mark the window as urgent, as foot's
  ;; wayl_win_set_urgent does: get an xdg-activation token for our surface
  ;; (without a serial, so it does not ask for focus) and, once it is done,
  ;; activate our own surface with it.  sway, for one, turns that into an
  ;; urgency hint while the window is not focused.  While a token is
  ;; pending, no other is asked for.  #f when the compositor lacks
  ;; xdg_activation_v1.
  (define (window-set-urgent! w)
    (let ([mgr (global w "xdg_activation_v1")])
      (cond
        [(not mgr) #f]
        [(window-urgency-token w) #t]
        [else
         (let ([token (xdg_activation_v1_get_activation_token mgr)])
           (window-urgency-token-set! w token)
           (wl-listen! token xdg_activation_token_v1
             (lambda (ev . args)
               (when (eq? ev 'done)
                 (xdg_activation_token_v1_destroy token)
                 (window-urgency-token-set! w #f)
                 (xdg_activation_v1_activate mgr (car args) (window-surface w)))))
           (xdg_activation_token_v1_set_surface token (window-surface w))
           (xdg_activation_token_v1_commit token)
           #t)])))

  (define (window-toggle-fullscreen! w)
    (if (window-fullscreen w)
        (xdg_toplevel_unset_fullscreen (window-toplevel w))
        (xdg_toplevel_set_fullscreen (window-toplevel w) #f)))

  ;;; Event loop helpers ---------------------------------------------------------

  (define (window-display-fd w) (wl_display_get_fd (window-display w)))
  (define (window-flush! w) (wl_display_flush (window-display w)))
  (define (window-dispatch! w)
    (when (< (wl_display_dispatch_pending (window-display w)) 0)
      (error 'chezterm "Wayland connection lost"))
    (wl-check-callback-error!))
  ;; returns #t when ready to poll; otherwise events are queued and must be
  ;; dispatched first
  (define (window-prepare-read! w) (= 0 (wl_display_prepare_read (window-display w))))
  (define (window-read-events! w)
    (when (< (wl_display_read_events (window-display w)) 0)
      (error 'chezterm "Wayland connection lost")))
  (define (window-cancel-read! w) (wl_display_cancel_read (window-display w)))

  (define (window-close! w)
    (wl_display_flush (window-display w))
    (wl_display_disconnect (window-display w)))

  ;;; Buffers & presentation ------------------------------------------------------

  (define (create-buffer! w width height)
    (let* ([stride (* 4 width)]
           [size (* stride height)]
           [fd (memfd_create "chezterm-shm" MFD_CLOEXEC)])
      (when (< fd 0) (error 'chezterm "memfd_create failed"))
      (ftruncate fd size)
      (let ([data (mmap 0 size (logor PROT_READ PROT_WRITE) MAP_SHARED fd 0)])
        (let* ([pool (wl_shm_create_pool (global w "wl_shm") fd size)]
               [format (if (window-opaque? w) WL_SHM_FORMAT_XRGB8888 WL_SHM_FORMAT_ARGB8888)]
               [proxy (wl_shm_pool_create_buffer pool 0 width height stride format)]
               [b (make-shm-buffer proxy data size width height #f 'all)])
          (wl_shm_pool_destroy pool)
          (close fd)
          (wl-listen! proxy wl_buffer
            (lambda (ev . args) (when (eq? ev 'release) (shm-buffer-busy-set! b #f))))
          b))))

  (define buffers-opaque #t)
  (define (window-opaque? w) buffers-opaque)

  (define (destroy-buffer! b)
    (wl_buffer_destroy (shm-buffer-proxy b))
    (munmap (shm-buffer-data b) (shm-buffer-size b)))

  (define (get-buffer! w width height)
    ;; drop buffers of the wrong size that are not in use
    (window-buffers-set!
     w (filter (lambda (b)
                 (if (and (= (shm-buffer-width b) width) (= (shm-buffer-height b) height))
                     #t
                     (begin (unless (shm-buffer-busy b) (destroy-buffer! b)) (shm-buffer-busy b))))
               (window-buffers w)))
    (or (find (lambda (b) (and (not (shm-buffer-busy b))
                               (= (shm-buffer-width b) width) (= (shm-buffer-height b) height)))
              (window-buffers w))
        (let ([b (create-buffer! w width height)])
          (window-buffers-set! w (cons b (window-buffers w)))
          b)))

  (define (window-configured? w) (window-configured w))
  (define (window-can-present? w) (and (window-configured w) (not (window-frame-pending w))))

  ;; Copy PIXELS (width x height ARGB) to a buffer and commit it.
  ;; DAMAGE is a list of (y0 . y1) buffer row ranges.
  ;; Sort and coalesce (y0 . y1) ranges.
  (define (merge-ranges ranges)
    (let loop ([rs (list-sort (lambda (a b) (< (car a) (car b))) ranges)] [acc '()])
      (cond
        [(null? rs) (reverse acc)]
        [(and (pair? acc) (<= (car (car rs)) (cdr (car acc))))
         (loop (cdr rs) (cons (cons (car (car acc)) (max (cdr (car acc)) (cdr (car rs)))) (cdr acc)))]
        [else (loop (cdr rs) (cons (car rs) acc))])))

  (define (window-present! w pixels width height damage opacity<1)
    (set! buffers-opaque (not opacity<1))
    (let* ([b (get-buffer! w width height)]
           [surface (window-surface w)]
           [stride (* 4 width)]
           [damage (merge-ranges damage)])
      ;; every buffer now lags behind the image in the damaged rows
      (for-each (lambda (other)
                  (unless (eq? (shm-buffer-stale other) 'all)
                    (let ([stale (append damage (shm-buffer-stale other))])
                      (shm-buffer-stale-set! other (if (> (length stale) 64) 'all stale)))))
                (window-buffers w))
      ;; bring the chosen buffer up to date: only the rows it is missing
      (let ([stale (shm-buffer-stale b)])
        (if (eq? stale 'all)
            (memcpy (shm-buffer-data b) pixels (* stride height))
            (for-each (lambda (r)
                        (let ([y0 (max 0 (car r))] [y1 (min height (cdr r))])
                          (when (< y0 y1)
                            (memcpy (+ (shm-buffer-data b) (* y0 stride)) (+ pixels (* y0 stride))
                                    (* (- y1 y0) stride)))))
                      (merge-ranges stale))))
      (shm-buffer-stale-set! b '())
      (wl_surface_attach surface (shm-buffer-proxy b) 0 0)
      (wl_surface_set_buffer_scale surface (window-scale w))
      (for-each (lambda (d) (wl_surface_damage_buffer surface 0 (car d) width (- (cdr d) (car d))))
                damage)
      (let ([cb (wl_surface_frame surface)])
        (window-frame-pending-set! w #t)
        (wl-listen! cb wl_callback
          (lambda (ev . args)
            (wl-unlisten! cb)
            (wl_proxy_destroy cb)
            (window-frame-pending-set! w #f)
            (emit w 'frame))))
      (shm-buffer-busy-set! b #t)
      (wl_surface_commit surface)))

  ;;; Input ------------------------------------------------------------------------

  (define (seat-capabilities! w caps)
    ;; devices that went away must be released; they are re-created when
    ;; the capability comes back
    (when (and (not (logtest caps WL_SEAT_CAPABILITY_KEYBOARD)) (window-keyboard-proxy w))
      (wl_keyboard_release (window-keyboard-proxy w))
      (window-keyboard-proxy-set! w #f)
      (keyboard-reset-modifiers! (window-keyboard w))
      (emit w 'focus #f '()))
    (when (and (not (logtest caps WL_SEAT_CAPABILITY_POINTER)) (window-pointer w))
      (when (window-cursor-shape-device w)
        (wp_cursor_shape_device_v1_destroy (window-cursor-shape-device w))
        (window-cursor-shape-device-set! w #f))
      (wl_pointer_release (window-pointer w))
      (window-pointer-set! w #f))
    (when (and (logtest caps WL_SEAT_CAPABILITY_KEYBOARD) (not (window-keyboard-proxy w)))
      (let ([kb (wl_seat_get_keyboard (window-seat w))])
        (window-keyboard-proxy-set! w kb)
        (wl-listen! kb wl_keyboard (lambda (ev . args) (apply keyboard-event! w ev args)))))
    (when (and (logtest caps WL_SEAT_CAPABILITY_POINTER) (not (window-pointer w)))
      (let ([p (wl_seat_get_pointer (window-seat w))])
        (window-pointer-set! w p)
        (let ([mgr (global w "wp_cursor_shape_manager_v1")])
          (when mgr
            (window-cursor-shape-device-set! w (wp_cursor_shape_manager_v1_get_pointer mgr p))))
        (wl-listen! p wl_pointer (lambda (ev . args) (apply pointer-event! w ev args)))))
    (setup-selection-devices! w))

  (define (keyboard-event! w ev . args)
    (case ev
      [(keymap) (let ([fd (cadr args)] [size (caddr args)])
                  (if (= (car args) WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1)
                      (keyboard-set-keymap! (window-keyboard w) fd size)
                      (close fd)))]
      [(enter)
       (window-serial-set! w (car args))
       (emit w 'focus #t (let ([keys (caddr args)])
                           (map (lambda (i) (bytevector-u32-native-ref keys (* 4 i)))
                                (iota (quotient (bytevector-length keys) 4)))))]
      [(leave)
       (keyboard-reset-modifiers! (window-keyboard w))
       (emit w 'focus #f '())]
      [(key)
       (let ([serial (car args)] [key (caddr args)] [state (cadddr args)])
         (window-serial-set! w serial)
         (if (= state WL_KEYBOARD_KEY_STATE_PRESSED)
             (emit w 'key-press (keyboard-translate (window-keyboard w) key KEY-PRESS) key)
             (emit w 'key-release key (keyboard-translate (window-keyboard w) key KEY-RELEASE))))]
      [(modifiers)
       (apply keyboard-update-modifiers! (window-keyboard w) (cdr args))
       (emit w 'modifiers)]
      [(repeat_info) (window-repeat-rate-set! w (car args)) (window-repeat-delay-set! w (cadr args))]
      [else (void)]))

  (define (pointer-event! w ev . args)
    (case ev
      [(enter)
       (window-pointer-serial-set! w (car args))
       (window-cursor-hidden-set! w #f)       ; it moved in
       (apply-cursor! w)
       (emit w 'pointer-enter (caddr args) (cadddr args))]
      [(leave) (emit w 'pointer-leave)]
      [(motion) (emit w 'pointer-motion (cadr args) (caddr args))]
      [(button)
       (window-serial-set! w (car args))
       (emit w 'pointer-button (caddr args) (= (cadddr args) WL_POINTER_BUTTON_STATE_PRESSED))]
      [(axis)
       (let ([axis (cadr args)] [value (caddr args)])
         (when (= axis 0) (window-axis-value-set! w (+ (window-axis-value w) value))))]
      [(axis_source) (window-axis-source-set! w (car args))]
      [(axis_discrete)
       (when (= (car args) 0) (window-axis-discrete-set! w (+ (window-axis-discrete w) (cadr args))))]
      [(frame)
       (let ([steps (window-axis-discrete w)] [value (window-axis-value w)])
         (cond
           [(not (= steps 0)) (emit w 'scroll 0 steps #t)]
           [(not (= value 0.0))
            (emit w 'scroll 0 value (not (eqv? (window-axis-source w) WL_POINTER_AXIS_SOURCE_FINGER)))])
         (window-axis-discrete-set! w 0)
         (window-axis-value-set! w 0.0)
         (window-axis-source-set! w #f))]
      [else (void)]))

  ;; name: 'text, 'default or 'pointer (a hand, over a link)
  (define (window-set-cursor! w name)
    (unless (eq? name (window-cursor-name w))
      (window-cursor-name-set! w name)
      (unless (window-cursor-hidden w) (apply-cursor! w))))

  ;; Hide the pointer over the window (HIDE? #t) or show it again.  A
  ;; hidden pointer has no cursor surface, which wl_pointer.set_cursor
  ;; allows; it shows again when it enters the window.
  (define (window-hide-cursor! w hide?)
    (unless (eq? hide? (window-cursor-hidden w))
      (window-cursor-hidden-set! w hide?)
      (apply-cursor! w)))

  (define (apply-cursor! w)
    (let ([p (window-pointer w)] [serial (window-pointer-serial w)]
          [name (or (window-cursor-name w) 'text)])
      (when p
        (cond
          [(window-cursor-hidden w) (wl_pointer_set_cursor p serial #f 0 0)]
          [(window-cursor-shape-device w)
           => (lambda (dev)
                (wp_cursor_shape_device_v1_set_shape
                 dev serial (case name
                              [(text) WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_TEXT]
                              [(pointer) WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_POINTER]
                              [else WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_DEFAULT])))]
          [else (set-theme-cursor! w p serial name)]))))

  ;; fallback: cursor images from the XCursor theme via libwayland-cursor
  (define (set-theme-cursor! w p serial name)
    (let* ([scale (window-scale w)]
           [size (* scale (or (let ([s (getenv "XCURSOR_SIZE")]) (and s (string->number s))) 24))])
      (unless (window-cursor-theme w)
        (let ([theme (wl_cursor_theme_load (getenv "XCURSOR_THEME") size (global w "wl_shm"))])
          (window-cursor-theme-set! w (if (ptr-null? theme) 'none theme))
          (window-cursor-surface-set! w (wl_compositor_create_surface (global w "wl_compositor")))))
      (let ([theme (window-cursor-theme w)])
        (unless (eq? theme 'none)
          (let ([cursor (let loop ([names (case name
                                            [(text) '("text" "xterm" "ibeam")]
                                            [(pointer) '("pointer" "hand2" "hand1")]
                                            [else '("default" "left_ptr")])])
                          (cond [(null? names) 0]
                                [else (let ([c (wl_cursor_theme_get_cursor theme (car names))])
                                        (if (ptr-null? c) (loop (cdr names)) c))]))])
            (unless (ptr-null? cursor)
              (let* ([cur (make-ftype-pointer wl_cursor cursor)]
                     [images (ftype-ref wl_cursor (images) cur)]
                     [img (foreign-ref 'uptr images 0)]
                     [image (make-ftype-pointer wl_cursor_image img)]
                     [buffer (wl_cursor_image_get_buffer img)]
                     [surface (window-cursor-surface w)])
                (wl_pointer_set_cursor p serial surface
                                       (quotient (ftype-ref wl_cursor_image (hotspot_x) image) scale)
                                       (quotient (ftype-ref wl_cursor_image (hotspot_y) image) scale))
                (wl_surface_set_buffer_scale surface scale)
                (wl_surface_attach surface buffer 0 0)
                (wl_surface_damage_buffer surface 0 0 #x7fffffff #x7fffffff)
                (wl_surface_commit surface))))))))

  ;;; Clipboard & primary selection ------------------------------------------------

  (define text-mimes '("text/plain;charset=utf-8" "UTF8_STRING" "text/plain" "TEXT" "STRING"))

  (define (setup-selection-devices! w)
    (let ([seat (window-seat w)])
      (when (and seat (global w "wl_data_device_manager") (not (window-data-device w)))
        (let ([dev (wl_data_device_manager_get_data_device (global w "wl_data_device_manager") seat)])
          (window-data-device-set! w dev)
          (wl-listen! dev wl_data_device
            (lambda (ev . args)
              (case ev
                [(data_offer) (track-offer! w (car args) wl_data_offer)]
                [(selection)
                 (let ([old (window-clipboard-offer w)])
                   (when (and old (not (eqv? old (car args)))) (destroy-offer! w old wl_data_offer_destroy)))
                 (window-clipboard-offer-set! w (car args))]
                [(enter) (let ([offer (list-ref args 4)])
                           (when offer (destroy-offer! w offer wl_data_offer_destroy)))]
                [else (void)])))))
      (when (and seat (global w "zwp_primary_selection_device_manager_v1") (not (window-primary-device w)))
        (let ([dev (zwp_primary_selection_device_manager_v1_get_device
                    (global w "zwp_primary_selection_device_manager_v1") seat)])
          (window-primary-device-set! w dev)
          (wl-listen! dev zwp_primary_selection_device_v1
            (lambda (ev . args)
              (case ev
                [(data_offer) (track-offer! w (car args) zwp_primary_selection_offer_v1)]
                [(selection)
                 (let ([old (window-primary-offer w)])
                   (when (and old (not (eqv? old (car args))))
                     (destroy-offer! w old zwp_primary_selection_offer_v1_destroy)))
                 (window-primary-offer-set! w (car args))]
                [else (void)])))))))

  (define (track-offer! w offer iface)
    (hashtable-set! (window-offer-mimes w) offer '())
    (wl-listen! offer iface
      (lambda (ev . args)
        (when (eq? ev 'offer)
          (hashtable-update! (window-offer-mimes w) offer
                             (lambda (l) (cons (car args) l)) '())))))

  (define (destroy-offer! w offer destroy)
    (hashtable-delete! (window-offer-mimes w) offer)
    (destroy offer))

  (define (window-owns-selection? w which)
    (if (eq? which 'primary) (window-primary-source w) (window-clipboard-source w)))

  (define (write-all fd bv)
    (let loop ([off 0])
      (when (< off (bytevector-length bv))
        (let* ([chunk (let ([c (make-bytevector (- (bytevector-length bv) off))])
                        (bytevector-copy! bv off c 0 (bytevector-length c))
                        c)]
               [n (c-write fd chunk (bytevector-length chunk))])
          (when (> n 0) (loop (+ off n)))))))

  ;; Offer TEXT as the clipboard ('clipboard) or primary ('primary) selection.
  (define (window-set-clipboard! w which text)
    (if (eq? which 'primary)
        (let ([mgr (global w "zwp_primary_selection_device_manager_v1")])
          (when (and mgr (window-primary-device w))
            (let ([src (zwp_primary_selection_device_manager_v1_create_source mgr)])
              (when (window-primary-source w)
                (zwp_primary_selection_source_v1_destroy (window-primary-source w)))
              (for-each (lambda (m) (zwp_primary_selection_source_v1_offer src m)) text-mimes)
              (wl-listen! src zwp_primary_selection_source_v1
                (lambda (ev . args)
                  (case ev
                    [(send) (write-all (cadr args) (string->utf8 (window-primary-text w)))
                            (close (cadr args))]
                    [(cancelled)
                     (when (eqv? src (window-primary-source w)) (window-primary-source-set! w #f))
                     (zwp_primary_selection_source_v1_destroy src)])))
              (window-primary-source-set! w src)
              (window-primary-text-set! w text)
              (zwp_primary_selection_device_v1_set_selection (window-primary-device w) src
                                                              (window-serial w)))))
        (let ([mgr (global w "wl_data_device_manager")])
          (when (and mgr (window-data-device w))
            (let ([src (wl_data_device_manager_create_data_source mgr)])
              (when (window-clipboard-source w)
                (wl_data_source_destroy (window-clipboard-source w)))
              (for-each (lambda (m) (wl_data_source_offer src m)) text-mimes)
              (wl-listen! src wl_data_source
                (lambda (ev . args)
                  (case ev
                    [(send) (write-all (cadr args) (string->utf8 (window-clipboard-text w)))
                            (close (cadr args))]
                    [(cancelled)
                     (when (eqv? src (window-clipboard-source w)) (window-clipboard-source-set! w #f))
                     (wl_data_source_destroy src)]
                    [else (void)])))
              (window-clipboard-source-set! w src)
              (window-clipboard-text-set! w text)
              (wl_data_device_set_selection (window-data-device w) src (window-serial w)))))))

  ;; Request the selection's text; it arrives later as a (paste which text
  ;; tag) event, with TAG (#f by default) telling requests apart.  TEXT is
  ;; #f when there is no text to paste.
  (define window-request-paste!
    (case-lambda
      [(w which) (window-request-paste! w which #f)]
      [(w which tag)
       (cond
         [(window-owns-selection? w which)
          (emit w 'paste which (if (eq? which 'primary) (window-primary-text w) (window-clipboard-text w)) tag)]
         [(let ([offer (if (eq? which 'primary) (window-primary-offer w) (window-clipboard-offer w))])
            (and offer
                 (let* ([mimes (hashtable-ref (window-offer-mimes w) offer '())]
                        [mime (find (lambda (m) (member m mimes)) text-mimes)])
                   (and mime (receive-offer! w which offer mime tag)))))
          (void)]
         [else (emit w 'paste which #f tag)])]))

  ;; Start reading OFFER's text as MIME; #f when no pipe could be made.
  (define (receive-offer! w which offer mime tag)
    (let* ([fds (malloc 8)]
           [ok (= 0 (pipe2 fds O_CLOEXEC))])
      (when ok
        (let ([rfd (foreign-ref 'int fds 0)] [wfd (foreign-ref 'int fds 4)])
          (if (eq? which 'primary)
              (zwp_primary_selection_offer_v1_receive offer mime wfd)
              (wl_data_offer_receive offer mime wfd))
          (close wfd)
          (fcntl rfd F_SETFL O_NONBLOCK)
          (window-reads-set! w (cons (vector rfd which (call-with-values open-bytevector-output-port cons) tag)
                                     (window-reads w)))
          (wl_display_flush (window-display w))))
      (free fds)
      ok))

  (define (window-poll-fds w) (map (lambda (r) (vector-ref r 0)) (window-reads w)))

  (define read-buf (make-bytevector 65536))

  (define (window-fd-ready! w fd)
    (let ([r (find (lambda (r) (= (vector-ref r 0) fd)) (window-reads w))])
      (when r
        (let loop ()
          (let ([n (c-read fd read-buf (bytevector-length read-buf))])
            (cond
              [(> n 0)
               (put-bytevector (car (vector-ref r 2)) read-buf 0 n)
               (loop)]
              [(and (< n 0) (memv (errno) (list EAGAIN EINTR))) (void)]
              [else
               ;; EOF or error: done
               (close fd)
               (window-reads-set! w (remq r (window-reads w)))
               (emit w 'paste (vector-ref r 1) (utf8->string ((cdr (vector-ref r 2)))) (vector-ref r 3))]))))))
  )
