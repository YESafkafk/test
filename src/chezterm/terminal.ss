;;; Terminal emulation: escape sequence parser and screen state.
;;;
;;; The parser follows the DEC ANSI state machine (vt100.net/emu/dec_ansi_parser)
;;; operating on Unicode code points decoded from UTF-8.  It implements the
;;; control functions of xterm that modern applications rely on: cursor
;;; movement, erasing, insert/delete, scroll regions, SGR with 256 and direct
;;; colors and underline styles, alternate screen, bracketed paste, mouse
;;; tracking modes, focus events, synchronized output, OSC title / colors /
;;; clipboard, device status and attribute reports, DEC line drawing, the
;;; flags of the kitty keyboard protocol, etc.
(library (chezterm terminal)
  (export make-terminal terminal? terminal-feed! terminal-resize!
          terminal-rows terminal-cols terminal-grid terminal-primary-grid
          terminal-cursor-row terminal-cursor-col terminal-cursor-visible?
          terminal-cursor-style terminal-cursor-blink?
          terminal-palette terminal-default-palette terminal-title
          terminal-alt-screen? terminal-app-cursor? terminal-app-keypad?
          terminal-bracketed-paste? terminal-mouse-mode terminal-mouse-sgr?
          terminal-mouse-utf8? terminal-focus-events? terminal-alternate-scroll?
          terminal-reverse-video? terminal-sync-update? terminal-newline-mode?
          terminal-display-offset terminal-scroll-display! terminal-scroll-to-bottom!
          terminal-selection terminal-set-selection! terminal-selection-clear!
          terminal-abs-row terminal-rel-row
          terminal-set-callbacks! terminal-reset! terminal-clear-history!
          terminal-cwd terminal-dirty? terminal-dirty-set!
          terminal-set-cell-pixel-size! terminal-set-defaults!
          terminal-keyboard-flags terminal-set-kitty-keyboard!
          terminal-link-uri terminal-link-count
          color->rgb make-default-palette)
  (import (chezscheme) (chezterm grid) (chezterm charwidth))

  ;;; Colors ----------------------------------------------------------------

  ;; Palette: 256 indexed colors + default fg, default bg, cursor.
  (define (make-default-palette normal bright fg bg cursor)
    (let ([p (make-vector 259 0)])
      (do ([i 0 (fx+ i 1)]) ((fx= i 8))
        (vector-set! p i (list-ref normal i))
        (vector-set! p (fx+ i 8) (list-ref bright i)))
      (let ([levels '#(0 95 135 175 215 255)])
        (do ([i 0 (fx+ i 1)]) ((fx= i 216))
          (vector-set! p (fx+ 16 i)
                       (fxior (fxsll (vector-ref levels (fxquotient i 36)) 16)
                              (fxsll (vector-ref levels (fxremainder (fxquotient i 6) 6)) 8)
                              (vector-ref levels (fxremainder i 6))))))
      (do ([i 0 (fx+ i 1)]) ((fx= i 24))
        (let ([v (fx+ 8 (fx* 10 i))])
          (vector-set! p (fx+ 232 i) (fxior (fxsll v 16) (fxsll v 8) v))))
      (vector-set! p COLOR-FG fg)
      (vector-set! p COLOR-BG bg)
      (vector-set! p COLOR-CURSOR cursor)
      p))

  (define (color->rgb palette c)
    (if (fxlogtest c COLOR-RGB)
        (fxand c #xFFFFFF)
        (vector-ref palette c)))

  ;;; Terminal state ----------------------------------------------------------

  (define-record-type terminal
    (fields
     (mutable rows) (mutable cols)
     (mutable primary-grid) (mutable alt-grid) (mutable grid)
     (mutable cursor-row) (mutable cursor-col) (mutable wrap-pending)
     (mutable attrs) (mutable fg) (mutable bg)
     (mutable saved-primary) (mutable saved-alt)
     (mutable top) (mutable bottom)
     (mutable tabs)
     ;; modes
     (mutable app-cursor) (mutable app-keypad) (mutable autowrap)
     (mutable origin-mode) (mutable insert-mode) (mutable newline-mode)
     (mutable cursor-visible) (mutable cursor-style) (mutable cursor-blink)
     (mutable alt-screen) (mutable bracketed-paste) (mutable mouse-mode)
     (mutable mouse-sgr) (mutable mouse-utf8) (mutable focus-events)
     (mutable alternate-scroll) (mutable reverse-video) (mutable sync-update)
     ;; charsets
     (mutable charsets) (mutable gl)
     ;; misc
     (mutable title) (mutable title-stack) (mutable cwd)
     (mutable palette) (mutable default-palette)
     (mutable last-char)
     (mutable display-offset)
     (mutable selection)
     (mutable dirty)
     (mutable cell-width) (mutable cell-height)
     ;; callbacks
     (mutable respond) (mutable on-title) (mutable on-bell) (mutable on-clipboard)
     ;; parser
     (mutable state) (mutable utf8-need) (mutable utf8-cp)
     (mutable params) (mutable nparams) (mutable colons) (mutable param-started)
     (mutable private) (mutable intermediates)
     (mutable strbuf) (mutable esc-in-string)
     (mutable default-cursor-style) (mutable default-cursor-blink)
     ;; primary screen cursor while the alternate screen is shown
     (mutable primary-cursor)
     ;; kitty keyboard protocol: whether it is enabled, and the flags
     ;; stacks of the primary and alternate screens (see keyboard-flags!)
     (mutable kitty-keyboard) (mutable kbd-primary) (mutable kbd-alt)
     ;; OSC 8 hyperlinks (see open-link!): id -> URI, (id-param . URI) -> id,
     ;; the next id, the id of the link being printed (0: none), and how many
     ;; more new links to drop before collecting again
     (mutable links) (mutable link-ids) (mutable link-next) (mutable link)
     (mutable link-gc-pause)
     ;; the cell extra printed characters get (see grid.ss), #f for none
     (mutable pen-extra)
     ;; underline color (SGR 58), #f for the foreground
     (mutable ul-color))
    (protocol
     (lambda (new)
       (lambda (rows cols history palette cursor-style cursor-blink)
         (let ([t (new rows cols
                       (make-grid rows cols history) (make-grid rows cols 0) #f
                       0 0 #f
                       0 COLOR-FG COLOR-BG
                       #f #f
                       0 (fx- rows 1)
                       (make-tabs cols)
                       #f #f #t #f #f #f
                       #t cursor-style cursor-blink
                       #f #f #f #f #f #f
                       #t #f #f
                       (vector 'ascii 'ascii 'ascii 'ascii) 0
                       "chezterm" '() #f
                       (vector-copy palette) palette
                       32 0 #f #t 8 16
                       (lambda (s) (void)) (lambda (s) (void)) (lambda () (void))
                       (lambda (s) (void))
                       'ground 0 0
                       (make-fxvector 32 0) 0 (make-bytevector 32 0) #f
                       #f '()
                       (open-output-string) #f
                       cursor-style cursor-blink
                       #f
                       #t '() '()
                       (make-eqv-hashtable) (make-hashtable equal-hash equal?) 1 0 0
                       #f #f)])
           (terminal-grid-set! t (terminal-primary-grid t))
           t)))))

  (define (make-tabs cols)
    (let ([v (make-bytevector cols 0)])
      (do ([i 8 (fx+ i 8)]) ((fx>= i cols) v)
        (bytevector-u8-set! v i 1))))

  (define (terminal-set-callbacks! t respond on-title on-bell on-clipboard)
    (terminal-respond-set! t respond)
    (terminal-on-title-set! t on-title)
    (terminal-on-bell-set! t on-bell)
    (terminal-on-clipboard-set! t on-clipboard))

  ;; Apply new defaults from a configuration reload: palette and cursor.
  ;; Colors changed by the application (OSC 4/10/11/12) are reset.
  (define (terminal-set-defaults! t palette cursor-style cursor-blink)
    (terminal-default-palette-set! t palette)
    (terminal-palette-set! t (vector-copy palette))
    (terminal-default-cursor-style-set! t cursor-style)
    (terminal-default-cursor-blink-set! t cursor-blink)
    (terminal-cursor-style-set! t cursor-style)
    (terminal-cursor-blink-set! t cursor-blink)
    (terminal-dirty-set! t #t))

  (define (terminal-set-cell-pixel-size! t w h)
    (terminal-cell-width-set! t w)
    (terminal-cell-height-set! t h))

  (define (terminal-cursor-visible? t) (terminal-cursor-visible t))
  (define (terminal-cursor-blink? t) (terminal-cursor-blink t))
  (define (terminal-alt-screen? t) (terminal-alt-screen t))
  (define (terminal-app-cursor? t) (terminal-app-cursor t))
  (define (terminal-app-keypad? t) (terminal-app-keypad t))
  (define (terminal-bracketed-paste? t) (terminal-bracketed-paste t))
  (define (terminal-mouse-sgr? t) (terminal-mouse-sgr t))
  (define (terminal-mouse-utf8? t) (terminal-mouse-utf8 t))
  (define (terminal-focus-events? t) (terminal-focus-events t))
  (define (terminal-alternate-scroll? t) (terminal-alternate-scroll t))
  (define (terminal-reverse-video? t) (terminal-reverse-video t))
  (define (terminal-sync-update? t) (terminal-sync-update t))
  (define (terminal-newline-mode? t) (terminal-newline-mode t))
  (define (terminal-dirty? t) (terminal-dirty t))

  ;;; Kitty keyboard protocol -------------------------------------------------

  ;; Each screen has a stack of progressive enhancement flags, a list with
  ;; the current flags first; the empty stack means 0.  As in kitty, the
  ;; stack holds kbd-stack-size entries: pushing onto the empty stack also
  ;; keeps the 0 below, pushing onto a full stack drops the oldest entry, and
  ;; popping more entries than there are empties it.
  (define kbd-stack-size 8)
  (define kbd-supported-flags 31)   ; disambiguate, events, alternates, all keys, text

  (define (kbd-stack t)
    (if (terminal-alt-screen t) (terminal-kbd-alt t) (terminal-kbd-primary t)))

  (define (kbd-stack-set! t s)
    (if (terminal-alt-screen t) (terminal-kbd-alt-set! t s) (terminal-kbd-primary-set! t s)))

  ;; The flags keys are encoded with: 0 while the protocol is disabled.
  (define (terminal-keyboard-flags t)
    (let ([s (kbd-stack t)])
      (if (and (terminal-kitty-keyboard t) (pair? s)) (car s) 0)))

  ;; Enable or disable the protocol.  While it is disabled, its control
  ;; sequences are ignored, so CSI ? u gets no reply and applications keep
  ;; to the legacy encoding.
  (define (terminal-set-kitty-keyboard! t on)
    (terminal-kitty-keyboard-set! t on))

  (define (kbd-push! t flags)
    (let ([s (kbd-stack t)] [flags (fxand flags kbd-supported-flags)])
      (kbd-stack-set! t (cond
                          [(null? s) (list flags 0)]
                          [(fx< (length s) kbd-stack-size) (cons flags s)]
                          [else (cons flags (list-head s (fx- kbd-stack-size 1)))]))))

  (define (kbd-pop! t n)
    (let ([s (kbd-stack t)])
      (kbd-stack-set! t (if (fx< n (length s)) (list-tail s n) '()))))

  ;; CSI = flags ; mode u.  Mode 1 sets the flags, 2 adds and 3 removes the
  ;; given bits.
  (define (kbd-set! t flags mode)
    (let* ([s (kbd-stack t)]
           [cur (if (pair? s) (car s) 0)]
           [flags (fxand flags kbd-supported-flags)]
           [new (case mode
                  [(1) flags]
                  [(2) (fxior cur flags)]
                  [(3) (fxand cur (fxnot flags))]
                  [else cur])])
      (kbd-stack-set! t (cons new (if (pair? s) (cdr s) '())))))

  (define (respond t s) ((terminal-respond t) s))

  ;;; Selection ----------------------------------------------------------------
  ;; A selection is a vector #(mode start-abs start-col end-abs end-col)
  ;; where abs rows are stable across scrolling (see terminal-abs-row).

  (define (terminal-abs-row t row)
    (fx+ row (grid-scroll-counter (terminal-grid t))))
  (define (terminal-rel-row t abs)
    (fx- abs (grid-scroll-counter (terminal-grid t))))

  (define (terminal-set-selection! t sel)
    (terminal-selection-set! t sel)
    (terminal-dirty-set! t #t))
  (define set-selection! terminal-set-selection!)

  (define (terminal-selection-clear! t)
    (when (terminal-selection t) (set-selection! t #f)))

  ;; clear the selection if it intersects screen ROW
  (define (touch-row! t row)
    (let ([sel (terminal-selection t)])
      (when sel
        (let ([abs (terminal-abs-row t row)]
              [a (vector-ref sel 1)] [b (vector-ref sel 3)])
          (when (fx<= (fxmin a b) abs (fxmax a b))
            (set-selection! t #f))))))

  ;;; Scrollback viewing ------------------------------------------------------

  (define (terminal-scroll-display! t delta)
    (let* ([g (terminal-grid t)]
           [n (fxmax 0 (fxmin (grid-hist-count g) (fx+ (terminal-display-offset t) delta)))])
      (unless (fx= n (terminal-display-offset t))
        (terminal-display-offset-set! t n)
        (terminal-dirty-set! t #t))))

  (define (terminal-scroll-to-bottom! t)
    (unless (fx= 0 (terminal-display-offset t))
      (terminal-display-offset-set! t 0)
      (terminal-dirty-set! t #t)))

  (define (terminal-clear-history! t)
    (grid-clear-history! (terminal-primary-grid t))
    (terminal-display-offset-set! t 0)
    (terminal-dirty-set! t #t))

  ;;; Basic operations --------------------------------------------------------

  (define (cur-line t) (grid-screen-line (terminal-grid t) (terminal-cursor-row t)))

  (define (clamp-cursor! t)
    (terminal-cursor-row-set! t (fxmax 0 (fxmin (terminal-cursor-row t) (fx- (terminal-rows t) 1))))
    (terminal-cursor-col-set! t (fxmax 0 (fxmin (terminal-cursor-col t) (fx- (terminal-cols t) 1)))))

  ;; Clear the selection if it intersects screen rows [from, to]: used for
  ;; scrolls that move text without changing absolute row numbers.
  (define (touch-rows! t from to)
    (let ([sel (terminal-selection t)])
      (when sel
        (let ([a (terminal-abs-row t from)] [b (terminal-abs-row t to)]
              [s0 (fxmin (vector-ref sel 1) (vector-ref sel 3))]
              [s1 (fxmax (vector-ref sel 1) (vector-ref sel 3))])
          (unless (or (fx< s1 a) (fx> s0 b))
            (set-selection! t #f))))))

  (define (full-screen-region? t)
    (and (fx= (terminal-top t) 0) (fx= (terminal-bottom t) (fx- (terminal-rows t) 1))))

  (define (scroll-up! t n)
    (let ([g (terminal-grid t)] [top (terminal-top t)])
      (touch-row! t top)
      ;; only a full-screen scroll into the history keeps absolute rows valid
      (unless (and (not (terminal-alt-screen t)) (full-screen-region? t))
        (touch-rows! t top (fx- (terminal-rows t) 1)))
      (let ([before (grid-scroll-counter g)])
        (grid-scroll-up! g top (terminal-bottom t) n (terminal-bg t)
                         (and (not (terminal-alt-screen t)) (fx= top 0)))
        ;; keep a scrolled-back view anchored to its content
        (let ([pushed (fx- (grid-scroll-counter g) before)])
          (when (and (fx> pushed 0) (fx> (terminal-display-offset t) 0))
            (terminal-display-offset-set!
             t (fxmin (grid-hist-count g) (fx+ (terminal-display-offset t) pushed))))))))

  (define (scroll-down! t n)
    (touch-rows! t (terminal-top t) (terminal-bottom t))
    (grid-scroll-down! (terminal-grid t) (terminal-top t) (terminal-bottom t) n (terminal-bg t)))

  (define (index! t)
    (let ([row (terminal-cursor-row t)])
      (cond
        [(fx= row (terminal-bottom t)) (scroll-up! t 1)]
        [(fx< row (fx- (terminal-rows t) 1)) (terminal-cursor-row-set! t (fx+ row 1))])))

  (define (reverse-index! t)
    (let ([row (terminal-cursor-row t)])
      (cond
        [(fx= row (terminal-top t)) (scroll-down! t 1)]
        [(fx> row 0) (terminal-cursor-row-set! t (fx- row 1))])))

  (define (linefeed! t)
    (index! t)
    (when (terminal-newline-mode t) (terminal-cursor-col-set! t 0))
    (terminal-wrap-pending-set! t #f))

  (define (carriage-return! t)
    (terminal-cursor-col-set! t 0)
    (terminal-wrap-pending-set! t #f))

  ;; Move to row/col; with origin mode rows are relative to the scroll region.
  (define (goto! t row col)
    (let* ([origin (terminal-origin-mode t)]
           [min-row (if origin (terminal-top t) 0)]
           [max-row (if origin (terminal-bottom t) (fx- (terminal-rows t) 1))]
           [row (if origin (fx+ row (terminal-top t)) row)])
      (terminal-cursor-row-set! t (fxmax min-row (fxmin row max-row)))
      (terminal-cursor-col-set! t (fxmax 0 (fxmin col (fx- (terminal-cols t) 1))))
      (terminal-wrap-pending-set! t #f)))

  (define (erase-cells! t row from to)
    (touch-row! t row)
    (let ([l (grid-screen-line (terminal-grid t) row)])
      (line-fill! l (fxmax 0 from) (fxmin to (terminal-cols t)) (terminal-bg t))))

  ;; Remove a wide character that one of cells [from,to) partially covers.
  (define (fix-wide-edges! t l from to)
    (let ([v (line-cells l)] [cols (terminal-cols t)] [bg (terminal-bg t)])
      (when (and (fx> from 0) (fx< from cols)
                 (fxlogtest (cell-attrs v from) ATTR-SPACER))
        (line-fill! l (fx- from 1) from bg))
      (when (and (fx> to 0) (fx< to cols) (fxlogtest (cell-attrs v (fx- to 1)) ATTR-WIDE))
        (line-fill! l to (fx+ to 1) bg))))

  ;;; Printing ------------------------------------------------------------------

  (define dec-special
    ;; DEC Special Graphics for 0x5f..0x7e
    '#(#x00A0 #x25C6 #x2592 #x2409 #x240C #x240D #x240A #x00B0 #x00B1 #x2424 #x240B
       #x2518 #x2510 #x250C #x2514 #x253C #x23BA #x23BB #x2500 #x23BC #x23BD #x251C
       #x2524 #x2534 #x252C #x2502 #x2264 #x2265 #x03C0 #x2260 #x00A3 #x00B7))

  (define (translate t cp)
    (let ([cs (vector-ref (terminal-charsets t) (terminal-gl t))])
      (cond
        [(eq? cs 'ascii) cp]
        [(eq? cs 'dec) (if (fx<= #x5f cp #x7e) (vector-ref dec-special (fx- cp #x5f)) cp)]
        [(eq? cs 'uk) (if (fx= cp #x23) #xA3 cp)]
        [else cp])))

  (define (add-combining! t cp)
    (let* ([col (if (terminal-wrap-pending t)
                    (terminal-cursor-col t)
                    (fx- (terminal-cursor-col t) 1))]
           [l (cur-line t)])
      (when (fx>= col 0)
        (let* ([col (if (and (fx> col 0) (fxlogtest (cell-attrs (line-cells l) col) ATTR-SPACER))
                        (fx- col 1) col)])
          (line-add-mark! l col cp)))))

  (define (print! t cp0)
    (let* ([cp (if (and (eq? (vector-ref (terminal-charsets t) (terminal-gl t)) 'ascii))
                   cp0
                   (translate t cp0))]
           [w (char-width cp)])
      (if (fx= w 0)
          (add-combining! t cp)
          (let ([cols (terminal-cols t)])
            (when (terminal-wrap-pending t)
              (when (terminal-autowrap t)
                (line-wrapped-set! (cur-line t) #t)
                (index! t)
                (terminal-cursor-col-set! t 0))
              (terminal-wrap-pending-set! t #f))
            (when (and (fx= w 2) (fx= (terminal-cursor-col t) (fx- cols 1)))
              (if (and (terminal-autowrap t) (fx> cols 1))
                  (begin
                    (erase-cells! t (terminal-cursor-row t) (fx- cols 1) cols)
                    (line-wrapped-set! (cur-line t) #t)
                    (index! t)
                    (terminal-cursor-col-set! t 0))
                  (terminal-cursor-col-set! t (fxmax 0 (fx- cols 2)))))
            (let* ([row (terminal-cursor-row t)]
                   [col (terminal-cursor-col t)]
                   [l (cur-line t)]
                   [v (line-cells l)]
                   [w (if (fx> (fx+ col w) cols) 1 w)])
              (when (terminal-selection t) (touch-row! t row))
              (when (terminal-insert-mode t)
                (insert-blanks! t w))
              (fix-wide-edges! t l col (fx+ col w))
              (line-extra-delete! l col (fx+ col 1))
              (let ([attrs (terminal-attrs t)] [fg (terminal-fg t)] [bg (terminal-bg t)])
                (if (fx= w 2)
                    (begin
                      (cell-set! v col cp (fxior attrs ATTR-WIDE) fg bg)
                      (cell-set! v (fx+ col 1) 0 (fxior attrs ATTR-SPACER) fg bg)
                      (line-extra-delete! l (fx+ col 1) (fx+ col 2)))
                    (cell-set! v col cp attrs fg bg))
                (let ([x (terminal-pen-extra t)]) (when x (line-extra-put! l col x))))
              (terminal-last-char-set! t cp)
              (if (fx>= (fx+ col w) cols)
                  (terminal-wrap-pending-set! t #t)
                  (terminal-cursor-col-set! t (fx+ col w))))))))

  ;; ASCII fast path: print the printable bytes [start,end) of bv, writing
  ;; whole runs into the current line at once.
  (define (print-ascii-run! t bv start end)
    (if (or (terminal-insert-mode t)
            (not (eq? (vector-ref (terminal-charsets t) (terminal-gl t)) 'ascii)))
        (do ([i start (fx+ i 1)]) ((fx= i end))
          (print! t (bytevector-u8-ref bv i)))
        (let loop ([i start])
          (when (fx< i end)
            (if (terminal-wrap-pending t)
                (begin (print! t (bytevector-u8-ref bv i)) (loop (fx+ i 1)))
                (let* ([cols (terminal-cols t)]
                       [col (terminal-cursor-col t)]
                       [n (fxmin (fx- end i) (fx- cols col))]
                       [l (cur-line t)]
                       [v (line-cells l)]
                       [attrs (fxsll (terminal-attrs t) 21)]
                       [fg (fg-field (terminal-fg t))]
                       [bg (bg-field (terminal-bg t))])
                  (when (terminal-selection t) (touch-row! t (terminal-cursor-row t)))
                  (fix-wide-edges! t l col (fx+ col n))
                  (line-extra-delete! l col (fx+ col n))
                  (do ([k 0 (fx+ k 1)]) ((fx= k n))
                    (let ([idx (fx* 3 (fx+ col k))])
                      (fxvector-set! v idx (fxior (bytevector-u8-ref bv (fx+ i k)) attrs))
                      (fxvector-set! v (fx+ idx 1) fg)
                      (fxvector-set! v (fx+ idx 2) bg)))
                  (let ([x (terminal-pen-extra t)]) (when x (line-extra-fill! l col (fx+ col n) x)))
                  (terminal-last-char-set! t (bytevector-u8-ref bv (fx+ i (fx- n 1))))
                  (if (fx>= (fx+ col n) cols)
                      (begin
                        (terminal-cursor-col-set! t (fx- cols 1))
                        (terminal-wrap-pending-set! t #t))
                      (terminal-cursor-col-set! t (fx+ col n)))
                  (loop (fx+ i n))))))))

  (define (insert-blanks! t n)
    (let* ([l (cur-line t)] [v (line-cells l)] [cols (terminal-cols t)]
           [col (terminal-cursor-col t)] [n (fxmin n (fx- cols col))])
      (touch-row! t (terminal-cursor-row t))
      (fix-wide-edges! t l col col)
      (do ([i (fx- cols 1) (fx- i 1)]) ((fx< i (fx+ col n)))
        (cell-copy! v (fx- i n) v i))
      (shift-extras! l col n cols)
      (line-fill! l col (fx+ col n) (terminal-bg t))
      ;; a wide char pushed partially off the edge
      (when (fxlogtest (cell-attrs v (fx- cols 1)) ATTR-WIDE)
        (line-fill! l (fx- cols 1) cols (terminal-bg t)))))

  ;; Move combining marks of columns >= COL by DELTA, dropping those that
  ;; leave [COL, COLS) (or land left of COL when deleting).
  (define (shift-extras! l col delta cols)
    (let ([ex (line-extra l)])
      (when ex
        (let-values ([(ks vs) (hashtable-entries ex)])
          (let ([new (make-eqv-hashtable)])
            (vector-for-each
             (lambda (k v)
               (cond
                 [(fx< k col) (hashtable-set! new k v)]
                 [else
                  (let ([nk (fx+ k delta)])
                    (when (and (fx>= nk col) (fx< nk cols))
                      (hashtable-set! new nk v)))]))
             ks vs)
            (line-extra-set! l new))))))

  (define (delete-chars! t n)
    (let* ([l (cur-line t)] [v (line-cells l)] [cols (terminal-cols t)]
           [col (terminal-cursor-col t)] [n (fxmin n (fx- cols col))])
      (touch-row! t (terminal-cursor-row t))
      (fix-wide-edges! t l col (fx+ col n))
      (line-extra-delete! l col (fx+ col n))
      (do ([i col (fx+ i 1)]) ((fx>= i (fx- cols n)))
        (cell-copy! v (fx+ i n) v i))
      (shift-extras! l col (fx- n) cols)
      (line-fill! l (fx- cols n) cols (terminal-bg t))))

  ;;; Control characters -------------------------------------------------------

  (define (next-tab t col)
    (let ([tabs (terminal-tabs t)] [cols (terminal-cols t)])
      (let loop ([c (fx+ col 1)])
        (cond [(fx>= c (fx- cols 1)) (fx- cols 1)]
              [(fx= 1 (bytevector-u8-ref tabs c)) c]
              [else (loop (fx+ c 1))]))))

  (define (prev-tab t col)
    (let ([tabs (terminal-tabs t)])
      (let loop ([c (fx- col 1)])
        (cond [(fx<= c 0) 0]
              [(fx= 1 (bytevector-u8-ref tabs c)) c]
              [else (loop (fx- c 1))]))))

  (define (execute! t c)
    (case c
      [(7) ((terminal-on-bell t))]
      [(8) (when (fx> (terminal-cursor-col t) 0)
             (terminal-cursor-col-set! t (fx- (terminal-cursor-col t) 1)))
           (terminal-wrap-pending-set! t #f)]
      [(9) (terminal-cursor-col-set! t (next-tab t (terminal-cursor-col t)))
           (terminal-wrap-pending-set! t #f)]
      [(10 11 12) (linefeed! t)]
      [(13) (carriage-return! t)]
      [(14) (terminal-gl-set! t 1)]
      [(15) (terminal-gl-set! t 0)]
      [else (void)]))

  ;;; Parser -------------------------------------------------------------------

  (define (reset-params! t)
    (terminal-nparams-set! t 0)
    (terminal-param-started-set! t #f)
    (terminal-private-set! t #f)
    (terminal-intermediates-set! t '()))

  (define (param-count t) (terminal-nparams t))

  ;; value of parameter i, or DEFAULT when omitted
  (define (param t i default)
    (if (fx< i (terminal-nparams t))
        (let ([v (fxvector-ref (terminal-params t) i)])
          (if (fx< v 0) default v))
        default))

  ;; like param, but 0 also means the default (for counts)
  (define (param1 t i default)
    (let ([v (param t i default)]) (if (fx= v 0) default v)))

  (define (colon? t i) (fx= 1 (bytevector-u8-ref (terminal-colons t) i)))

  (define (push-param! t colon)
    (let ([n (terminal-nparams t)])
      (when (fx< n 32)
        (fxvector-set! (terminal-params t) n -1)
        (bytevector-u8-set! (terminal-colons t) n (if colon 1 0))
        (terminal-nparams-set! t (fx+ n 1)))))

  (define (feed-param-char! t c)
    (cond
      [(fx<= 48 c 57)
       (unless (terminal-param-started t)
         (push-param! t #f)
         (terminal-param-started-set! t #t))
       (let* ([i (fx- (terminal-nparams t) 1)]
              [v (fxvector-ref (terminal-params t) i)])
         (when (fx< v 100000)
           (fxvector-set! (terminal-params t) i (fx+ (fx* (fxmax v 0) 10) (fx- c 48)))))]
      [(fx= c 59)   ; ;
       (unless (terminal-param-started t) (push-param! t #f))
       (push-param! t #f)
       (terminal-param-started-set! t #t)]
      [(fx= c 58)   ; :
       (unless (terminal-param-started t) (push-param! t #f))
       (push-param! t #t)
       (terminal-param-started-set! t #t)]))

  (define (strbuf-reset! t)
    (terminal-strbuf-set! t (open-output-string)))

  (define max-string-length (* 4 1024 1024))

  (define (terminal-feed! t bv len)
    (let loop ([i 0])
      (when (fx< i len)
        (let ([b (bytevector-u8-ref bv i)])
          (cond
            ;; fast path: runs of printable ASCII in ground state
            [(and (fx<= 32 b 126) (eq? (terminal-state t) 'ground) (fx= 0 (terminal-utf8-need t)))
             (let ([j (let scan ([j (fx+ i 1)])
                        (if (and (fx< j len) (fx<= 32 (bytevector-u8-ref bv j) 126))
                            (scan (fx+ j 1))
                            j))])
               (print-ascii-run! t bv i j)
               (loop j))]
            [(fx= 0 (terminal-utf8-need t))
             (cond
               [(fx< b #x80) (process! t b)]
               [(fx= (fxand b #xE0) #xC0)
                (terminal-utf8-need-set! t 1) (terminal-utf8-cp-set! t (fxand b #x1F))]
               [(fx= (fxand b #xF0) #xE0)
                (terminal-utf8-need-set! t 2) (terminal-utf8-cp-set! t (fxand b #x0F))]
               [(fx= (fxand b #xF8) #xF0)
                (terminal-utf8-need-set! t 3) (terminal-utf8-cp-set! t (fxand b #x07))]
               [else (process! t #xFFFD)])
             (loop (fx+ i 1))]
            [(fx= (fxand b #xC0) #x80)
             (terminal-utf8-cp-set! t (fxior (fxsll (terminal-utf8-cp t) 6) (fxand b #x3F)))
             (terminal-utf8-need-set! t (fx- (terminal-utf8-need t) 1))
             (when (fx= 0 (terminal-utf8-need t))
               (let ([cp (terminal-utf8-cp t)])
                 (process! t (if (or (fx> cp #x10FFFF) (fx<= #xD800 cp #xDFFF)) #xFFFD cp))))
             (loop (fx+ i 1))]
            [else
             ;; invalid continuation: emit replacement, reprocess byte
             (terminal-utf8-need-set! t 0)
             (process! t #xFFFD)
             (loop i)]))))
    (terminal-dirty-set! t #t))

  (define (process! t c)
    (let ([state (terminal-state t)])
      (cond
        ;; CAN / SUB abort sequences, ESC starts a new one (except inside
        ;; strings, where it may begin the ST terminator)
        [(and (or (fx= c #x18) (fx= c #x1A)) (not (eq? state 'ground)))
         (terminal-state-set! t 'ground)]
        [(eq? state 'ground)
         (cond
           [(fx= c #x1B) (terminal-state-set! t 'escape) (reset-params! t)]
           [(fx< c #x20) (execute! t c)]
           [(fx= c #x7F) (void)]
           [else (print! t c)])]
        [(memq state '(osc dcs ignore-string))
         (string-char! t c)]
        [(fx= c #x1B) (terminal-state-set! t 'escape) (reset-params! t)]
        [(eq? state 'escape)
         (cond
           [(fx< c #x20) (execute! t c)]
           [(fx<= #x20 c #x2F)
            (terminal-intermediates-set! t (cons c (terminal-intermediates t)))
            (terminal-state-set! t 'escape-intermediate)]
           [(fx= c 91) (terminal-state-set! t 'csi)]                ; [
           [(fx= c 93) (strbuf-reset! t) (terminal-esc-in-string-set! t #f)
                       (terminal-state-set! t 'osc)]                 ; ]
           [(fx= c 80) (strbuf-reset! t) (terminal-esc-in-string-set! t #f)
                       (terminal-state-set! t 'dcs)]                 ; P
           [(memv c '(88 94 95)) (terminal-esc-in-string-set! t #f)
                                 (terminal-state-set! t 'ignore-string)] ; X ^ _
           [(fx= c #x7F) (void)]
           [else (terminal-state-set! t 'ground) (esc-dispatch! t c)])]
        [(eq? state 'escape-intermediate)
         (cond
           [(fx< c #x20) (execute! t c)]
           [(fx<= #x20 c #x2F)
            (terminal-intermediates-set! t (cons c (terminal-intermediates t)))]
           [(fx= c #x7F) (void)]
           [else (terminal-state-set! t 'ground) (esc-dispatch! t c)])]
        [(eq? state 'csi)
         (cond
           [(fx< c #x20) (execute! t c)]
           [(fx<= 48 c 59) (feed-param-char! t c)]
           [(fx<= 60 c 63)                       ; < = > ?
            (if (and (fx= 0 (terminal-nparams t)) (not (terminal-private t)))
                (terminal-private-set! t c)
                (terminal-state-set! t 'csi-ignore))]
           [(fx<= #x20 c #x2F)
            (terminal-intermediates-set! t (cons c (terminal-intermediates t)))]
           [(fx<= #x40 c #x7E)
            (terminal-state-set! t 'ground)
            (csi-dispatch! t c)]
           [else (void)])]
        [(eq? state 'csi-ignore)
         (cond
           [(fx< c #x20) (execute! t c)]
           [(fx<= #x40 c #x7E) (terminal-state-set! t 'ground)])]
        [else (terminal-state-set! t 'ground)])))

  ;; Characters inside OSC / DCS / SOS / PM / APC strings.
  (define (string-char! t c)
    (let ([state (terminal-state t)])
      (cond
        [(terminal-esc-in-string t)
         (terminal-esc-in-string-set! t #f)
         (terminal-state-set! t 'ground)
         (finish-string! t state "\x1b;\\")
         (unless (fx= c 92)   ; not ST: treat as start of a new escape sequence
           (terminal-state-set! t 'escape)
           (reset-params! t)
           (process! t c))]
        [(fx= c #x1B) (terminal-esc-in-string-set! t #t)]
        [(and (fx= c 7) (not (eq? state 'dcs)))
         (terminal-state-set! t 'ground)
         (finish-string! t state "\a")]
        [(eq? state 'ignore-string) (void)]
        [(fx< (port-position (terminal-strbuf t)) max-string-length)
         (write-char (integer->char c) (terminal-strbuf t))])))

  (define (finish-string! t state terminator)
    ;; malformed strings from applications must never take the terminal down
    (guard (e [#t (void)])
      (case state
        [(osc) (osc-dispatch! t (get-output-string (terminal-strbuf t)) terminator)]
        [(dcs) (dcs-dispatch! t (get-output-string (terminal-strbuf t)))]
        [else (void)])))

  ;;; ESC sequences ------------------------------------------------------------

  (define (save-cursor! t)
    (let ([s (vector (terminal-cursor-row t) (terminal-cursor-col t)
                     (terminal-attrs t) (terminal-fg t) (terminal-bg t)
                     (terminal-origin-mode t) (vector-copy (terminal-charsets t))
                     (terminal-gl t) (terminal-wrap-pending t) (terminal-autowrap t)
                     (terminal-ul-color t))])
      (if (terminal-alt-screen t)
          (terminal-saved-alt-set! t s)
          (terminal-saved-primary-set! t s))))

  (define (restore-cursor! t)
    (let ([s (if (terminal-alt-screen t) (terminal-saved-alt t) (terminal-saved-primary t))])
      (if s
          (begin
            (terminal-cursor-row-set! t (vector-ref s 0))
            (terminal-cursor-col-set! t (vector-ref s 1))
            (terminal-attrs-set! t (vector-ref s 2))
            (terminal-fg-set! t (vector-ref s 3))
            (terminal-bg-set! t (vector-ref s 4))
            (terminal-origin-mode-set! t (vector-ref s 5))
            (terminal-charsets-set! t (vector-copy (vector-ref s 6)))
            (terminal-gl-set! t (vector-ref s 7))
            (terminal-wrap-pending-set! t (vector-ref s 8))
            (terminal-autowrap-set! t (vector-ref s 9))
            (set-ul-color! t (vector-ref s 10))
            (clamp-cursor! t))
          (begin
            (terminal-cursor-row-set! t 0)
            (terminal-cursor-col-set! t 0)
            (terminal-wrap-pending-set! t #f)
            (terminal-attrs-set! t 0)
            (terminal-fg-set! t COLOR-FG)
            (terminal-bg-set! t COLOR-BG)
            (set-ul-color! t #f)
            (terminal-origin-mode-set! t #f)))))

  (define (esc-dispatch! t c)
    (let ([inter (terminal-intermediates t)])
      (cond
        [(null? inter)
         (case (integer->char c)
           [(#\7) (save-cursor! t)]
           [(#\8) (restore-cursor! t)]
           [(#\D) (index! t) (terminal-wrap-pending-set! t #f)]
           [(#\E) (index! t) (carriage-return! t)]
           [(#\H) (bytevector-u8-set! (terminal-tabs t) (terminal-cursor-col t) 1)]
           [(#\M) (reverse-index! t) (terminal-wrap-pending-set! t #f)]
           [(#\c) (terminal-reset! t)]
           [(#\=) (terminal-app-keypad-set! t #t)]
           [(#\>) (terminal-app-keypad-set! t #f)]
           [(#\n) (terminal-gl-set! t 2)]
           [(#\o) (terminal-gl-set! t 3)]
           [else (void)])]
        [(equal? inter '(35))                  ; #
         (when (fx= c 56)                      ; DECALN: fill screen with E
           (do ([r 0 (fx+ r 1)]) ((fx= r (terminal-rows t)))
             (let ([l (grid-screen-line (terminal-grid t) r)])
               (line-extra-set! l #f)
               (do ([col 0 (fx+ col 1)]) ((fx= col (terminal-cols t)))
                 (cell-set! (line-cells l) col 69 0 COLOR-FG COLOR-BG))))
           (terminal-top-set! t 0)
           (terminal-bottom-set! t (fx- (terminal-rows t) 1))
           (goto! t 0 0))]
        [(and (fx= 1 (length inter)) (memv (car inter) '(40 41 42 43)))  ; ( ) * +
         (vector-set! (terminal-charsets t) (fx- (car inter) 40)
                      (case (integer->char c)
                        [(#\0) 'dec]
                        [(#\A) 'uk]
                        [else 'ascii]))]
        [else (void)])))

  ;;; CSI sequences ------------------------------------------------------------

  (define (csi-dispatch! t c)
    (let ([private (terminal-private t)]
          [inter (terminal-intermediates t)]
          [rows (terminal-rows t)]
          [cols (terminal-cols t)])
      (cond
        [(and (not private) (null? inter))
         (case (integer->char c)
           [(#\@) (insert-blanks! t (param1 t 0 1))]
           [(#\A) (cursor-up! t (param1 t 0 1))]
           [(#\B #\e) (cursor-down! t (param1 t 0 1))]
           [(#\C #\a) (terminal-cursor-col-set! t (fxmin (fx- cols 1) (fx+ (terminal-cursor-col t) (param1 t 0 1))))
                      (terminal-wrap-pending-set! t #f)]
           [(#\D) (terminal-cursor-col-set! t (fxmax 0 (fx- (terminal-cursor-col t) (param1 t 0 1))))
                  (terminal-wrap-pending-set! t #f)]
           [(#\E) (cursor-down! t (param1 t 0 1)) (carriage-return! t)]
           [(#\F) (cursor-up! t (param1 t 0 1)) (carriage-return! t)]
           [(#\G #\`) (terminal-cursor-col-set! t (fxmin (fx- cols 1) (fx- (param1 t 0 1) 1)))
                      (terminal-wrap-pending-set! t #f)]
           [(#\H #\f) (goto! t (fx- (param1 t 0 1) 1) (fx- (param1 t 1 1) 1))]
           [(#\I) (do ([n (param1 t 0 1) (fx- n 1)]) ((fx= n 0))
                    (terminal-cursor-col-set! t (next-tab t (terminal-cursor-col t))))
                  (terminal-wrap-pending-set! t #f)]
           [(#\J) (erase-display! t (param t 0 0))]
           [(#\K) (erase-line! t (param t 0 0))]
           [(#\L) (insert-lines! t (param1 t 0 1))]
           [(#\M) (delete-lines! t (param1 t 0 1))]
           [(#\P) (delete-chars! t (param1 t 0 1))]
           [(#\S) (scroll-up! t (param1 t 0 1))]
           [(#\T) (scroll-down! t (param1 t 0 1))]
           [(#\X) (let ([col (terminal-cursor-col t)] [l (cur-line t)] [n (param1 t 0 1)])
                    (fix-wide-edges! t l col (fxmin cols (fx+ col n)))
                    (erase-cells! t (terminal-cursor-row t) col (fx+ col n)))
                  (terminal-wrap-pending-set! t #f)]
           [(#\Z) (do ([n (param1 t 0 1) (fx- n 1)]) ((fx= n 0))
                    (terminal-cursor-col-set! t (prev-tab t (terminal-cursor-col t))))
                  (terminal-wrap-pending-set! t #f)]
           [(#\b) (let ([ch (terminal-last-char t)])
                    (do ([n (fxmin (param1 t 0 1) 65535) (fx- n 1)]) ((fx= n 0))
                      (print! t ch)))]
           [(#\c) (when (fx= 0 (param t 0 0)) (respond t "\x1b;[?62;22c"))]
           [(#\d) (goto! t (fx- (param1 t 0 1) 1) (terminal-cursor-col t))]
           [(#\g) (case (param t 0 0)
                    [(0) (bytevector-u8-set! (terminal-tabs t) (terminal-cursor-col t) 0)]
                    [(3) (bytevector-fill! (terminal-tabs t) 0)])]
           [(#\h) (set-ansi-modes! t #t)]
           [(#\l) (set-ansi-modes! t #f)]
           [(#\m) (sgr! t)]
           [(#\n) (case (param t 0 0)
                    [(5) (respond t "\x1b;[0n")]
                    [(6) (respond t (format "\x1b;[~a;~aR"
                                            (fx+ 1 (fx- (terminal-cursor-row t)
                                                        (if (terminal-origin-mode t) (terminal-top t) 0)))
                                            (fx+ 1 (terminal-cursor-col t))))])]
           [(#\r) (let ([top (fx- (param1 t 0 1) 1)]
                        [bottom (fx- (param1 t 1 rows) 1)])
                    (when (fx< top (fxmin bottom rows))
                      (terminal-top-set! t top)
                      (terminal-bottom-set! t (fxmin bottom (fx- rows 1)))
                      (goto! t 0 0)))]
           [(#\s) (save-cursor! t)]
           [(#\u) (restore-cursor! t)]
           [(#\t) (window-op! t)]
           [else (void)])]
        [(and (eqv? private 63) (null? inter))          ; ?
         (case (integer->char c)
           [(#\h) (set-dec-modes! t #t)]
           [(#\l) (set-dec-modes! t #f)]
           [(#\J) (erase-display! t (param t 0 0))]
           [(#\K) (erase-line! t (param t 0 0))]
           [(#\n) (when (fx= (param t 0 0) 6)
                    (respond t (format "\x1b;[?~a;~aR" (fx+ 1 (terminal-cursor-row t))
                                       (fx+ 1 (terminal-cursor-col t)))))]
           [(#\u) (when (terminal-kitty-keyboard t)            ; kitty keyboard query
                    (respond t (format "\x1b;[?~au" (terminal-keyboard-flags t))))]
           [else (void)])]
        [(and (eqv? private 62) (null? inter))          ; >
         (case (integer->char c)
           [(#\c) (respond t "\x1b;[>1;4000;0c")]
           [(#\q) (respond t "\x1b;P>|chezterm 0.1\x1b;\\")]
           [(#\u) (when (terminal-kitty-keyboard t) (kbd-push! t (param t 0 0)))]
           [else (void)])]
        [(and (eqv? private 60) (null? inter) (fx= c 117))     ; < u: pop keyboard flags
         (when (terminal-kitty-keyboard t) (kbd-pop! t (param1 t 0 1)))]
        [(and (eqv? private 61) (null? inter) (fx= c 117))     ; = u: set keyboard flags
         (when (terminal-kitty-keyboard t) (kbd-set! t (param t 0 0) (param1 t 1 1)))]
        [(and (not private) (equal? inter '(32)) (fx= c 113))    ; SP q: DECSCUSR
         (let ([n (param t 0 0)])
           (if (fx= n 0)
               (begin (terminal-cursor-style-set! t (terminal-default-cursor-style t))
                      (terminal-cursor-blink-set! t (terminal-default-cursor-blink t)))
               (begin
                 (terminal-cursor-style-set! t (case n [(1 2) 'block] [(3 4) 'underline] [else 'beam]))
                 (terminal-cursor-blink-set! t (odd? n)))))]
        [(and (not private) (equal? inter '(33)) (fx= c 112))    ; ! p: DECSTR
         (soft-reset! t)]
        [(and (equal? inter '(36)) (fx= c 112))                  ; $ p: DECRQM
         (let* ([mode (param t 0 0)]
                [state (if (eqv? private 63) (dec-mode-state t mode) (ansi-mode-state t mode))])
           (respond t (format "\x1b;[~a~a;~a$y" (if (eqv? private 63) "?" "") mode state)))]
        [else (void)])))

  (define (cursor-up! t n)
    (let ([limit (if (fx>= (terminal-cursor-row t) (terminal-top t)) (terminal-top t) 0)])
      (terminal-cursor-row-set! t (fxmax limit (fx- (terminal-cursor-row t) n)))
      (terminal-wrap-pending-set! t #f)))

  (define (cursor-down! t n)
    (let ([limit (if (fx<= (terminal-cursor-row t) (terminal-bottom t))
                     (terminal-bottom t)
                     (fx- (terminal-rows t) 1))])
      (terminal-cursor-row-set! t (fxmin limit (fx+ (terminal-cursor-row t) n)))
      (terminal-wrap-pending-set! t #f)))

  (define (erase-display! t mode)
    (let ([row (terminal-cursor-row t)] [col (terminal-cursor-col t)]
          [rows (terminal-rows t)] [cols (terminal-cols t)])
      (case mode
        [(0) (fix-wide-edges! t (cur-line t) col cols)
             (erase-cells! t row col cols)
             (line-wrapped-set! (cur-line t) #f)
             (do ([r (fx+ row 1) (fx+ r 1)]) ((fx>= r rows))
               (line-clear! (grid-screen-line (terminal-grid t) r) (terminal-bg t))
               (touch-row! t r))]
        [(1) (fix-wide-edges! t (cur-line t) 0 (fx+ col 1))
             (erase-cells! t row 0 (fx+ col 1))
             (do ([r 0 (fx+ r 1)]) ((fx>= r row))
               (line-clear! (grid-screen-line (terminal-grid t) r) (terminal-bg t))
               (touch-row! t r))]
        [(2) (do ([r 0 (fx+ r 1)]) ((fx>= r rows))
               (line-clear! (grid-screen-line (terminal-grid t) r) (terminal-bg t))
               (touch-row! t r))]
        [(3) (terminal-clear-history! t) (terminal-selection-clear! t)])))

  (define (erase-line! t mode)
    (let ([row (terminal-cursor-row t)] [col (terminal-cursor-col t)] [cols (terminal-cols t)]
          [l (cur-line t)])
      (case mode
        [(0) (fix-wide-edges! t l col cols)
             (erase-cells! t row col cols)
             (line-wrapped-set! l #f)]
        [(1) (fix-wide-edges! t l 0 (fx+ col 1)) (erase-cells! t row 0 (fx+ col 1))]
        [(2) (erase-cells! t row 0 cols) (line-wrapped-set! l #f)])))

  (define (insert-lines! t n)
    (let ([row (terminal-cursor-row t)])
      (when (fx<= (terminal-top t) row (terminal-bottom t))
        (touch-rows! t row (terminal-bottom t))
        (grid-scroll-down! (terminal-grid t) row (terminal-bottom t) n (terminal-bg t))
        (carriage-return! t))))

  (define (delete-lines! t n)
    (let ([row (terminal-cursor-row t)])
      (when (fx<= (terminal-top t) row (terminal-bottom t))
        (touch-rows! t row (terminal-bottom t))
        (grid-scroll-up! (terminal-grid t) row (terminal-bottom t) n (terminal-bg t) #f)
        (carriage-return! t))))

  (define (window-op! t)
    (case (param t 0 0)
      [(14) (respond t (format "\x1b;[4;~a;~at" (fx* (terminal-rows t) (terminal-cell-height t))
                               (fx* (terminal-cols t) (terminal-cell-width t))))]
      [(16) (respond t (format "\x1b;[6;~a;~at" (terminal-cell-height t) (terminal-cell-width t)))]
      [(18) (respond t (format "\x1b;[8;~a;~at" (terminal-rows t) (terminal-cols t)))]
      [(22) (let ([st (terminal-title-stack t)])
              (terminal-title-stack-set! t (cons (terminal-title t)
                                                 (if (fx>= (length st) 10) (list-head st 9) st))))]
      [(23) (let ([s (terminal-title-stack t)])
              (when (pair? s)
                (terminal-title-stack-set! t (cdr s))
                (set-title! t (car s))))]
      [else (void)]))

  (define (set-title! t s)
    (terminal-title-set! t s)
    ((terminal-on-title t) s))

  ;;; Modes ----------------------------------------------------------------------

  (define (set-ansi-modes! t on)
    (do ([i 0 (fx+ i 1)]) ((fx= i (param-count t)))
      (case (param t i 0)
        [(4) (terminal-insert-mode-set! t on)]
        [(20) (terminal-newline-mode-set! t on)]
        [else (void)])))

  (define (ansi-mode-state t mode)
    (case mode
      [(4) (if (terminal-insert-mode t) 1 2)]
      [(20) (if (terminal-newline-mode t) 1 2)]
      [else 0]))

  (define (dec-mode-state t mode)
    (define (b x) (if x 1 2))
    (case mode
      [(1) (b (terminal-app-cursor t))]
      [(5) (b (terminal-reverse-video t))]
      [(6) (b (terminal-origin-mode t))]
      [(7) (b (terminal-autowrap t))]
      [(12) (b (terminal-cursor-blink t))]
      [(25) (b (terminal-cursor-visible t))]
      [(47 1047 1049) (b (terminal-alt-screen t))]
      [(1000) (b (eq? (terminal-mouse-mode t) 'click))]
      [(1002) (b (eq? (terminal-mouse-mode t) 'drag))]
      [(1003) (b (eq? (terminal-mouse-mode t) 'motion))]
      [(1004) (b (terminal-focus-events t))]
      [(1005) (b (terminal-mouse-utf8 t))]
      [(1006) (b (terminal-mouse-sgr t))]
      [(1007) (b (terminal-alternate-scroll t))]
      [(2004) (b (terminal-bracketed-paste t))]
      [(2026) (b (terminal-sync-update t))]
      [else 0]))

  (define (enter-alt-screen! t clear?)
    (unless (terminal-alt-screen t)
      (terminal-primary-cursor-set! t (cons (terminal-cursor-row t) (terminal-cursor-col t)))
      (terminal-alt-screen-set! t #t)
      (terminal-grid-set! t (terminal-alt-grid t))
      (terminal-display-offset-set! t 0)
      (terminal-selection-clear! t)
      (when clear?
        (do ([r 0 (fx+ r 1)]) ((fx= r (terminal-rows t)))
          (line-clear! (grid-screen-line (terminal-grid t) r) (terminal-bg t))))))

  (define (leave-alt-screen! t)
    (when (terminal-alt-screen t)
      (terminal-alt-screen-set! t #f)
      (terminal-grid-set! t (terminal-primary-grid t))
      (terminal-selection-clear! t)))

  (define (set-dec-modes! t on)
    (do ([i 0 (fx+ i 1)]) ((fx= i (param-count t)))
      (case (param t i 0)
        [(1) (terminal-app-cursor-set! t on)]
        [(5) (terminal-reverse-video-set! t on)]
        [(6) (terminal-origin-mode-set! t on) (goto! t 0 0)]
        [(7) (terminal-autowrap-set! t on)
             (unless on (terminal-wrap-pending-set! t #f))]
        [(12) (terminal-cursor-blink-set! t on)]
        [(25) (terminal-cursor-visible-set! t on)]
        [(47) (if on (enter-alt-screen! t #f) (leave-alt-screen! t))]
        [(1047) (if on
                    (enter-alt-screen! t #f)
                    (begin
                      (when (terminal-alt-screen t)
                        (do ([r 0 (fx+ r 1)]) ((fx= r (terminal-rows t)))
                          (line-clear! (grid-screen-line (terminal-grid t) r) COLOR-BG)))
                      (leave-alt-screen! t)))]
        [(1048) (if on (save-cursor! t) (restore-cursor! t))]
        [(1049) (if on
                    (unless (terminal-alt-screen t)
                      (save-cursor! t)
                      (enter-alt-screen! t #t))
                    (when (terminal-alt-screen t)
                      (leave-alt-screen! t)
                      (restore-cursor! t)))]
        [(9 1000) (terminal-mouse-mode-set! t (and on 'click))]
        [(1002) (terminal-mouse-mode-set! t (and on 'drag))]
        [(1003) (terminal-mouse-mode-set! t (and on 'motion))]
        [(1004) (terminal-focus-events-set! t on)]
        [(1005) (terminal-mouse-utf8-set! t on)]
        [(1006) (terminal-mouse-sgr-set! t on)]
        [(1007) (terminal-alternate-scroll-set! t on)]
        [(2004) (terminal-bracketed-paste-set! t on)]
        [(2026) (terminal-sync-update-set! t (and on (real-time)))]
        [else (void)])))

  ;;; SGR ------------------------------------------------------------------------

  ;; Parse an extended color starting at parameter i (the 38/48/58 itself).
  ;; Returns (values color next-index).
  (define (extended-color t i)
    (let ([n (param-count t)])
      (cond
        [(fx>= (fx+ i 1) n) (values #f n)]
        [else
         (let ([kind (param t (fx+ i 1) 0)]
               [colon-form (colon? t (fx+ i 1))])
           (case kind
             [(5) (values (and (fx< (fx+ i 2) n) (fxmin 255 (param t (fx+ i 2) 0))) (fx+ i 3))]
             [(2)
              ;; 38;2;r;g;b or 38:2:colorspace:r:g:b (colorspace optional)
              (let* ([subs (let loop ([j (fx+ i 2)] [acc '()])
                             (if (and (fx< j n) (or (not colon-form) (colon? t j)))
                                 (if (and (not colon-form) (fx= (length acc) 3))
                                     (reverse acc)
                                     (loop (fx+ j 1) (cons (param t j 0) acc)))
                                 (reverse acc)))]
                     [consumed (length subs)]
                     [rgb (if (fx>= (length subs) 4) (list-tail subs (fx- (length subs) 3)) subs)])
                (values (and (fx= (length rgb) 3)
                             (fxior COLOR-RGB
                                    (fxsll (fxand 255 (car rgb)) 16)
                                    (fxsll (fxand 255 (cadr rgb)) 8)
                                    (fxand 255 (caddr rgb))))
                        (fx+ i 2 consumed)))]
             [else (values #f (fx+ i 2))]))])))

  (define (set-underline! t style)
    (terminal-attrs-set! t (fxior (fxand (terminal-attrs t) (fxnot ATTR-UNDERLINE-MASK))
                                  (fxsll style ATTR-UNDERLINE-SHIFT))))

  ;; The underline color is kept in cell extras, like hyperlinks.
  (define (set-ul-color! t c)
    (unless (eqv? c (terminal-ul-color t))
      (terminal-ul-color-set! t c)
      (update-pen! t)))

  (define (attr-on! t a) (terminal-attrs-set! t (fxior (terminal-attrs t) a)))
  (define (attr-off! t a) (terminal-attrs-set! t (fxand (terminal-attrs t) (fxnot a))))

  (define (sgr! t)
    (if (fx= 0 (param-count t))
        (begin (terminal-attrs-set! t 0) (terminal-fg-set! t COLOR-FG) (terminal-bg-set! t COLOR-BG)
               (set-ul-color! t #f))
        (let loop ([i 0])
          (when (fx< i (param-count t))
            (let ([p (param t i 0)])
              (cond
                [(fx= p 0) (terminal-attrs-set! t 0) (terminal-fg-set! t COLOR-FG)
                           (terminal-bg-set! t COLOR-BG) (set-ul-color! t #f) (loop (fx+ i 1))]
                [(fx= p 1) (attr-on! t ATTR-BOLD) (loop (fx+ i 1))]
                [(fx= p 2) (attr-on! t ATTR-DIM) (loop (fx+ i 1))]
                [(fx= p 3) (attr-on! t ATTR-ITALIC) (loop (fx+ i 1))]
                [(fx= p 4)
                 (if (and (fx< (fx+ i 1) (param-count t)) (colon? t (fx+ i 1)))
                     (begin
                       (set-underline! t (fxmin 5 (param t (fx+ i 1) 1)))
                       (loop (fx+ i 2)))
                     (begin (set-underline! t UL-SINGLE) (loop (fx+ i 1))))]
                [(or (fx= p 5) (fx= p 6)) (attr-on! t ATTR-BLINK) (loop (fx+ i 1))]
                [(fx= p 7) (attr-on! t ATTR-REVERSE) (loop (fx+ i 1))]
                [(fx= p 8) (attr-on! t ATTR-HIDDEN) (loop (fx+ i 1))]
                [(fx= p 9) (attr-on! t ATTR-STRIKE) (loop (fx+ i 1))]
                [(fx= p 21) (set-underline! t UL-DOUBLE) (loop (fx+ i 1))]
                [(fx= p 22) (attr-off! t (fxior ATTR-BOLD ATTR-DIM)) (loop (fx+ i 1))]
                [(fx= p 23) (attr-off! t ATTR-ITALIC) (loop (fx+ i 1))]
                [(fx= p 24) (set-underline! t UL-NONE) (loop (fx+ i 1))]
                [(fx= p 25) (attr-off! t ATTR-BLINK) (loop (fx+ i 1))]
                [(fx= p 27) (attr-off! t ATTR-REVERSE) (loop (fx+ i 1))]
                [(fx= p 28) (attr-off! t ATTR-HIDDEN) (loop (fx+ i 1))]
                [(fx= p 29) (attr-off! t ATTR-STRIKE) (loop (fx+ i 1))]
                [(fx<= 30 p 37) (terminal-fg-set! t (fx- p 30)) (loop (fx+ i 1))]
                [(fx= p 38) (let-values ([(c next) (extended-color t i)])
                              (when c (terminal-fg-set! t c))
                              (loop next))]
                [(fx= p 39) (terminal-fg-set! t COLOR-FG) (loop (fx+ i 1))]
                [(fx<= 40 p 47) (terminal-bg-set! t (fx- p 40)) (loop (fx+ i 1))]
                [(fx= p 48) (let-values ([(c next) (extended-color t i)])
                              (when c (terminal-bg-set! t c))
                              (loop next))]
                [(fx= p 49) (terminal-bg-set! t COLOR-BG) (loop (fx+ i 1))]
                [(fx= p 58) (let-values ([(c next) (extended-color t i)])
                              (when c (set-ul-color! t c))
                              (loop next))]
                [(fx= p 59) (set-ul-color! t #f) (loop (fx+ i 1))]
                [(fx<= 90 p 97) (terminal-fg-set! t (fx- p 82)) (loop (fx+ i 1))]
                [(fx<= 100 p 107) (terminal-bg-set! t (fx- p 92)) (loop (fx+ i 1))]
                [else (loop (fx+ i 1))]))))))

  ;;; OSC ------------------------------------------------------------------------

  (define (string-split s ch)
    (let loop ([i 0] [start 0] [acc '()])
      (cond
        [(fx= i (string-length s)) (reverse (cons (substring s start i) acc))]
        [(char=? (string-ref s i) ch) (loop (fx+ i 1) (fx+ i 1) (cons (substring s start i) acc))]
        [else (loop (fx+ i 1) start acc)])))

  ;; Parse X11 color specs: rgb:R/G/B (1-4 hex digits) or #RGB / #RRGGBB
  (define (parse-color s)
    (define (hex str)
      (and (fx<= 1 (string-length str) 4)
           (for-all (lambda (c) (hex-digit? c)) (string->list str))
           (let ([n (string->number str 16)]
                 [bits (fx* 4 (string-length str))])
             (fxquotient (fx* n 255) (fx- (fxsll 1 bits) 1)))))
    (cond
      [(and (fx> (string-length s) 4) (string=? (substring s 0 4) "rgb:"))
       (let ([parts (string-split (substring s 4 (string-length s)) #\/)])
         (and (fx= 3 (length parts))
              (let ([r (hex (car parts))] [g (hex (cadr parts))] [b (hex (caddr parts))])
                (and r g b (fxior (fxsll r 16) (fxsll g 8) b)))))]
      [(and (fx> (string-length s) 1) (char=? (string-ref s 0) #\#))
       (let* ([h (substring s 1 (string-length s))] [n (string-length h)])
         (and (memv n '(3 6 9 12))
              (let* ([k (fxquotient n 3)]
                     [r (hex (substring h 0 k))]
                     [g (hex (substring h k (fx* 2 k)))]
                     [b (hex (substring h (fx* 2 k) n))])
                (and r g b (fxior (fxsll r 16) (fxsll g 8) b)))))]
      [else #f]))

  (define (hex-digit? c)
    (or (char<=? #\0 c #\9) (char<=? #\a (char-downcase c) #\f)))

  (define (palette-index s)
    (let ([n (string->number s 10)])
      (and n (fixnum? n) (fx<= 0 n 255) n)))

  (define (color-report rgb)
    (let ([r (fxsrl rgb 16)] [g (fxand #xFF (fxsrl rgb 8))] [b (fxand #xFF rgb)])
      (format "rgb:~a/~a/~a" (hex4 r) (hex4 g) (hex4 b))))

  (define (hex4 v)
    (let ([s (number->string (fx+ (fx* v 256) v) 16)])
      (string-append (make-string (fx- 4 (string-length s)) #\0) (string-downcase s))))

  (define (osc-dispatch! t s term)
    (let* ([semi (let loop ([i 0])
                   (cond [(fx= i (string-length s)) #f]
                         [(char=? (string-ref s i) #\;) i]
                         [else (loop (fx+ i 1))]))]
           [code (let ([n (string->number (if semi (substring s 0 semi) s) 10)])
                   (and n (fixnum? n) n))]
           [rest (if semi (substring s (fx+ semi 1) (string-length s)) "")]
           [palette (terminal-palette t)])
      (terminal-dirty-set! t #t)
      (case code
        [(0 2) (set-title! t rest)]
        [(1) (void)]
        [(4)
         (let loop ([parts (string-split rest #\;)])
           (when (and (pair? parts) (pair? (cdr parts)))
             (let ([idx (palette-index (car parts))] [spec (cadr parts)])
               (when idx
                 (if (string=? spec "?")
                     (respond t (format "\x1b;]4;~a;~a~a" idx (color-report (vector-ref palette idx)) term))
                     (let ([c (parse-color spec)])
                       (when c (vector-set! palette idx c))))))
             (loop (cddr parts))))]
        [(10 11 12)
         (let loop ([specs (string-split rest #\;)] [code code])
           (when (and (pair? specs) (fx<= code 12))
             (let ([slot (case code [(10) COLOR-FG] [(11) COLOR-BG] [else COLOR-CURSOR])])
               (if (string=? (car specs) "?")
                   (respond t (format "\x1b;]~a;~a~a" code (color-report (vector-ref palette slot)) term))
                   (let ([c (parse-color (car specs))])
                     (when c (vector-set! palette slot c)))))
             (loop (cdr specs) (fx+ code 1))))]
        [(104)
         (if (string=? rest "")
             (do ([i 0 (fx+ i 1)]) ((fx= i 256))
               (vector-set! palette i (vector-ref (terminal-default-palette t) i)))
             (for-each (lambda (p)
                         (let ([i (palette-index p)])
                           (when i
                             (vector-set! palette i (vector-ref (terminal-default-palette t) i)))))
                       (string-split rest #\;)))]
        [(110) (vector-set! palette COLOR-FG (vector-ref (terminal-default-palette t) COLOR-FG))]
        [(111) (vector-set! palette COLOR-BG (vector-ref (terminal-default-palette t) COLOR-BG))]
        [(112) (vector-set! palette COLOR-CURSOR (vector-ref (terminal-default-palette t) COLOR-CURSOR))]
        [(7)
         ;; file://host/path
         (when (and (fx> (string-length rest) 7) (string=? (substring rest 0 7) "file://"))
           (let* ([p (substring rest 7 (string-length rest))]
                  [slash (let loop ([i 0])
                           (cond [(fx= i (string-length p)) #f]
                                 [(char=? (string-ref p i) #\/) i]
                                 [else (loop (fx+ i 1))]))])
             (when slash
               (terminal-cwd-set! t (percent-decode (substring p slash (string-length p)))))))]
        [(8) (osc-hyperlink! t rest)]
        [(52)
         (let ([parts (string-split rest #\;)])
           (when (and (fx= 2 (length parts)) (not (string=? (cadr parts) "?")))
             (let ([data (base64-decode (cadr parts))])
               (when data ((terminal-on-clipboard t) (utf8->string data))))))]
        [else (void)])))

;;; OSC 8 hyperlinks --------------------------------------------------------
  ;;; OSC 8 ; params ; URI ST starts a link that the following characters get,
  ;;; an empty URI ends it (gist.github.com/egmontkob/eb114294efbcd5adb1944c9f3cb5feda).
  ;;; Cells hold a link id in their cell extra, and the terminal maps ids to
  ;;; URIs.  Every OSC 8 without an id= parameter starts a link of its own;
  ;;; with one, runs with the same id and URI get the same link id, so that a
  ;;; link a program draws in pieces is one link.  A URI must be printable
  ;;; ASCII of at most max-uri-length bytes; an invalid OSC 8 ends the link.

  (define max-uri-length 2083)
  (define max-link-id-length 256)
  (define max-links 16384)

  (define (terminal-link-uri t id)
    (and (fx> id 0) (let ([e (hashtable-ref (terminal-links t) id #f)]) (and e (car e)))))

  (define (terminal-link-count t) (hashtable-size (terminal-links t)))

  (define (printable-ascii? s)
    (let loop ([i 0])
      (or (fx= i (string-length s))
          (and (char<=? #\space (string-ref s i) #\~) (loop (fx+ i 1))))))

  (define (osc-hyperlink! t rest)
    (let ([semi (let loop ([i 0])
                  (cond [(fx= i (string-length rest)) #f]
                        [(char=? (string-ref rest i) #\;) i]
                        [else (loop (fx+ i 1))]))])
      (set-link! t
                 (if (not semi)
                     0
                     (let ([params (substring rest 0 semi)]
                           [uri (substring rest (fx+ semi 1) (string-length rest))])
                       (let ([id (let loop ([ps (string-split params #\:)])
                                   (cond
                                     [(null? ps) #f]
                                     [(and (fx> (string-length (car ps)) 3)
                                           (string=? (substring (car ps) 0 3) "id="))
                                      (substring (car ps) 3 (string-length (car ps)))]
                                     [else (loop (cdr ps))]))])
                         (if (and (fx> (string-length uri) 0)
                                  (fx<= (string-length uri) max-uri-length)
                                  (printable-ascii? uri)
                                  (or (not id) (and (fx<= (string-length id) max-link-id-length)
                                                    (printable-ascii? id))))
                             (link-id! t id uri)
                             0)))))))

  (define (set-link! t id)
    (terminal-link-set! t id)
    (update-pen! t))

  (define (update-pen! t)
    (terminal-pen-extra-set! t (make-extra "" (terminal-link t) (terminal-ul-color t))))

  ;; The id for a new link to URI (with id parameter ID, or #f), or 0 when
  ;; there is no room for it.
  (define (link-id! t id uri)
    (or (and id (hashtable-ref (terminal-link-ids t) (cons id uri) #f))
        (and (or (fx< (hashtable-size (terminal-links t)) max-links) (make-room-for-link! t))
             (let ([n (terminal-link-next t)] [key (and id (cons id uri))])
               (terminal-link-next-set! t (fx+ n 1))
               (hashtable-set! (terminal-links t) n (cons uri key))
               (when key (hashtable-set! (terminal-link-ids t) key n))
               n))
        0))

  ;; With the table full, forget the links no cell uses any more, and if
  ;; that is not enough, those only the history uses (as kitty does); their
  ;; cells then have no link.  When even that is not enough, the next
  ;; max-links / 16 new links are dropped without trying again.  Ids are
  ;; never reused, so a forgotten id cannot come back with another URI.
  (define (make-room-for-link! t)
    (cond
      [(fx> (terminal-link-gc-pause t) 0)
       (terminal-link-gc-pause-set! t (fx- (terminal-link-gc-pause t) 1))
       #f]
      [else
       (collect-links! t #t)
       (unless (fx< (hashtable-size (terminal-links t)) max-links) (collect-links! t #f))
       (or (fx< (hashtable-size (terminal-links t)) max-links)
           (begin (terminal-link-gc-pause-set! t (fxquotient max-links 16)) #f))]))

  (define (collect-links! t history?)
    (let ([used (make-eqv-hashtable)])
      (hashtable-set! used (terminal-link t) #t)
      (for-each
       (lambda (g)
         (do ([r (if history? (fx- (grid-hist-count g)) 0) (fx+ r 1)]) ((fx= r (grid-rows g)))
           (let ([ex (line-extra (grid-line g r))])
             (when ex
               (vector-for-each (lambda (x) (hashtable-set! used (extra-link x) #t))
                                (hashtable-values ex))))))
       (list (terminal-primary-grid t) (terminal-alt-grid t)))
      (let-values ([(ids entries) (hashtable-entries (terminal-links t))])
        (vector-for-each
         (lambda (id e)
           (unless (hashtable-contains? used id)
             (hashtable-delete! (terminal-links t) id)
             (when (cdr e) (hashtable-delete! (terminal-link-ids t) (cdr e)))))
         ids entries))))

  (define (percent-decode s)
    (let-values ([(out extract) (open-bytevector-output-port)])
      (let loop ([i 0] [n (string-length s)])
        (cond
          [(fx= i n) (utf8->string (extract))]
          [(and (char=? (string-ref s i) #\%) (fx< (fx+ i 2) n)
                (hex-digit? (string-ref s (fx+ i 1))) (hex-digit? (string-ref s (fx+ i 2)))
                (string->number (substring s (fx+ i 1) (fx+ i 3)) 16))
           => (lambda (b) (put-u8 out b) (loop (fx+ i 3) n))]
          [else (put-bytevector out (string->utf8 (string (string-ref s i)))) (loop (fx+ i 1) n)]))))

  (define (base64-decode s)
    (define (val c)
      (cond [(char<=? #\A c #\Z) (fx- (char->integer c) 65)]
            [(char<=? #\a c #\z) (fx+ 26 (fx- (char->integer c) 97))]
            [(char<=? #\0 c #\9) (fx+ 52 (fx- (char->integer c) 48))]
            [(char=? c #\+) 62]
            [(char=? c #\/) 63]
            [else #f]))
    (let-values ([(out extract) (open-bytevector-output-port)])
      (let loop ([i 0] [acc 0] [bits 0])
        (if (fx= i (string-length s))
            (extract)
            (let ([v (val (string-ref s i))])
              (if v
                  (let ([acc (fxior (fxsll (fxand acc #xFFFF) 6) v)] [bits (fx+ bits 6)])
                    (if (fx>= bits 8)
                        (begin (put-u8 out (fxand #xFF (fxsrl acc (fx- bits 8))))
                               (loop (fx+ i 1) acc (fx- bits 8)))
                        (loop (fx+ i 1) acc bits)))
                  (loop (fx+ i 1) acc bits)))))))

  ;;; DCS ------------------------------------------------------------------------

  (define (dcs-dispatch! t s)
    ;; DECRQSS: DCS $ q <setting> ST
    (when (and (fx>= (string-length s) 2) (string=? (substring s 0 2) "$q"))
      (let ([what (substring s 2 (string-length s))])
        (cond
          [(string=? what "m") (respond t (format "\x1b;P1$r~am\x1b;\\" (sgr-report t)))]
          [(string=? what "r")
           (respond t (format "\x1b;P1$r~a;~ar\x1b;\\" (fx+ 1 (terminal-top t)) (fx+ 1 (terminal-bottom t))))]
          [(string=? what " q")
           (respond t (format "\x1b;P1$r~a q\x1b;\\"
                              (fx+ (case (terminal-cursor-style t) [(block) 1] [(underline) 3] [else 5])
                                   (if (terminal-cursor-blink t) 0 1))))]
          [else (respond t "\x1b;P0$r\x1b;\\")]))))

  ;; The current SGR attributes as DECRQSS reports them, in the forms kitty
  ;; uses: "0;1;4:3;38:5:196;58:2:255:0:0".
  (define (sgr-report t)
    (let ([a (terminal-attrs t)] [o (open-output-string)])
      (define (color base bright ext c default)
        (cond
          [(eqv? c default) (void)]
          [(fxlogtest c COLOR-RGB)
           (format o ";~a:2:~a:~a:~a" ext (fxsrl (fxand c #xFF0000) 16) (fxsrl (fxand c #xFF00) 8)
                   (fxand c #xFF))]
          [(and base (fx< c 8)) (format o ";~a" (fx+ base c))]
          [(and bright (fx< c 16)) (format o ";~a" (fx+ bright (fx- c 8)))]
          [else (format o ";~a:5:~a" ext c)]))
      (put-string o "0")
      (for-each (lambda (bit code) (when (fxlogtest a bit) (format o ";~a" code)))
                (list ATTR-BOLD ATTR-DIM ATTR-ITALIC) '(1 2 3))
      (let ([ul (fxsrl (fxand a ATTR-UNDERLINE-MASK) ATTR-UNDERLINE-SHIFT)])
        (cond [(fx= ul UL-SINGLE) (put-string o ";4")]
              [(fx> ul UL-SINGLE) (format o ";4:~a" ul)]))
      (for-each (lambda (bit code) (when (fxlogtest a bit) (format o ";~a" code)))
                (list ATTR-BLINK ATTR-REVERSE ATTR-HIDDEN ATTR-STRIKE) '(5 7 8 9))
      (color 30 90 38 (terminal-fg t) COLOR-FG)
      (color 40 100 48 (terminal-bg t) COLOR-BG)
      (color #f #f 58 (terminal-ul-color t) #f)
      (get-output-string o)))

  ;;; Reset & resize -------------------------------------------------------------

  (define (soft-reset! t)
    (terminal-cursor-visible-set! t #t)
    (terminal-origin-mode-set! t #f)
    (terminal-autowrap-set! t #t)
    (terminal-insert-mode-set! t #f)
    (terminal-app-cursor-set! t #f)
    (terminal-app-keypad-set! t #f)
    (terminal-top-set! t 0)
    (terminal-bottom-set! t (fx- (terminal-rows t) 1))
    (terminal-attrs-set! t 0)
    (terminal-fg-set! t COLOR-FG)
    (terminal-bg-set! t COLOR-BG)
    (terminal-ul-color-set! t #f)
    (terminal-charsets-set! t (vector 'ascii 'ascii 'ascii 'ascii))
    (terminal-gl-set! t 0)
    (terminal-saved-primary-set! t #f)
    (terminal-saved-alt-set! t #f)
    (terminal-wrap-pending-set! t #f)
    ;; as in kitty, both screens' kitty keyboard flags go, and so does the
    ;; hyperlink being printed
    (terminal-kbd-primary-set! t '())
    (terminal-kbd-alt-set! t '())
    (set-link! t 0))

  (define (terminal-reset! t)
    (leave-alt-screen! t)
    (soft-reset! t)
    (terminal-newline-mode-set! t #f)
    (terminal-cursor-style-set! t (terminal-default-cursor-style t))
    (terminal-cursor-blink-set! t (terminal-default-cursor-blink t))
    (terminal-bracketed-paste-set! t #f)
    (terminal-mouse-mode-set! t #f)
    (terminal-mouse-sgr-set! t #f)
    (terminal-mouse-utf8-set! t #f)
    (terminal-focus-events-set! t #f)
    (terminal-reverse-video-set! t #f)
    (terminal-sync-update-set! t #f)
    (terminal-palette-set! t (vector-copy (terminal-default-palette t)))
    (terminal-tabs-set! t (make-tabs (terminal-cols t)))
    (terminal-cursor-row-set! t 0)
    (terminal-cursor-col-set! t 0)
    (do ([r 0 (fx+ r 1)]) ((fx= r (terminal-rows t)))
      (line-clear! (grid-screen-line (terminal-grid t) r) COLOR-BG))
    (terminal-clear-history! t)
    (hashtable-clear! (terminal-links t))
    (hashtable-clear! (terminal-link-ids t))
    (terminal-link-gc-pause-set! t 0)
    (terminal-selection-clear! t)
    (terminal-dirty-set! t #t))

  (define (terminal-resize! t rows cols)
    (unless (and (fx= rows (terminal-rows t)) (fx= cols (terminal-cols t)))
      (let ([alt (terminal-alt-screen t)])
        ;; primary grid: reflow, anchored at the primary screen's cursor
        (let* ([saved (terminal-saved-primary t)]
               [pc (if alt
                       (or (terminal-primary-cursor t) (cons 0 0))
                       (cons (terminal-cursor-row t) (terminal-cursor-col t)))]
               [crow (fxmin (car pc) (fx- (terminal-rows t) 1))]
               [ccol (fxmin (cdr pc) (fx- (terminal-cols t) 1))])
          (let-values ([(r c) (grid-resize! (terminal-primary-grid t) rows cols #t crow ccol)])
            (if alt
                (terminal-primary-cursor-set! t (cons r c))
                (begin (terminal-cursor-row-set! t r) (terminal-cursor-col-set! t c)))
            ;; a cursor saved at the anchor position follows the content;
            ;; other saved positions are kept inside the screen
            (when saved
              (if (and (fx= (vector-ref saved 0) crow) (fx= (vector-ref saved 1) ccol))
                  (begin (vector-set! saved 0 r) (vector-set! saved 1 c))
                  (begin (vector-set! saved 0 (fxmin (vector-ref saved 0) (fx- rows 1)))
                         (vector-set! saved 1 (fxmin (vector-ref saved 1) (fx- cols 1))))))))
        (let ([saved (terminal-saved-alt t)])
          (when saved
            (vector-set! saved 0 (fxmin (vector-ref saved 0) (fx- rows 1)))
            (vector-set! saved 1 (fxmin (vector-ref saved 1) (fx- cols 1)))))
        ;; alternate grid: plain truncate / extend
        (let-values ([(r c) (grid-resize! (terminal-alt-grid t) rows cols #f
                                          (if alt (terminal-cursor-row t) 0)
                                          (if alt (terminal-cursor-col t) 0))])
          (when alt (terminal-cursor-row-set! t r) (terminal-cursor-col-set! t c)))
        (grid-clear-history! (terminal-alt-grid t))
        (terminal-rows-set! t rows)
        (terminal-cols-set! t cols)
        (terminal-top-set! t 0)
        (terminal-bottom-set! t (fx- rows 1))
        (terminal-tabs-set! t (make-tabs cols))
        (terminal-wrap-pending-set! t #f)
        (terminal-display-offset-set! t 0)
        (terminal-selection-clear! t)
        (clamp-cursor! t)
        (terminal-dirty-set! t #t)))))
