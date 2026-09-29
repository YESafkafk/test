;;; Wayland client runtime.
;;;
;;; libwayland-client's protocol stubs are static inline functions and cannot
;;; be called through an FFI, so this library provides the equivalent:
;;;  - interface descriptors (built into C `struct wl_interface`s so that
;;;    libwayland can marshal and demarshal messages),
;;;  - wl-marshal, which sends a request with wl_proxy_marshal_array_flags,
;;;  - event dispatch through a single wl_proxy_add_dispatcher callback that
;;;    decodes the `union wl_argument` array and calls a Scheme handler.
;;;
;;; Proxies are represented by their C addresses (integers).
(library (chezterm wayland)
  (export make-wl-interface wl-interface? wl-interface-name wl-interface-version
          wl-interface-set-messages! wl-interface-ptr
          wl-marshal wl-proxy-destroy wl-listen! wl-unlisten!
          wl-check-callback-error!)
  (import (chezscheme) (chezterm ffi) (chezterm cutil))

  (define-record-type wl-interface
    (fields name version ptr
            (mutable requests)      ; vector of #(name kinds)
            (mutable events))       ; vector of #(name-symbol kinds)
    (protocol
     (lambda (new)
       (lambda (name version)
         (let ([p (malloc (ftype-sizeof wl_interface))])
           (memset p 0 (ftype-sizeof wl_interface))
           (new name version p '#() '#()))))))

  ;; "?ou2i" -> (#\o #\u #\i); the since-version and nullability markers
  ;; are irrelevant for encoding.
  (define (signature-kinds sig)
    (filter (lambda (c) (not (or (char=? c #\?) (char-numeric? c)))) (string->list sig)))

  (define (build-messages descs)
    ;; descs: list of (name signature types)
    (let* ([n (length descs)]
           [arr (if (= n 0) 0 (malloc (* n (ftype-sizeof wl_message))))])
      (let loop ([ds descs] [i 0])
        (unless (null? ds)
          (let* ([d (car ds)]
                 [types (caddr d)]
                 [tarr (if (null? types) 0 (malloc (* 8 (length types))))]
                 [m (make-ftype-pointer wl_message (+ arr (* i (ftype-sizeof wl_message))))])
            (let tloop ([ts types] [j 0])
              (unless (null? ts)
                (foreign-set! 'uptr tarr (* j 8) (if (car ts) (wl-interface-ptr (car ts)) 0))
                (tloop (cdr ts) (+ j 1))))
            (ftype-set! wl_message (name) m (string->cstring (car d)))
            (ftype-set! wl_message (signature) m (string->cstring (cadr d)))
            (ftype-set! wl_message (types) m tarr)
            (loop (cdr ds) (+ i 1)))))
      arr))

  (define (wl-interface-set-messages! iface requests events)
    (let ([reqs (vector->list requests)] [evs (vector->list events)]
          [c (make-ftype-pointer wl_interface (wl-interface-ptr iface))])
      (ftype-set! wl_interface (name) c (string->cstring (wl-interface-name iface)))
      (ftype-set! wl_interface (version) c (wl-interface-version iface))
      (ftype-set! wl_interface (method_count) c (length reqs))
      (ftype-set! wl_interface (methods) c (make-ftype-pointer wl_message (build-messages reqs)))
      (ftype-set! wl_interface (event_count) c (length evs))
      (ftype-set! wl_interface (events) c (make-ftype-pointer wl_message (build-messages evs)))
      (wl-interface-requests-set! iface
        (list->vector (map (lambda (d) (vector (car d) (signature-kinds (cadr d)))) reqs)))
      (wl-interface-events-set! iface
        (list->vector (map (lambda (d) (vector (string->symbol (car d)) (signature-kinds (cadr d))))
                           evs)))))

  ;;; Requests ----------------------------------------------------------

  (define max-args 20)
  (define arg-buffer (malloc (* 8 max-args)))

  (define (wl-marshal proxy iface opcode new-iface new-version flags . args)
    (let* ([req (vector-ref (wl-interface-requests iface) opcode)]
           [kinds (vector-ref req 1)]
           [temps '()])
      (let loop ([ks kinds] [as args] [off 0])
        (unless (null? ks)
          (let ([a (car as)])
            (case (car ks)
              [(#\i #\h) (foreign-set! 'integer-32 arg-buffer off a)]
              [(#\u) (foreign-set! 'unsigned-32 arg-buffer off a)]
              [(#\f) (foreign-set! 'integer-32 arg-buffer off (exact (round (* a 256))))]
              [(#\s)
               (let ([p (if a (string->cstring a) 0)])
                 (set! temps (cons p temps))
                 (foreign-set! 'uptr arg-buffer off p))]
              [(#\o #\n) (foreign-set! 'uptr arg-buffer off (or a 0))]
              [(#\a)
               ;; a is a bytevector; wrap it in a temporary struct wl_array
               (let* ([n (bytevector-length a)]
                      [data (bytes->cstring a)]
                      [arr (malloc (ftype-sizeof wl_array))])
                 (foreign-set! 'unsigned-long arr 0 n)
                 (foreign-set! 'unsigned-long arr 8 n)
                 (foreign-set! 'uptr arr 16 data)
                 (set! temps (cons* data arr temps))
                 (foreign-set! 'uptr arg-buffer off arr))]
              [else (errorf 'wl-marshal "bad argument kind ~s" (car ks))])
            (loop (cdr ks) (cdr as) (+ off 8)))))
      (when (= flags WL_MARSHAL_FLAG_DESTROY)
        (wl-unlisten! proxy))
      (let ([r (wl_proxy_marshal_array_flags
                proxy opcode
                (if new-iface (wl-interface-ptr new-iface) 0)
                (cond [new-version new-version]
                      [new-iface (wl_proxy_get_version proxy)]
                      [else 0])
                flags arg-buffer)])
        (for-each free temps)
        (ptr-or-false r))))

  (define (wl-proxy-destroy proxy)
    (wl-unlisten! proxy)
    (wl_proxy_destroy proxy))

  ;;; Events ------------------------------------------------------------

  ;; proxy address -> (interface . handler)
  (define handlers (make-eqv-hashtable))
  (define dispatcher-installed (make-eqv-hashtable))

  ;; Exceptions must not unwind through libwayland's C frames; they are
  ;; captured here and re-raised by the event loop.
  (define pending-error #f)

  (define (wl-check-callback-error!)
    (when pending-error
      (let ([e pending-error])
        (set! pending-error #f)
        (raise e))))

  (define (read-wl-array p)
    (let* ([size (foreign-ref 'unsigned-long p 0)]
           [data (foreign-ref 'uptr p 16)]
           [bv (make-bytevector size)])
      (do ([i 0 (fx+ i 1)]) ((fx= i size))
        (bytevector-u8-set! bv i (foreign-ref 'unsigned-8 data i)))
      bv))

  (define (decode-args kinds args)
    (let loop ([ks kinds] [off 0] [acc '()])
      (if (null? ks)
          (reverse acc)
          (loop (cdr ks) (+ off 8)
                (cons (case (car ks)
                        [(#\i #\h) (foreign-ref 'integer-32 args off)]
                        [(#\u) (foreign-ref 'unsigned-32 args off)]
                        [(#\f) (/ (foreign-ref 'integer-32 args off) 256.0)]
                        [(#\s) (cstring->string (foreign-ref 'uptr args off))]
                        [(#\o #\n) (ptr-or-false (foreign-ref 'uptr args off))]
                        [(#\a) (read-wl-array (foreign-ref 'uptr args off))]
                        [else #f])
                      acc)))))

  (define (dispatch target opcode args)
    (let ([h (hashtable-ref handlers target #f)])
      (when h
        (let* ([ev (vector-ref (wl-interface-events (car h)) opcode)]
               [decoded (decode-args (vector-ref ev 1) args)])
          (apply (cdr h) (vector-ref ev 0) decoded)))))

  (define dispatcher-entry
    (let ([fc (foreign-callable
               (lambda (impl target opcode msg args)
                 (guard (e [#t (unless pending-error (set! pending-error e))])
                   (dispatch target opcode args))
                 0)
               (uptr uptr unsigned-32 uptr uptr)
               int)])
      (lock-object fc)
      (foreign-callable-entry-point fc)))

  ;; Install HANDLER, called as (handler event-symbol arg ...), for events
  ;; arriving on PROXY which implements IFACE.
  (define (wl-listen! proxy iface handler)
    (hashtable-set! handlers proxy (cons iface handler))
    (unless (hashtable-ref dispatcher-installed proxy #f)
      (hashtable-set! dispatcher-installed proxy #t)
      (wl_proxy_add_dispatcher proxy dispatcher-entry 0 0)))

  (define (wl-unlisten! proxy)
    (hashtable-delete! handlers proxy)
    (hashtable-delete! dispatcher-installed proxy)))
