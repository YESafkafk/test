;;; The application: ties together window, terminal, renderer and pty, and
;;; implements the event loop, input handling, selection, clipboard,
;;; key bindings, scrollback search and font resizing.
(library (chezterm app)
  (export run)
  (import (chezscheme) (chezterm ffi) (chezterm cutil) (chezterm config)
          (chezterm charwidth) (chezterm grid) (chezterm terminal) (chezterm font)
          (chezterm render) (chezterm keyboard) (chezterm window) (chezterm pty))

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

  (define bindings '())           ; list of ((mods . sym) . action)

  ;; key repeat
  (define repeat-key #f)          ; evdev keycode
  (define repeat-event #f)
  (define repeat-next 0)

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

  ;; search
  (define search-active #f)
  (define search-backward #t)
  (define search-query "")
  (define search-match #f)        ; #(abs c0 c1)

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
    (let loop ([k 0])
      (if (>= k 16)
          #t
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
      (let ([cols (renderer-cols renderer)] [rows (renderer-rows renderer)])
        (unless (and (= cols (terminal-cols term)) (= rows (terminal-rows term)))
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

  (define (maybe-draw!)
    (when (and (window-can-present? win)
               (or need-redraw (terminal-dirty? term))
               (not (sync-hold?)))
      (set! need-redraw #f)
      (terminal-dirty-set! term #f)
      (let ([damage (renderer-render! renderer term focused blink-on search-highlights
                                      (and search-active (search-overlay)))])
        (unless (null? damage)
          (window-present! win (renderer-pixels renderer) (renderer-width renderer)
                           (renderer-height renderer) damage
                           (< (config-ref 'opacity) 1.0))))
      (when dump-frame (check-dump-frame!))))

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

  (define (line-at-abs abs)
    (let ([row (terminal-rel-row term abs)] [g (terminal-grid term)])
      (and (>= row (- (grid-hist-count g))) (< row (grid-rows g))
           (grid-line g row))))

  (define (cell-char l col)
    (let ([v (line-cells l)])
      (if (or (< col 0) (>= col (line-cols l))) #\space
          (let ([c (cell-ch v col)]) (if (= c 0) #\space (integer->char c))))))

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

  (define (word-char? c)
    (not (or (char=? c #\space)
             (memv c (string->list (config-ref 'word-separators))))))

  (define (word-bounds abs col)
    (let ([l (line-at-abs abs)])
      (if (not l)
          (cons col col)
          (let ([ch (cell-char l col)] [cols (line-cols l)])
            (if (not (word-char? ch))
                (cons col col)
                (let ([start (let loop ([c col])
                               (if (and (> c 0) (word-char? (cell-char l (- c 1)))) (loop (- c 1)) c))]
                      [end (let loop ([c col])
                             (if (and (< c (- cols 1)) (word-char? (cell-char l (+ c 1)))) (loop (+ c 1)) c))])
                  (cons start end)))))))

  ;; start/end rows of the logical (wrapped) line containing ABS
  (define (logical-line-bounds abs)
    (let ([start (let loop ([a abs])
                   (let ([prev (line-at-abs (- a 1))])
                     (if (and prev (line-wrapped prev)) (loop (- a 1)) a)))]
          [end (let loop ([a abs])
                 (let ([l (line-at-abs a)])
                   (if (and l (line-wrapped l) (line-at-abs (+ a 1))) (loop (+ a 1)) a)))])
      (cons start end)))

  (define (point<? a b) (or (< (car a) (car b)) (and (= (car a) (car b)) (< (cdr a) (cdr b)))))

  (define (update-selection! pt)
    (let* ([anchor select-anchor]
           [forward (not (point<? pt anchor))]
           [a anchor] [b pt])
      (case selecting
        [(word)
         (let* ([wa (word-bounds (car a) (cdr a))] [wb (word-bounds (car b) (cdr b))])
           (if forward
               (set-sel! (car a) (car wa) (car b) (cdr wb))
               (set-sel! (car a) (cdr wa) (car b) (car wb))))]
        [(line)
         (let ([la (logical-line-bounds (car a))] [lb (logical-line-bounds (car b))]
               [last (- (terminal-cols term) 1)])
           (if forward
               (set-sel! (car la) 0 (cdr lb) last)
               (set-sel! (cdr la) last (car lb) 0)))]
        [else (set-sel! (car a) (cdr a) (car b) (cdr b))])))

  (define (set-sel! a ac b bc)
    (terminal-set-selection! term (vector (if select-block 'block 'stream) a ac b bc)))

  ;; Text of the current selection.
  (define (selection-text)
    (let ([sel (terminal-selection term)])
      (and sel
           (let* ([sa (vector-ref sel 1)] [sc (vector-ref sel 2)]
                  [ea (vector-ref sel 3)] [ec (vector-ref sel 4)]
                  [forward (or (< sa ea) (and (= sa ea) (<= sc ec)))]
                  [r0 (if forward sa ea)] [c0 (if forward sc ec)]
                  [r1 (if forward ea sa)] [c1 (if forward ec sc)]
                  [block (eq? (vector-ref sel 0) 'block)]
                  [out (open-output-string)])
             (let loop ([abs r0])
               (when (<= abs r1)
                 (let ([l (line-at-abs abs)])
                   (when l
                     (let* ([cols (line-cols l)]
                            [from (cond [block (min sc ec)] [(= abs r0) c0] [else 0])]
                            [to (cond [block (+ 1 (max sc ec))] [(= abs r1) (+ c1 1)] [else cols])]
                            [to (min to cols)]
                            [content (line-content-length l)]
                            [trimmed-to (if (or block (not (line-wrapped l)) (= abs r1)) (min to content) to)])
                       (write-string (line-text l from trimmed-to) out)
                       (when (and (< abs r1) (or block (not (line-wrapped l))))
                         (newline out)))))
                 (loop (+ abs 1))))
             (let ([s (get-output-string out)])
               (and (> (string-length s) 0) s))))))

  (define (line-text l from to)
    (let ([v (line-cells l)] [ex (line-extra l)] [out (open-output-string)])
      (do ([i from (+ i 1)]) ((>= i to))
        (unless (fxlogtest (cell-attrs v i) ATTR-SPACER)
          (let ([c (cell-ch v i)])
            (write-char (if (= c 0) #\space (integer->char c)) out)
            (let ([marks (and ex (hashtable-ref ex i #f))])
              (when marks (write-string marks out))))))
      (get-output-string out)))

  (define (write-string s port) (put-string port s))

  (define (copy-selection! which)
    (let ([text (selection-text)])
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
      (if (terminal-bracketed-paste? term)
          (send! (string-append "\x1b;[200~" normalized "\x1b;[201~"))
          (send! normalized))))

  ;;; Search -------------------------------------------------------------------------------

  (define (smart-case-equal? query)
    (if (string=? query (string-downcase query)) char-ci=? char=?))

  ;; Matches of the search query in absolute row ABS: list of (c0 c1)
  ;; (cell columns, end exclusive).
  (define (line-matches abs)
    (let ([l (line-at-abs abs)] [q search-query])
      (if (or (not l) (= 0 (string-length q)))
          '()
          (let* ([v (line-cells l)] [cols (line-cols l)]
                 ;; text and the column of each character
                 [chars (let loop ([i (- cols 1)] [acc '()])
                          (if (< i 0) acc
                              (loop (- i 1)
                                    (if (fxlogtest (cell-attrs v i) ATTR-SPACER)
                                        acc
                                        (cons (cons (cell-char l i) i) acc)))))]
                 [text (list->vector chars)]
                 [n (vector-length text)] [m (string-length q)]
                 [eq (smart-case-equal? q)])
            (let loop ([i 0] [acc '()])
              (if (> (+ i m) n)
                  (reverse acc)
                  (if (let check ([k 0])
                        (or (= k m)
                            (and (eq (car (vector-ref text (+ i k))) (string-ref q k))
                                 (check (+ k 1)))))
                      (let* ([c0 (cdr (vector-ref text i))]
                             [last (vector-ref text (+ i m -1))]
                             [c1 (+ (cdr last) (if (fxlogtest (cell-attrs v (cdr last)) ATTR-WIDE) 2 1))])
                        (loop (+ i m) (cons (list c0 c1) acc)))
                      (loop (+ i 1) acc))))))))

  (define (search-highlights abs)
    (if (and search-active (> (string-length search-query) 0))
        (map (lambda (m)
               (list (car m) (cadr m)
                     (and search-match (= abs (vector-ref search-match 0))
                          (= (car m) (vector-ref search-match 1)))))
             (line-matches abs))
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
          (let* ([ms (line-matches abs)]
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

  (define (start-search! backward?)
    (set! search-active #t)
    (set! search-backward backward?)
    (set! search-match #f)
    (set! need-redraw #t))

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
         (set! search-query (string-append search-query text))
         (search-step! search-backward #t)
         (set! need-redraw #t)]
        [else (void)])))

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
      [(clear-history) (terminal-clear-history! term)]
      [(clear-selection) (terminal-selection-clear! term)]
      [(reset) (terminal-reset! term)]
      [(spawn-new-instance) (spawn-new-instance!)]
      [(toggle-fullscreen) (window-toggle-fullscreen! win)]
      [(search-forward) (start-search! #f)]
      [(search-backward) (start-search! #t)]
      [(quit) (set! quit? #t)]
      [(none) (void)]
      [else
       (cond
         [(string? action) (send! action)]
         [else (warn "unknown action ~s" action)])]))

  (define (spawn-new-instance!)
    (let ([exe (or (getenv "CHEZTERM_EXE") "chezterm")]
          [cwd (or (terminal-cwd term) (and child-pid (process-cwd child-pid)))])
      (spawn-detached (list exe) cwd)))

  (define (find-binding ev)
    (let* ([mods (key-event-mods ev)]
           [sym (keysym-lower (key-event-sym ev))]
           [b (find (lambda (b) (and (= (caar b) mods) (= (cdar b) sym))) bindings)])
      (and b (cdr b))))

  ;;; Keyboard -----------------------------------------------------------------------------

  (define (key-press! ev)
    (cond
      [search-active (search-key! ev)]
      [(find-binding ev) => run-action!]
      [else
       (let ([bytes (encode-key ev (terminal-app-cursor? term) (terminal-app-keypad? term)
                                (terminal-newline-mode? term))])
         (when bytes
           (terminal-scroll-to-bottom! term)
           (reset-blink!)
           (send! bytes)))]))

  ;;; Mouse --------------------------------------------------------------------------------

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
                 [(and ctrl (= click-count 1) (url-at pt))
                  => (lambda (url) (spawn-detached (list "xdg-open" url) #f))]
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

  (define (pointer-motion! x y)
    (set! mouse-x x)
    (set! mouse-y y)
    (window-set-cursor! win (if (mouse-reporting?) 'default 'text))
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

  ;; URL under the pointer (for ctrl+click)
  (define (url-at pt)
    (let ([l (line-at-abs (car pt))])
      (and l
           (let* ([cols (line-cols l)]
                  [text (list->string (map (lambda (i) (cell-char l i)) (iota cols)))]
                  [col (cdr pt)])
             (let loop ([schemes '("https://" "http://" "file://" "ftp://" "mailto:")])
               (and (pair? schemes)
                    (or (let find ([from 0])
                          (let ([i (string-search text (car schemes) from)])
                            (and i
                                 (let ([end (let e ([j i])
                                              (if (and (< j cols)
                                                       (not (memv (string-ref text j)
                                                                  '(#\space #\" #\' #\< #\> #\` #\tab))))
                                                  (e (+ j 1)) j))])
                                   (if (and (<= i col) (< col end))
                                       (string-trim-url (substring text i end))
                                       (find end))))))
                        (loop (cdr schemes)))))))))

  (define (string-search s pat from)
    (let ([n (string-length s)] [m (string-length pat)])
      (let loop ([i from])
        (cond [(> (+ i m) n) #f]
              [(string=? (substring s i (+ i m)) pat) i]
              [else (loop (+ i 1))]))))

  (define (string-trim-url u)
    ;; drop trailing punctuation that is rarely part of a URL
    (let loop ([u u])
      (if (and (> (string-length u) 0)
               (memv (string-ref u (- (string-length u) 1)) '(#\. #\, #\; #\: #\) #\] #\!)))
          (loop (substring u 0 (- (string-length u) 1)))
          u)))

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
       (set! focused (car args))
       (unless focused (set! repeat-key #f))
       (when (terminal-focus-events? term) (send! (if focused "\x1b;[I" "\x1b;[O")))
       (set! need-redraw #t)]
      [(key-press)
       (let ([ev (car args)] [key (cadr args)])
         (key-press! ev)
         (if (and (keyboard-repeats? (window-keyboard win) key) (> (window-repeat-rate win) 0))
             (begin
               (set! repeat-key key)
               (set! repeat-event ev)
               (set! repeat-next (+ (now-ms) (window-repeat-delay win))))
             (set! repeat-key #f)))]
      [(key-release) (when (eqv? (car args) repeat-key) (set! repeat-key #f))]
      [(pointer-enter) (pointer-motion! (car args) (cadr args))]
      [(pointer-leave) (void)]
      [(pointer-motion) (pointer-motion! (car args) (cadr args))]
      [(pointer-button) (pointer-button! (car args) (cadr args))]
      [(scroll) (when (= (car args) 0) (scroll! (cadr args) (caddr args)))]
      [(paste) (when (cadr args) (paste-text! (cadr args)))]
      [(frame) (void)]
      [else (void)]))

  ;;; Main loop --------------------------------------------------------------------------------

  (define pollfds (malloc (* 8 16)))

  (define (compute-timeout now)
    (let* ([ts '()]
           [ts (if repeat-key (cons (max 0 (- repeat-next now)) ts) ts)]
           [ts (if (and (terminal-cursor-blink? term) focused (terminal-cursor-visible? term))
                   (cons (max 0 (- blink-next now)) ts) ts)]
           [ts (if (terminal-sync-update? term) (cons sync-timeout ts) ts)]
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
                (let ([first-extra n])
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
                          (unless (= 0 (pollfd-revents i)) (window-fd-ready! win (car fds)))
                          (floop (cdr fds) (+ i 1)))))
                    (handle-timers! (now-ms))
                    (when dump-frame (check-dump-frame!))
                    (loop)))))))))

  (define (child-exited!)
    (set! child-exited #t)
    (close pty-fd)
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
  (define (set-config-override! k v) (set! overrides (cons (cons k v) overrides)))
  (define (option k) (let ([e (assq k overrides)]) (if e (cdr e) (config-ref k))))

  ;;; Entry point ----------------------------------------------------------------------------

  (define (run args)
    (let* ([opts (parse-args args)]
           [opt (lambda (k) (let ([e (assq k opts)]) (and e (cdr e))))])
      (load-config (or (opt 'config) (config-path)))
      (apply-option-overrides! opts)
      (when (pair? overrides) (install-overrides!))
      (init-charwidth!)
      (load-bindings!)
      (set! hold? (opt 'hold))
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
      (let ([padding (config-ref 'padding)])
        (set! pad-x (car padding))
        (set! pad-y (if (pair? (cdr padding)) (cadr padding) (car padding))))
      (set! font (make-font-at font-size 1))
      (let* ([cols (config-ref 'columns)] [rows (config-ref 'lines)]
             [palette (build-palette)])
        (set! logical-width (+ (* 2 pad-x) (* cols (font-cell-width font))))
        (set! logical-height (+ (* 2 pad-y) (* rows (font-cell-height font))))
        (set! term (make-terminal rows cols (config-ref 'scrollback) palette
                                  (config-ref 'cursor-style) (config-ref 'cursor-blink)))
        (terminal-set-cell-pixel-size! term (font-cell-width font) (font-cell-height font))
        (set! renderer (make-renderer font pad-x pad-y (config-ref 'opacity)
                                      (config-ref 'bold-is-bright)
                                      (color-option 'selection-foreground)
                                      (or (color-option 'selection-background) #x4f4f4f)
                                      (config-ref 'cursor-unfocused-hollow)))
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
          (lambda () (void))
          (lambda (text) (window-set-clipboard! win 'clipboard text)))
        (let ([program (or (opt 'command)
                           (let ([sh (config-ref 'shell)])
                             (if sh
                                 (if (string? sh) (list sh) sh)
                                 (list (default-shell)))))])
          (let-values ([(fd pid) (pty-spawn program rows cols
                                            (* cols (font-cell-width font))
                                            (* rows (font-cell-height font))
                                            (or (opt 'cwd) (config-ref 'working-directory))
                                            (append `(("TERM" . ,(config-ref 'term))
                                                      ("COLORTERM" . "truecolor")
                                                      ("TERM_PROGRAM" . "chezterm")
                                                      ("TERM_PROGRAM_VERSION" . ,version))
                                                    (map (lambda (kv) (cons (car kv) (cdr kv)))
                                                         (config-ref 'env))))])
            (set! pty-fd fd)
            (set! child-pid pid)))
        (main-loop!)
        (when (and pty-fd (not child-exited)) (pty-hangup! pty-fd child-pid))
        (window-close! win))))

  (define (install-overrides!)
    ;; make command-line overrides visible through config-ref
    (set-config-overrides! overrides)))
