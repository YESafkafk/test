;;; The application: ties together window, terminal, renderer and pty, and
;;; implements the event loop, input handling, selection, clipboard,
;;; key bindings, scrollback search and font resizing.
(library (chezterm app)
  (export run)
  (import (chezscheme) (chezterm ffi) (chezterm cutil) (chezterm config)
          (chezterm charwidth) (chezterm grid) (chezterm terminal) (chezterm font)
          (chezterm render) (chezterm keyboard) (chezterm window) (chezterm pty)
          (chezterm selection) (chezterm hints) (chezterm termenv))

  (define version "0.1.0")

  ;;; State ----------------------------------------------------------------------

  (define win #f)
  (define term #f)
  (define renderer #f)
  (define font #f)
  (define pty-fd #f)
  (define child-pid #f)
  (define child-exited #f)
  (define hold? #f)
  (define hostname "")            ; this machine's, for file:// URIs (see uri-to-open)
  (define quit? #f)

  (define scale 1)
  (define font-size 11.0)
  (define logical-width 0)
  (define logical-height 0)
  (define pad-x 2)
  (define pad-y 2)
  (define focused #t)
  (define need-redraw #t)

  (define write-queue '())        ; list of bytevectors pending for the pty

  ;; Output backlog: while the pty has more output than one read batch
  ;; takes, frames are spaced so that drawing takes at most about a fifth
  ;; of the time (4x the last frame's drawing time), but never more than
  ;; max-backlog-frame-gap ms apart.  Parsing gets the rest.
  (define backlog #f)             ; the last read batch did not drain the pty
  (define backlog-next-frame 0)   ; earliest time of the next frame during a backlog
  (define max-backlog-frame-gap 50)

  (define bindings '())           ; list of ((mods . sym) . action)

  ;; key repeat
  (define repeat-key #f)          ; evdev keycode
  (define repeat-event #f)
  (define repeat-next 0)
  ;; evdev keycodes of held keys whose press was reported to the program:
  ;; only their releases are (see reported-after-press)
  (define reported-keys '())

  ;; visual bell
  (define bell-start #f)          ; when the flash started, while it lasts

  ;; cursor blinking
  (define blink-on #t)
  (define blink-next 0)

  ;; mouse
  (define mouse-x 0.0)
  (define mouse-y 0.0)
  (define mouse-buttons '())      ; pressed buttons
  (define last-mouse-cell #f)
  (define selecting #f)           ; #f or 'char / 'word / 'line
  (define select-anchor #f)       ; (abs . col) where the selection started
  (define select-block #f)
  (define click-count 0)
  (define last-click-time 0)
  (define last-click-cell #f)
  (define smooth-scroll-acc 0.0)
  (define pointer-inside #f)
  (define hover-link 0)           ; the OSC 8 link under the pointer while Ctrl is held
  (define hover-url #f)           ; or the URL found in the text there (a target)

  ;; search
  (define search-active #f)
  (define search-backward #t)
  (define search-query "")
  (define search-match #f)        ; #(abs c0 c1)

  ;; keyboard hints
  (define hints #f)               ; the hint state (see hints.ss) while hint mode is on
  (define hint-cells #f)          ; its labels by absolute row (hint-label-cells)

  ;; live configuration reload
  (define config-file #f)
  (define config-watch-fd #f)

  ;; testing aid
  (define dump-frame #f)          ; (path . delay-ms)
  (define start-time 0)

  (define BTN-LEFT 272)
  (define BTN-RIGHT 273)
  (define BTN-MIDDLE 274)

  (define (now-ms)
    (let ([t (current-time 'time-monotonic)])
      (+ (* 1000 (time-second t)) (quotient (time-nanosecond t) 1000000))))

  (define (warn fmt . args)
    (apply fprintf (current-error-port) (string-append "chezterm: " fmt "\n") args)
    (flush-output-port (current-error-port)))

  ;;; Configuration helpers ---------------------------------------------------------

  (define (color-option key)
    (let ([v (cdr (assq key (config-ref 'colors)))])
      (and v (or (parse-hex-color v)
                 (begin (warn "invalid color ~s for ~a" v key) #f)))))

  (define (build-palette)
    (let ([colors (config-ref 'colors)])
      (make-default-palette (map parse-hex-color (cdr (assq 'normal colors)))
                            (map parse-hex-color (cdr (assq 'bright colors)))
                            (color-option 'foreground)
                            (color-option 'background)
                            (color-option 'cursor))))

  (define (load-bindings!)
    (set! bindings
          (filter values
                  (map (lambda (b)
                         (let ([k (parse-key-binding (car b))])
                           (if k
                               (cons k (cdr b))
                               (begin (warn "invalid key binding ~s" (car b)) #f))))
                       (config-ref 'bindings)))))

  (define (make-font-at size s)
    (make-font (config-ref 'font-family) size (inexact (config-ref 'dpi)) s
               (config-ref 'font-bold-family) (config-ref 'font-italic-family)))

  (define (create-renderer f)
    (let ([r (make-renderer f pad-x pad-y (config-ref 'opacity)
                            (config-ref 'bold-is-bright)
                            (color-option 'selection-foreground)
                            (or (color-option 'selection-background) #x4f4f4f)
                            (config-ref 'cursor-unfocused-hollow))])
      (renderer-set-hint-colors! r (or (color-option 'hint-foreground) #x181818)
                                 (or (color-option 'hint-background) #xf4bf75)
                                 (or (color-option 'hint-typed-foreground) #x181818)
                                 (or (color-option 'hint-typed-background) #xac4242))
      r))

  (define (read-padding!)
    (let ([padding (config-ref 'padding)])
      (set! pad-x (car padding))
      (set! pad-y (if (pair? (cdr padding)) (cadr padding) (car padding)))))

  ;;; Live configuration reload ------------------------------------------------------

  (define (watch-config!)
    (when config-file
      (let ([dir (path-parent config-file)])
        (when (and (not (string=? dir "")) (file-directory? dir))
          (let ([fd (inotify_init1 (logor IN_NONBLOCK IN_CLOEXEC))])
            (when (>= fd 0)
              (if (>= (inotify_add_watch fd dir (logor IN_CLOSE_WRITE IN_MOVED_TO IN_CREATE)) 0)
                  (set! config-watch-fd fd)
                  (close fd))))))))

  (define inotify-buf (make-bytevector 4096))

  ;; Drain inotify events; reload when one names the configuration file.
  (define (config-watch-ready!)
    (let ([name (path-last config-file)])
      (let loop ([hit #f])
        (let ([n (c-read config-watch-fd inotify-buf (bytevector-length inotify-buf))])
          (if (> n 0)
              ;; struct inotify_event { int wd; u32 mask, cookie, len; char name[]; }
              (loop (let scan ([off 0] [hit hit])
                      (if (>= off n)
                          hit
                          (let* ([len (bytevector-u32-native-ref inotify-buf (+ off 12))]
                                 [ev-name (let ([bv (make-bytevector len)])
                                            (bytevector-copy! inotify-buf (+ off 16) bv 0 len)
                                            (let ([s (utf8->string bv)])
                                              ;; strip NUL padding
                                              (let trim ([k 0])
                                                (if (and (< k (string-length s))
                                                         (not (char=? (string-ref s k) #\nul)))
                                                    (trim (+ k 1))
                                                    (substring s 0 k)))))])
                            (scan (+ off 16 len) (or hit (string=? ev-name name)))))))
              (when hit
                (guard (e [#t (let ([p (current-error-port)])
                                (display "chezterm: reloading the configuration failed: " p)
                                (display-condition e p)
                                (newline p))])
                  (reload-config!))))))))

  (define (reload-config!)
    (warn "reloading ~a" config-file)
    (load-config config-file)
    (load-bindings!)
    (terminal-set-defaults! term (build-palette) (config-ref 'cursor-style) (config-ref 'cursor-blink))
    (terminal-set-kitty-keyboard! term (config-ref 'kitty-keyboard))
    (read-padding!)
    (renderer-free! renderer)
    (set! renderer (create-renderer font))
    (set-font! (inexact (config-ref 'font-size)) scale)
    (unless (config-ref 'dynamic-title) (window-set-title! win (config-ref 'title)))
    (set! need-redraw #t))

  ;;; PTY I/O ------------------------------------------------------------------------

  (define (send! x)
    (when (and pty-fd (not child-exited))
      (let ([bv (if (string? x) (string->utf8 x) x)])
        (when (> (bytevector-length bv) 0)
          (set! write-queue (append write-queue (list bv)))
          (flush-writes!)))))

  (define (flush-writes!)
    (let loop ()
      (when (and (pair? write-queue) pty-fd)
        (let* ([bv (car write-queue)]
               [n (pty-write pty-fd bv 0 (bytevector-length bv))])
          (cond
            [(not n) (set! write-queue '())]
            [(= n (bytevector-length bv)) (set! write-queue (cdr write-queue)) (loop)]
            [(> n 0)
             (let ([rest (make-bytevector (- (bytevector-length bv) n))])
               (bytevector-copy! bv n rest 0 (bytevector-length rest))
               (set-car! write-queue rest))]
            [else (void)])))))

  (define read-buffer (make-bytevector 65536))

  ;; Read and process available pty output; returns #f on EOF.
  (define (read-pty!)
    (set! backlog #f)
    (let loop ([k 0])
      (if (>= k 16)
          (begin (set! backlog #t) #t)
          (let ([n (pty-read pty-fd read-buffer)])
            (cond
              [(not n) #f]
              [(= n 0) #t]
              [else
               (terminal-feed! term read-buffer n)
               (reset-blink!)
               (loop (+ k 1))])))))

  (define (resize-pty!)
    (when (and pty-fd (not child-exited))
      (pty-resize! pty-fd (terminal-rows term) (terminal-cols term)
                   (* (terminal-cols term) (font-cell-width font))
                   (* (terminal-rows term) (font-cell-height font)))))

  ;;; Layout -----------------------------------------------------------------------------

  (define (relayout!)
    (let ([bw (* logical-width scale)] [bh (* logical-height scale)])
      (renderer-resize! renderer bw bh)
      ;; at least two columns, so that wide characters always fit
      (let ([cols (max 2 (renderer-cols renderer))] [rows (renderer-rows renderer)])
        (unless (and (= cols (terminal-cols term)) (= rows (terminal-rows term)))
          (end-hints!)
          (terminal-resize! term rows cols)
          (resize-pty!)))
      (terminal-set-cell-pixel-size! term (font-cell-width font) (font-cell-height font))
      (set! need-redraw #t)))

  (define (set-font! size s)
    (let ([f (make-font-at size s)])
      (when font (font-destroy! font))
      (set! font f)
      (set! font-size size)
      (renderer-set-font! renderer f)
      (renderer-set-padding! renderer (* s pad-x) (* s pad-y))
      (window-set-min-size! win (quotient (+ (* 2 pad-x s) (* 2 (font-cell-width f))) s)
                            (quotient (+ (* 2 pad-y s) (font-cell-height f)) s))
      (relayout!)))

  ;;; Drawing ------------------------------------------------------------------------------

  (define sync-timeout 150)

  (define (sync-hold?)
    (let ([t (terminal-sync-update? term)])
      (and t
           (let ([elapsed (- (real-time) t)])
             ;; the application ends the update with ESC[?2026l; if it
             ;; doesn't, draw anyway after the timeout
             (< elapsed sync-timeout)))))

  (define (backlog-hold?)
    (and backlog (< (now-ms) backlog-next-frame)))

  (define (maybe-draw!)
    (when (and (window-can-present? win)
               (or need-redraw (terminal-dirty? term))
               (not (sync-hold?))
               (not (backlog-hold?)))
      (set! need-redraw #f)
      (terminal-dirty-set! term #f)
      (let* ([t0 (now-ms)]
             [damage (begin
                       (update-hover!)       ; the text under the pointer may have changed
                       (when hints (update-hints!))
                       (let ([d (renderer-render! renderer term focused blink-on highlights
                                                  (and search-active (search-overlay)))])
                         (if bell-start (flash-bell! d) d)))]
             [t1 (now-ms)])
        (set! backlog-next-frame (+ t1 (min max-backlog-frame-gap (* 4 (- t1 t0)))))
        (unless (null? damage)
          (window-present! win (renderer-pixels renderer) (renderer-width renderer)
                           (renderer-height renderer) damage
                           (< (config-ref 'opacity) 1.0))))
      (when dump-frame (check-dump-frame!))))

  ;; The visual bell: the window tinted with the bell color, fading out
  ;; linearly over bell-duration ms, as Alacritty's Linear animation.  Every
  ;; frame of the flash is a full redraw (renderer-tint! makes the next
  ;; one full), and so is the one after it.
  (define (flash-bell! damage)
    (let* ([duration (config-ref 'bell-duration)]
           [left (- (+ bell-start duration) (now-ms))])
      (if (and (real? duration) (> left 0))
          (begin
            (set! need-redraw #t)       ; the next frame fades further
            (renderer-tint! renderer (or (color-option 'bell) #xffffff)
                            (exact (round (* 255 (/ left duration))))))
          (begin (set! bell-start #f) damage))))

  (define (check-dump-frame!)
    (when (>= (- (now-ms) start-time) (cdr dump-frame))
      (write-ppm (car dump-frame))
      (set! quit? #t)))

  (define (write-ppm path)
    (let* ([w (renderer-width renderer)] [h (renderer-height renderer)]
           [p (renderer-pixels renderer)] [bv (make-bytevector (* 3 w h))])
      (do ([i 0 (fx+ i 1)]) ((fx= i (* w h)))
        (let ([px (foreign-ref 'unsigned-32 p (fx* 4 i))])
          (bytevector-u8-set! bv (fx* 3 i) (fxand #xff (fxsrl px 16)))
          (bytevector-u8-set! bv (fx+ 1 (fx* 3 i)) (fxand #xff (fxsrl px 8)))
          (bytevector-u8-set! bv (fx+ 2 (fx* 3 i)) (fxand #xff px))))
      (let ([o (open-file-output-port path (file-options no-fail))])
        (put-bytevector o (string->utf8 (format "P6\n~a ~a\n255\n" w h)))
        (put-bytevector o bv)
        (close-port o))))

  (define (reset-blink!)
    (unless blink-on (set! need-redraw #t))
    (set! blink-on #t)
    (set! blink-next (+ (now-ms) (config-ref 'cursor-blink-interval))))

  ;;; Selection ---------------------------------------------------------------------------

  ;; pointer position -> (abs-row . col), clamped to the grid
  (define (point->cell x y)
    (let* ([cw (font-cell-width font)] [ch (font-cell-height font)]
           [px (- (* x scale) (* pad-x scale))] [py (- (* y scale) (* pad-y scale))]
           [col (max 0 (min (- (terminal-cols term) 1) (exact (floor (/ px cw)))))]
           [row (max 0 (min (- (terminal-rows term) 1) (exact (floor (/ py ch)))))])
      (cons (terminal-abs-row term (- row (terminal-display-offset term))) col)))

  (define (view-row-of-pointer)
    (let ([py (- (* mouse-y scale) (* pad-y scale))])
      (exact (floor (/ py (font-cell-height font))))))

  (define (point<? a b) (or (< (car a) (car b)) (and (= (car a) (car b)) (< (cdr a) (cdr b)))))

  (define (update-selection! pt)
    (let* ([anchor select-anchor]
           [forward (not (point<? pt anchor))]
           [a anchor] [b pt])
      (case selecting
        [(word)
         (let* ([wa (word-bounds term (config-ref 'word-separators) (car a) (cdr a))] [wb (word-bounds term (config-ref 'word-separators) (car b) (cdr b))])
           (if forward
               (set-sel! (car a) (car wa) (car b) (cdr wb))
               (set-sel! (car a) (cdr wa) (car b) (car wb))))]
        [(line)
         (let ([la (logical-line-bounds term (car a))] [lb (logical-line-bounds term (car b))]
               [last (- (terminal-cols term) 1)])
           (if forward
               (set-sel! (car la) 0 (cdr lb) last)
               (set-sel! (cdr la) last (car lb) 0)))]
        [else (set-sel! (car a) (cdr a) (car b) (cdr b))])))

  (define (set-sel! a ac b bc)
    (terminal-set-selection! term (vector (if select-block 'block 'stream) a ac b bc)))

  (define (copy-selection! which)
    (let ([text (selection-text term)])
      (when text (window-set-clipboard! win which text))))

  ;;; Paste --------------------------------------------------------------------------------

  (define (paste-text! text)
    (let* ([normalized (let ([out (open-output-string)] [n (string-length text)])
                         (let loop ([i 0])
                           (when (< i n)
                             (let ([c (string-ref text i)])
                               (cond
                                 [(and (char=? c #\return) (< (+ i 1) n)
                                       (char=? (string-ref text (+ i 1)) #\newline))
                                  (write-char #\return out) (loop (+ i 2))]
                                 [(char=? c #\newline) (write-char #\return out) (loop (+ i 1))]
                                 ;; never let pasted text end bracketed paste early
                                 [(and (char=? c #\x1b) (terminal-bracketed-paste? term)) (loop (+ i 1))]
                                 [else (write-char c out) (loop (+ i 1))]))))
                         (get-output-string out))])
      (terminal-scroll-to-bottom! term)
      (typing!)
      (if (terminal-bracketed-paste? term)
          (send! (string-append "\x1b;[200~" normalized "\x1b;[201~"))
          (send! normalized))))

  ;;; Search -------------------------------------------------------------------------------

  ;; What the renderer highlights in absolute row ABS: search matches, the
  ;; hovered link or URL and hint labels.
  (define (highlights abs)
    (let* ([s (search-highlights abs)]
           [s (if (= hover-link 0)
                  s
                  (append s (map (lambda (r) (list (car r) (cadr r) 'link))
                                 (link-ranges term hover-link abs))))]
           [s (if hover-url
                  (append s (map (lambda (r) (list (car r) (cadr r) 'link))
                                 (target-ranges hover-url abs (terminal-cols term))))
                  s)])
      (if hint-cells
          (append s (hashtable-ref hint-cells abs '()))
          s)))

  (define (search-highlights abs)
    (if (and search-active (> (string-length search-query) 0))
        (map (lambda (m)
               (list (car m) (cadr m)
                     (and search-match (= abs (vector-ref search-match 0))
                          (= (car m) (vector-ref search-match 1)))))
             (line-matches term search-query abs))
        '()))

  (define (search-overlay)
    (let* ([cols (terminal-cols term)]
           [l (make-line cols)]
           [text (string-append (if search-backward "Search backward: " "Search forward: ")
                                search-query "_")]
           [n (string-length text)]
           [start (max 0 (- n cols))])
      (do ([i 0 (+ i 1)]) ((= i cols))
        (let ([k (+ start i)])
          (cell-set! (line-cells l) i (if (< k n) (char->integer (string-ref text k)) 32)
                     ATTR-REVERSE COLOR-FG COLOR-BG)))
      l))

  ;; Find the next match from position FROM (#(abs col)) in direction.
  (define (search-step! backward? include-current?)
    (let* ([g (terminal-grid term)]
           [top (terminal-abs-row term (- (grid-hist-count g)))]
           [bottom (terminal-abs-row term (- (grid-rows g) 1))]
           [total (+ 1 (- bottom top))]
           [start-abs (if search-match
                          (vector-ref search-match 0)
                          (if backward? bottom top))]
           [start-col (if search-match (vector-ref search-match 1) (if backward? 1000000 -1))])
      (let loop ([k 0] [abs start-abs])
        (when (<= k total)
          (let* ([ms (line-matches term search-query abs)]
                 [candidates
                  (cond
                    [(> k 0) ms]
                    [backward? (filter (lambda (m) (if include-current? (<= (car m) start-col) (< (car m) start-col))) ms)]
                    [else (filter (lambda (m) (if include-current? (>= (car m) start-col) (> (car m) start-col))) ms)])]
                 [pick (and (pair? candidates)
                            (if backward? (car (last-pair candidates)) (car candidates)))])
            (if pick
                (begin
                  (set! search-match (vector abs (car pick) (cadr pick)))
                  (reveal-row! abs)
                  (set! need-redraw #t))
                (let ([next (if backward? (- abs 1) (+ abs 1))])
                  (loop (+ k 1)
                        (cond [(< next top) bottom] [(> next bottom) top] [else next])))))))))

  (define (reveal-row! abs)
    (let* ([row (terminal-rel-row term abs)]
           [offset (terminal-display-offset term)]
           [rows (terminal-rows term)]
           [view (+ row offset)])
      (unless (and (>= view 0) (< view (- rows 1)))
        (terminal-scroll-display! term (- (- (quotient rows 2) row) offset)))))

  ;; not in hint mode
  (define (start-search! backward?)
    (unless hints
      (set! search-active #t)
      (set! search-backward backward?)
      (set! search-match #f)
      (set! need-redraw #t)))

  (define (end-search!)
    (set! search-active #f)
    (when search-match
      ;; leave the match selected so it can be copied
      (terminal-set-selection! term (vector 'stream (vector-ref search-match 0) (vector-ref search-match 1)
                                            (vector-ref search-match 0) (- (vector-ref search-match 2) 1))))
    (set! search-match #f)
    (set! need-redraw #t))

  (define (search-key! ev)
    (let ([sym (key-event-sym ev)] [text (key-event-text ev)] [mods (key-event-mods ev)])
      (cond
        [(= sym (keysym-by-name "Escape")) (end-search!)]
        [(or (= sym (keysym-by-name "Return")) (= sym (keysym-by-name "KP_Enter")))
         (search-step! (if (logtest mods MOD-SHIFT) (not search-backward) search-backward) #f)]
        [(= sym (keysym-by-name "BackSpace"))
         (when (> (string-length search-query) 0)
           (set! search-query (substring search-query 0 (- (string-length search-query) 1)))
           (search-step! search-backward #t))
         (set! need-redraw #t)]
        [(and (logtest mods MOD-CTRL) (= (keysym-lower sym) (keysym-by-name "u")))
         (set! search-query "") (set! search-match #f) (set! need-redraw #t)]
        [(and (> (string-length text) 0) (char>=? (string-ref text 0) #\space)
              (not (logtest mods MOD-CTRL)))
         (typing!)
         (set! search-query (string-append search-query text))
         (search-step! search-backward #t)
         (set! need-redraw #t)]
        [else (void)])))

  ;;; Keyboard hints -----------------------------------------------------------------------
  ;;; A key binding starts hint mode for one action: every target on screen
  ;;; (OSC 8 links and URLs, see hint-targets) gets a label, and typing a
  ;;; label runs the action on its target.  As in Alacritty, the targets are
  ;;; found again whenever a frame is drawn, so labels follow output and
  ;;; scrolling, keeping the keys typed so far; hint mode ends when no
  ;;; target is left, on Escape, once an action ran, and on a resize.

  (define (hint-alphabet)
    (let ([a (config-ref 'hint-alphabet)])
      (if (valid-hint-alphabet? a)
          a
          (begin (warn "invalid hint-alphabet ~s: at least two different characters needed" a)
                 default-hint-alphabet))))

  ;; the targets ACTION can be run on: hint-open only opens what Ctrl+click
  ;; would
  (define (action-targets action)
    (let ([ts (hint-targets term)])
      (if (eq? action 'hint-open)
          (filter (lambda (t) (uri-to-open (target-uri t) hostname)) ts)
          ts)))

  (define (start-hints! action)
    (unless (or search-active hints)
      (set-hints! (hint-start action (hint-alphabet) (action-targets action)))))

  (define (set-hints! state)
    (set! hints state)
    (set! hint-cells (and state (hint-label-cells state (terminal-cols term))))
    (set! need-redraw #t))

  (define (end-hints!)
    (when hints (set-hints! #f)))

  ;; before drawing a frame, which the new labels are then part of
  (define (update-hints!)
    (set-hints! (hint-update hints (action-targets (hint-state-action hints))))
    (set! need-redraw #f))

  (define (hint-key-press! ev)
    (let* ([sym (key-event-sym ev)] [text (key-event-text ev)]
           [ctrl (logtest (key-event-mods ev) MOD-CTRL)]
           [key (cond
                  [(= sym (keysym-by-name "Escape")) 'escape]
                  [(and ctrl (= (keysym-lower sym) (keysym-by-name "c"))) 'escape]
                  [(= sym (keysym-by-name "BackSpace")) 'backspace]
                  [(and (not ctrl) (= (string-length text) 1) (char>? (string-ref text 0) #\space))
                   (string-ref text 0)]
                  [else #f])]
           [action (hint-state-action hints)])
      (let-values ([(state target) (hint-key hints key)])
        (unless (eq? state hints) (set-hints! state))
        (when target (run-hint-action! action target)))))

  (define (run-hint-action! action t)
    (case action
      [(hint-open) (open-uri! (uri-to-open (target-uri t) hostname))]
      [(hint-copy) (window-set-clipboard! win 'clipboard (target-uri t))]
      ;; as if pasted, so bracketed paste applies (Alacritty's Paste)
      [(hint-paste) (paste-text! (target-uri t))]
      [(hint-select)
       (let ([s (target-start t)] [e (target-end t)])
         (terminal-set-selection! term (vector 'stream (car s) (cdr s) (car e) (- (cdr e) 1)))
         (when (config-ref 'copy-on-select) (copy-selection! 'primary)))]))

  ;;; Actions ------------------------------------------------------------------------------

  (define (run-action! action)
    (case action
      [(copy) (copy-selection! 'clipboard)]
      [(paste) (window-request-paste! win 'clipboard)]
      [(paste-primary) (window-request-paste! win 'primary)]
      [(increase-font-size) (set-font! (+ font-size 1.0) scale)]
      [(decrease-font-size) (when (> font-size 2.0) (set-font! (- font-size 1.0) scale))]
      [(reset-font-size) (set-font! (inexact (config-ref 'font-size)) scale)]
      [(scroll-page-up) (terminal-scroll-display! term (- (terminal-rows term) 1))]
      [(scroll-page-down) (terminal-scroll-display! term (- 1 (terminal-rows term)))]
      [(scroll-half-page-up) (terminal-scroll-display! term (quotient (terminal-rows term) 2))]
      [(scroll-half-page-down) (terminal-scroll-display! term (- (quotient (terminal-rows term) 2)))]
      [(scroll-line-up) (terminal-scroll-display! term 1)]
      [(scroll-line-down) (terminal-scroll-display! term -1)]
      [(scroll-to-top) (terminal-scroll-display! term (grid-hist-count (terminal-grid term)))]
      [(scroll-to-bottom) (terminal-scroll-to-bottom! term)]
      [(scroll-to-previous-prompt) (scroll-to-prompt! -1)]
      [(scroll-to-next-prompt) (scroll-to-prompt! 1)]
      [(clear-history) (terminal-clear-history! term)]
      [(clear-selection) (terminal-selection-clear! term)]
      [(reset) (terminal-reset! term)]
      [(spawn-new-instance) (spawn-new-instance!)]
      [(toggle-fullscreen) (window-toggle-fullscreen! win)]
      [(search-forward) (start-search! #f)]
      [(search-backward) (start-search! #t)]
      [(hint-open hint-copy hint-paste hint-select) (start-hints! action)]
      [(quit) (set! quit? #t)]
      [(none) (void)]
      [else
       (cond
         [(string? action) (send! action)]
         [else (warn "unknown action ~s" action)])]))

  ;; Put the previous or next prompt (OSC 133;A) at the top of the view.
  (define (scroll-to-prompt! dir)
    (let ([offset (prompt-view-offset term dir)])
      (when offset
        (terminal-scroll-display! term (- offset (terminal-display-offset term))))))

  ;; Open URI with the open-command, the URI appended as its last argument
  ;; (as Alacritty's hint command).
  (define (open-uri! uri)
    (let ([cmd (config-ref 'open-command)])
      (if (and (pair? cmd) (for-all string? cmd))
          (spawn-detached (append cmd (list uri)) #f)
          (warn "invalid open-command ~s: a list of strings needed" cmd))))

  (define last-bell -1000)

  ;; BEL: flash the window (the visual bell), mark it as urgent while it is
  ;; not focused (bell-urgent, as foot's bell.urgent, unless a program
  ;; turned that off with CSI ? 1042 l), and run the configured bell
  ;; command, at most every 100 ms
  (define (ring-bell!)
    (let ([cmd (config-ref 'bell-command)] [t (now-ms)] [duration (config-ref 'bell-duration)])
      (when (and (real? duration) (> duration 0))
        (set! bell-start t)
        (set! need-redraw #t))
      (when (and (not focused) (config-ref 'bell-urgent) (terminal-urgent-on-bell? term))
        (window-set-urgent! win))
      (when (and cmd (> (- t last-bell) 100))
        (set! last-bell t)
        (spawn-detached (if (string? cmd) (list cmd) cmd) #f))))

  ;; OSC 52 query for selection LETTER, meaning WHICH ('clipboard or
  ;; 'primary).  With (clipboard-read allow) the text is read like a paste
  ;; and sent back base64 encoded; otherwise, and when there is no text,
  ;; the reply is empty, as kitty answers a denied read, so that programs
  ;; need not wait for a reply that never comes.
  (define (clipboard-read! letter which terminator)
    (case (config-ref 'clipboard-read)
      [(allow) (window-request-paste! win which (list 'osc52 letter terminator))]
      [(deny) (send! (osc52-reply letter "" terminator))]
      [else
       (warn "invalid clipboard-read ~s: allow or deny" (config-ref 'clipboard-read))
       (send! (osc52-reply letter "" terminator))]))

  (define (spawn-new-instance!)
    (let ([exe (or (getenv "CHEZTERM_EXE") "chezterm")]
          [cwd (or (let ([uri (terminal-cwd-uri term)]) (and uri (uri-local-path uri hostname)))
                   (and child-pid (process-cwd child-pid)))])
      (spawn-detached (list exe) cwd)))

  ;; Bindings match Shift, Alt, Ctrl and Super only.
  (define (find-binding ev)
    (let* ([mods (key-event-legacy-mods ev)]
           [sym (keysym-lower (key-event-sym ev))]
           [b (find (lambda (b) (and (= (caar b) mods) (= (cdar b) sym))) bindings)])
      (and b (cdr b))))

  ;;; Keyboard -----------------------------------------------------------------------------

  ;; Handle a key press or repeat; #t when chezterm consumed it.
  (define (key-press! ev)
    (cond
      [hints (hint-key-press! ev) #t]
      [search-active (search-key! ev) #t]
      [(find-binding ev) => (lambda (action) (run-action! action) #t)]
      [else (send-key! ev) #f]))

  (define (send-key! ev)
    (let ([bytes (encode-key ev (terminal-app-cursor? term) (terminal-app-keypad? term)
                             (terminal-newline-mode? term) (terminal-keyboard-flags term)
                             (and (config-ref 'kitty-keyboard)
                                  (config-ref 'kitty-keyboard-legacy-csi-u)))])
      (when bytes
        ;; modifier keys and releases (kitty keyboard protocol) keep the view
        (unless (or (= (key-event-type ev) KEY-RELEASE) (key-event-modifier-key? ev))
          (terminal-scroll-to-bottom! term)
          (reset-blink!)
          (typing!))
        (send! bytes))))

  (define (key-release! key ev)
    (let-values ([(keys report?) (reported-after-release reported-keys key)])
      (set! reported-keys keys)
      (when (and report? ev) (send-key! ev))))

  ;;; Mouse --------------------------------------------------------------------------------

  ;; With mouse-hide-when-typing, the pointer is hidden while typing, as in
  ;; Alacritty: when a key other than a modifier is sent to the program,
  ;; on a paste and when a search is typed.  It shows again when it moves,
  ;; a button is pressed or the wheel turns.
  (define (typing!)
    (when (and pointer-inside (config-ref 'mouse-hide-when-typing))
      (window-hide-cursor! win #t)))

  (define (show-pointer!) (window-hide-cursor! win #f))

  (define (mouse-reporting?)
    (and (terminal-mouse-mode term)
         (not (logtest (keyboard-mods (window-keyboard win)) MOD-SHIFT))))

  (define (mouse-mods)
    (let ([m (keyboard-mods (window-keyboard win))])
      (+ (if (logtest m MOD-SHIFT) 4 0) (if (logtest m MOD-ALT) 8 0) (if (logtest m MOD-CTRL) 16 0))))

  (define (report-mouse! code col row release?)
    (let ([code (+ code (mouse-mods))] [x (+ col 1)] [y (+ row 1)])
      (cond
        [(terminal-mouse-sgr? term)
         (send! (format "\x1b;[<~a;~a;~a~a" code x y (if release? "m" "M")))]
        [else
         (let* ([code (if release? (+ 3 (- code (logand code 3))) code)]
                [enc (lambda (v)
                       (let ([v (+ 32 v)])
                         (if (terminal-mouse-utf8? term)
                             (string (integer->char (min v 2047)))
                             (string (integer->char (min v 255))))))])
           (when (or (terminal-mouse-utf8? term) (and (<= x 223) (<= y 223)))
             (send! (let ([s (string-append "\x1b;[M" (enc code) (enc x) (enc y))])
                      (if (terminal-mouse-utf8? term)
                          s
                          ;; raw bytes, not UTF-8
                          (u8-list->bytevector (map char->integer (string->list s))))))))])))

  (define (pointer-view-cell)
    (let* ([cw (font-cell-width font)] [ch (font-cell-height font)]
           [px (- (* mouse-x scale) (* pad-x scale))] [py (- (* mouse-y scale) (* pad-y scale))])
      (cons (max 0 (min (- (terminal-rows term) 1) (exact (floor (/ py ch)))))
            (max 0 (min (- (terminal-cols term) 1) (exact (floor (/ px cw))))))))

  (define (button-code button)
    (cond [(= button BTN-LEFT) 0] [(= button BTN-MIDDLE) 1] [(= button BTN-RIGHT) 2] [else #f]))

  (define (pointer-button! button pressed?)
    (show-pointer!)
    (set! mouse-buttons (if pressed? (cons button mouse-buttons) (remv button mouse-buttons)))
    (let ([cell (pointer-view-cell)])
      (cond
        [(mouse-reporting?)
         (let ([code (button-code button)])
           (when code
             (report-mouse! code (cdr cell) (car cell) (not pressed?))
             (set! last-mouse-cell cell)))]
        [(= button BTN-LEFT)
         (if pressed?
             (let* ([t (now-ms)]
                    [pt (point->cell mouse-x mouse-y)]
                    [ctrl (logtest (keyboard-mods (window-keyboard win)) MOD-CTRL)])
               (set! click-count (if (and (< (- t last-click-time) 400) (equal? pt last-click-cell))
                                     (+ 1 (modulo click-count 3))
                                     1))
               (set! last-click-time t)
               (set! last-click-cell pt)
               (cond
                 [(and ctrl (= click-count 1)
                       (let ([url (url-at term pt)]) (and url (uri-to-open url hostname))))
                  => open-uri!]
                 [else
                  (set! select-anchor pt)
                  (set! select-block ctrl)
                  (case click-count
                    [(1) (set! selecting 'char) (terminal-selection-clear! term)]
                    [(2) (set! selecting 'word) (update-selection! pt)]
                    [(3) (set! selecting 'line) (update-selection! pt)])]))
             (begin
               (when (and selecting (config-ref 'copy-on-select)) (copy-selection! 'primary))
               (set! selecting #f)))]
        [(and (= button BTN-MIDDLE) pressed?)
         (window-request-paste! win 'primary)]
        [(and (= button BTN-RIGHT) pressed? (terminal-selection term))
         ;; extend the existing selection to the pointer
         (let* ([sel (terminal-selection term)] [pt (point->cell mouse-x mouse-y)]
                [a (cons (vector-ref sel 1) (vector-ref sel 2))]
                [b (cons (vector-ref sel 3) (vector-ref sel 4))]
                [lo (if (point<? a b) a b)] [hi (if (point<? a b) b a)])
           (set-sel! (car (if (point<? pt lo) hi lo)) (cdr (if (point<? pt lo) hi lo)) (car pt) (cdr pt))
           (when (config-ref 'copy-on-select) (copy-selection! 'primary)))]
        [else (void)])))

  ;; Hovering an OSC 8 link or a URL in the text with Ctrl held underlines
  ;; all of it (on screen), also where it wraps, and shows a hand when a
  ;; click would open it.  As with url-at, a link comes first.
  (define (update-hover!)
    (let-values ([(id url)
                  (if (and pointer-inside (not (mouse-reporting?))
                           (logtest (keyboard-mods (window-keyboard win)) MOD-CTRL))
                      (let* ([pt (point->cell mouse-x mouse-y)]
                             [id (link-id-at term pt)]
                             [uri (terminal-link-uri term id)])
                        (if uri
                            (values (if (uri-to-open uri hostname) id 0) #f)
                            (let ([t (text-url-target-at term pt)])
                              (values 0 (and t (uri-to-open (target-uri t) hostname) t)))))
                      (values 0 #f))])
      (unless (and (= id hover-link) (equal? (target-key url) (target-key hover-url)))
        (set! hover-link id)
        (set! hover-url url)
        (set! need-redraw #t))
      (when pointer-inside
        (window-set-cursor! win (cond [(mouse-reporting?) 'default]
                                      [(or (> id 0) url) 'pointer]
                                      [else 'text])))))

  (define (target-key t) (and t (list (target-uri t) (target-start t) (target-end t))))

  (define (pointer-motion! x y)
    (show-pointer!)
    (set! mouse-x x)
    (set! mouse-y y)
    (set! pointer-inside #t)
    (update-hover!)
    (let ([cell (pointer-view-cell)])
      (cond
        [(mouse-reporting?)
         (let ([mode (terminal-mouse-mode term)])
           (unless (equal? cell last-mouse-cell)
             (set! last-mouse-cell cell)
             (cond
               [(and (memq mode '(drag motion)) (pair? mouse-buttons))
                (let ([code (button-code (car mouse-buttons))])
                  (when code (report-mouse! (+ 32 code) (cdr cell) (car cell) #f)))]
               [(eq? mode 'motion) (report-mouse! 35 (cdr cell) (car cell) #f)])))]
        [selecting
         ;; auto-scroll when dragging past the top or bottom
         (let ([vr (view-row-of-pointer)])
           (cond [(< vr 0) (terminal-scroll-display! term 1)]
                 [(>= vr (terminal-rows term)) (terminal-scroll-display! term -1)]))
         (let ([pt (point->cell x y)])
           (when (or (not (eq? selecting 'char)) (not (equal? pt select-anchor)) (terminal-selection term))
             (update-selection! pt)))])))

  (define (scroll! amount discrete?)
    ;; amount: wheel steps when discrete?, else surface pixels
    (show-pointer!)
    (let ([lines (if discrete?
                     (* amount (config-ref 'scroll-multiplier))
                     (begin
                       (set! smooth-scroll-acc (+ smooth-scroll-acc (* amount scale)))
                       (let ([n (truncate (/ smooth-scroll-acc (font-cell-height font)))])
                         (set! smooth-scroll-acc (- smooth-scroll-acc (* n (font-cell-height font))))
                         (exact n))))])
      (unless (= lines 0)
        (cond
          [(mouse-reporting?)
           (let ([cell (pointer-view-cell)] [code (if (< lines 0) 64 65)])
             (do ([i 0 (+ i 1)]) ((= i (min 10 (abs (if discrete? amount lines)))))
               (report-mouse! code (cdr cell) (car cell) #f)))]
          [(and (terminal-alt-screen? term) (terminal-alternate-scroll? term)
                (config-ref 'alternate-scroll))
           (let ([seq (if (terminal-app-cursor? term)
                          (if (< lines 0) "\x1b;OA" "\x1b;OB")
                          (if (< lines 0) "\x1b;[A" "\x1b;[B"))])
             (do ([i 0 (+ i 1)]) ((= i (abs lines))) (send! seq)))]
          [else (terminal-scroll-display! term (- lines))]))))

  ;;; Window events -------------------------------------------------------------------------

  (define debug? (getenv "CHEZTERM_DEBUG"))

  (define (on-window-event type . args)
    (when debug? (warn "event ~s ~s" type args))
    (case type
      [(configure)
       (let ([w (car args)] [h (cadr args)])
         (unless (and (> w 0) (> h 0) (= w logical-width) (= h logical-height))
           (when (and (> w 0) (> h 0))
             (set! logical-width w)
             (set! logical-height h))
           (relayout!))
         (set! need-redraw #t))]
      [(close) (set! quit? #t)]
      [(scale)
       (let ([s (car args)])
         (unless (= s scale)
           (set! scale s)
           (set-font! font-size s)))]
      [(focus)
       ;; Keys held while the focus leaves get no release, as in kitty and
       ;; foot, and neither do keys pressed while it is away, as in kitty
       (set! focused (car args))
       (set! reported-keys '())
       (unless focused (set! repeat-key #f))
       (update-hover!)
       (when (terminal-focus-events? term) (send! (if focused "\x1b;[I" "\x1b;[O")))
       (set! need-redraw #t)]
      [(key-press)
       (let ([ev (car args)] [key (cadr args)])
         (cond
           [(not ev) (set! reported-keys (reported-after-press reported-keys key #f))] ; composing
           [else
            ;; keys typed in hint mode do not repeat: a repeat would reach
            ;; the program once the key ended hint mode
            (let ([hint-key? hints])
              (set! reported-keys (reported-after-press reported-keys key
                                                        (not (or (key-press! ev) (key-event-composed? ev)))))
              (if (and (not hint-key?)
                       (keyboard-repeats? (window-keyboard win) key) (> (window-repeat-rate win) 0))
                  (begin
                    (set! repeat-key key)
                    (set! repeat-event (key-event-with-type ev KEY-REPEAT))
                    (set! repeat-next (+ (now-ms) (window-repeat-delay win))))
                  (set! repeat-key #f)))]))]
      [(key-release)
       (let ([key (car args)])
         (when (eqv? key repeat-key) (set! repeat-key #f))
         (key-release! key (cadr args)))]
      [(pointer-enter) (pointer-motion! (car args) (cadr args))]
      [(pointer-leave) (set! pointer-inside #f) (update-hover!)]
      [(modifiers) (update-hover!)]
      [(pointer-motion) (pointer-motion! (car args) (cadr args))]
      [(pointer-button) (pointer-button! (car args) (cadr args))]
      [(scroll) (when (= (car args) 0) (scroll! (cadr args) (caddr args)))]
      [(paste)
       (let ([text (cadr args)] [tag (caddr args)])
         (if (and (pair? tag) (eq? (car tag) 'osc52))
             (send! (osc52-reply (cadr tag) (or text "") (caddr tag)))
             (when text (paste-text! text))))]
      [(frame) (void)]
      [else (void)]))

  ;;; Main loop --------------------------------------------------------------------------------

  (define pollfds-capacity 16)
  (define pollfds (malloc (* 8 pollfds-capacity)))

  (define (ensure-pollfds! n)
    (when (> n pollfds-capacity)
      (free pollfds)
      (set! pollfds-capacity (* 2 n))
      (set! pollfds (malloc (* 8 pollfds-capacity)))))

  (define (compute-timeout now)
    (let* ([ts '()]
           [ts (if repeat-key (cons (max 0 (- repeat-next now)) ts) ts)]
           [ts (if (and (terminal-cursor-blink? term) focused (terminal-cursor-visible? term))
                   (cons (max 0 (- blink-next now)) ts) ts)]
           [ts (if (terminal-sync-update? term) (cons sync-timeout ts) ts)]
           [ts (if (and backlog (or need-redraw (terminal-dirty? term)))
                   (cons (max 0 (- backlog-next-frame now)) ts) ts)]
           [ts (if dump-frame (cons 50 ts) ts)])
      (if (null? ts) -1 (apply min ts))))

  (define (handle-timers! now)
    (when (and repeat-key (>= now repeat-next))
      (key-press! repeat-event)
      (set! repeat-next (+ now (quotient 1000 (max 1 (window-repeat-rate win))))))
    (when (and (terminal-cursor-blink? term) (>= now blink-next))
      (set! blink-on (not blink-on))
      (set! blink-next (+ now (config-ref 'cursor-blink-interval)))
      (set! need-redraw #t)))

  (define (set-pollfd! i fd events)
    (let ([p (make-ftype-pointer pollfd (+ pollfds (* 8 i)))])
      (ftype-set! pollfd (fd) p fd)
      (ftype-set! pollfd (events) p events)
      (ftype-set! pollfd (revents) p 0)))

  (define (pollfd-revents i)
    (ftype-ref pollfd (revents) (make-ftype-pointer pollfd (+ pollfds (* 8 i)))))

  (define (main-loop!)
    (let ([wl-fd (window-display-fd win)])
      (let loop ()
        (window-dispatch! win)
        (flush-writes!)
        (maybe-draw!)
        (window-flush! win)
        (unless quit?
          (if (not (window-prepare-read! win))
              (loop)
              (let* ([extra (window-poll-fds win)]
                     [pty-active (and pty-fd (not child-exited))]
                     [n 0])
                (set-pollfd! 0 wl-fd POLLIN)
                (set! n 1)
                (when pty-active
                  (set-pollfd! 1 pty-fd (logor POLLIN (if (pair? write-queue) POLLOUT 0)))
                  (set! n 2))
                (let ([first-extra n]
                      [extra (if config-watch-fd (cons config-watch-fd extra) extra)])
                  (ensure-pollfds! (+ n (length extra)))
                  (for-each (lambda (fd) (set-pollfd! n fd POLLIN) (set! n (+ n 1))) extra)
                  (let ([r (poll pollfds n (compute-timeout (now-ms)))])
                    (if (and (> r 0) (logtest (pollfd-revents 0) (logor POLLIN POLLERR POLLHUP)))
                        (window-read-events! win)
                        (window-cancel-read! win))
                    (window-dispatch! win)
                    (when (and (> r 0) pty-active)
                      (let ([rev (pollfd-revents 1)])
                        (when (logtest rev POLLOUT) (flush-writes!))
                        (when (logtest rev (logor POLLIN POLLHUP POLLERR))
                          (unless (read-pty!) (child-exited!)))))
                    (when (> r 0)
                      (let floop ([fds extra] [i first-extra])
                        (unless (null? fds)
                          (unless (= 0 (pollfd-revents i))
                            (if (eqv? (car fds) config-watch-fd)
                                (config-watch-ready!)
                                (window-fd-ready! win (car fds))))
                          (floop (cdr fds) (+ i 1)))))
                    (handle-timers! (now-ms))
                    (when dump-frame (check-dump-frame!))
                    (loop)))))))))

  (define (child-exited!)
    (set! child-exited #t)
    (close pty-fd)
    (set! pty-fd #f)
    (set! write-queue '())
    (pty-child-exited? child-pid)
    (if hold?
        (begin
          (let ([msg (string->utf8 "\r\n[process exited]")])
            (terminal-feed! term msg (bytevector-length msg)))
          (terminal-dirty-set! term #t))
        (unless dump-frame (set! quit? #t))))

  ;;; Command line ---------------------------------------------------------------------------

  (define usage
    "Usage: chezterm [options] [-e command [args...]]

Options:
  -e, --command CMD ARGS...  run CMD instead of the shell
  -T, --title TITLE          window title
      --class APP_ID         Wayland app-id
  -d, --working-directory D  start in directory D
      --config-file FILE     configuration file to use
      --hold                 keep the window open after the command exits
  -o, --option KEY=VALUE     override a configuration option (Scheme syntax)
  -h, --help                 show this help
  -v, --version              show version
")

  (define (parse-args args)
    ;; returns alist
    (let loop ([args args] [acc '()])
      (cond
        [(null? args) acc]
        [(member (car args) '("-e" "--command"))
         (cons (cons 'command (cdr args)) acc)]
        [(member (car args) '("-h" "--help")) (display usage) (exit 0)]
        [(member (car args) '("-v" "--version")) (printf "chezterm ~a\n" version) (exit 0)]
        [(member (car args) '("--hold")) (loop (cdr args) (cons '(hold . #t) acc))]
        [(and (pair? (cdr args)) (member (car args) '("-T" "--title")))
         (loop (cddr args) (cons (cons 'title (cadr args)) acc))]
        [(and (pair? (cdr args)) (member (car args) '("--class")))
         (loop (cddr args) (cons (cons 'app-id (cadr args)) acc))]
        [(and (pair? (cdr args)) (member (car args) '("-d" "--working-directory")))
         (loop (cddr args) (cons (cons 'cwd (cadr args)) acc))]
        [(and (pair? (cdr args)) (member (car args) '("--config-file")))
         (loop (cddr args) (cons (cons 'config (cadr args)) acc))]
        [(and (pair? (cdr args)) (member (car args) '("-o" "--option")))
         (loop (cddr args) (cons (cons 'option (cadr args)) acc))]
        [(and (pair? (cdr args)) (member (car args) '("--dump-frame")))
         (loop (cddr args) (cons (cons 'dump-frame (cadr args)) acc))]
        [else (warn "unknown argument ~a" (car args)) (display usage (current-error-port)) (exit 2)])))

  (define (apply-option-overrides! opts)
    ;; -o key=value : parsed as a config form (key value)
    (for-each
     (lambda (o)
       (when (eq? (car o) 'option)
         (let* ([s (cdr o)]
                [i (let find ([i 0]) (cond [(= i (string-length s)) #f]
                                           [(char=? (string-ref s i) #\=) i]
                                           [else (find (+ i 1))]))])
           (if i
               (set-config-override! (string->symbol (substring s 0 i))
                                     (read (open-input-string (substring s (+ i 1) (string-length s)))))
               (warn "invalid option ~a" s)))))
     opts))

  (define overrides '())
  (define (set-config-override! k v)
    ;; KEY=(a b) means the config form (KEY a b), KEY=x means (KEY x)
    (set! overrides (cons (config-normalize (cons k (if (list? v) v (list v)))) overrides)))

  ;;; Entry point ----------------------------------------------------------------------------

  (define (run args)
    (let* ([opts (parse-args args)]
           [opt (lambda (k) (let ([e (assq k opts)]) (and e (cdr e))))])
      (set! config-file (or (opt 'config) (config-path)))
      (load-config config-file)
      (apply-option-overrides! opts)
      (when (pair? overrides) (install-overrides!))
      (init-charwidth!)
      (load-bindings!)
      (set! hold? (opt 'hold))
      (set! hostname (host-name))
      (set! start-time (now-ms))
      (let ([d (opt 'dump-frame)])
        (when d
          (let ([parts (let ([i (let f ([i 0]) (cond [(= i (string-length d)) #f]
                                                     [(char=? (string-ref d i) #\:) i]
                                                     [else (f (+ i 1))]))])
                         (if i (cons (substring d 0 i) (string->number (substring d (+ i 1) (string-length d))))
                             (cons d 500)))])
            (set! dump-frame parts))))
      (set! font-size (inexact (config-ref 'font-size)))
      (read-padding!)
      (set! font (make-font-at font-size 1))
      (let* ([cols (config-ref 'columns)] [rows (config-ref 'lines)]
             [palette (build-palette)])
        (set! logical-width (+ (* 2 pad-x) (* cols (font-cell-width font))))
        (set! logical-height (+ (* 2 pad-y) (* rows (font-cell-height font))))
        (set! term (make-terminal rows cols (config-ref 'scrollback) palette
                                  (config-ref 'cursor-style) (config-ref 'cursor-blink)))
        (terminal-set-cell-pixel-size! term (font-cell-width font) (font-cell-height font))
        (terminal-set-kitty-keyboard! term (config-ref 'kitty-keyboard))
        (set! renderer (create-renderer font))
        (set! win (open-window on-window-event (or (opt 'title) (config-ref 'title))
                               (or (opt 'app-id) (config-ref 'app-id))
                               logical-width logical-height (config-ref 'decorations)))
        (unless (= 1 (window-scale win))
          (set! scale (window-scale win))
          (set! font (make-font-at font-size scale))
          (renderer-set-font! renderer font)
          (renderer-set-padding! renderer (* scale pad-x) (* scale pad-y)))
        (window-set-min-size! win (+ (* 2 pad-x) (* 2 (quotient (font-cell-width font) scale)))
                              (+ (* 2 pad-y) (quotient (font-cell-height font) scale)))
        (terminal-set-callbacks! term
          send!
          (lambda (title) (when (config-ref 'dynamic-title) (window-set-title! win title)))
          ring-bell!
          (lambda (text) (window-set-clipboard! win 'clipboard text)))
        (terminal-set-clipboard-read-handler! term clipboard-read!)
        (let ([program (or (opt 'command)
                           (let ([sh (config-ref 'shell)])
                             (if sh
                                 (if (string? sh) (list sh) sh)
                                 (list (default-shell)))))])
          (let-values ([(fd pid) (pty-spawn program rows cols
                                            (* cols (font-cell-width font))
                                            (* rows (font-cell-height font))
                                            (or (opt 'cwd) (config-ref 'working-directory))
                                            (append (term-environment (config-ref 'term)
                                                                      (getenv "CHEZTERM_TERMINFO")
                                                                      getenv file-exists?)
                                                    `(("COLORTERM" . "truecolor")
                                                      ("TERM_PROGRAM" . "chezterm")
                                                      ("TERM_PROGRAM_VERSION" . ,version))
                                                    (map (lambda (kv) (cons (car kv) (cdr kv)))
                                                         (config-ref 'env))))])
            (set! pty-fd fd)
            (set! child-pid pid)))
        (let ([ok (guard (e [#t (let ([p (current-error-port)])
                                  (display "chezterm: fatal error: " p)
                                  (display-condition e p)
                                  (newline p))
                                #f])
                    (watch-config!)
                    (main-loop!)
                    #t)])
          (when (and pty-fd (not child-exited)) (pty-hangup! pty-fd child-pid))
          (window-close! win)
          (unless ok (exit 1))))))

  (define (install-overrides!)
    ;; make command-line overrides visible through config-ref
    (set-config-overrides! overrides)))
