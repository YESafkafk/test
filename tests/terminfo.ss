;;; Check the chezterm terminfo entries against the emulator.
;;;
;;; Every capability is expanded by ncurses' tput (from the compiled entry in
;;; $TERMINFO), fed to the terminal emulator, and its effect is checked.  Key
;;; capabilities are compared with what chezterm sends for those keys.
;;;
;;;   TERMINFO=build/terminfo scheme --libdirs build/lib --script tests/terminfo.ss
(import (chezscheme) (chezterm grid) (chezterm terminal) (chezterm charwidth)
        (chezterm keyboard))

(define failures 0)
(define passes 0)

(define-syntax check
  (syntax-rules ()
    [(_ name expected expr)
     (let ([e expected] [v (guard (c [#t (list 'exception (condition-message c))]) expr)])
       (if (equal? e v)
           (set! passes (+ passes 1))
           (begin
             (set! failures (+ failures 1))
             (printf "FAIL ~a\n  expected: ~s\n  got:      ~s\n" name e v))))]))

(define terminfo (getenv "TERMINFO"))

(define (have-tput?)
  (guard (c [#t #f])
    (= 0 (system "command -v tput >/dev/null 2>&1"))))

(unless (and terminfo (have-tput?)
             (or (file-exists? (string-append terminfo "/c/chezterm"))
                 (file-exists? (string-append terminfo "/63/chezterm"))))
  (printf "terminfo tests skipped (need tput and the compiled entry in $TERMINFO)\n")
  (exit 0))

;; Bytes tput prints for capability CAP of terminal TERM with ARGS.
(define (tput term cap . args)
  (let-values ([(to from err pid)
                (open-process-ports
                 (apply string-append "tput -T " term " " cap
                        (map (lambda (a) (format " '~a'" a)) args))
                 (buffer-mode block) #f)])
    (close-port to)
    (let ([bv (get-bytevector-all from)])
      (close-port from) (close-port err)
      (if (eof-object? bv) (make-bytevector 0) bv))))

(init-charwidth!)

(define palette (make-default-palette (make-list 8 0) (make-list 8 0) #xffffff 0 #xffffff))
(define responses '())
(define title #f)
(define clipboard #f)

(define (make-term)
  (let ([t (make-terminal 10 40 100 palette 'block #f)])
    (set! responses '())
    (terminal-set-callbacks! t
      (lambda (s) (set! responses (cons s responses)))
      (lambda (s) (set! title s))
      void
      (lambda (s) (set! clipboard s)))
    t))

(define (feed-bv t bv) (terminal-feed! t bv (bytevector-length bv)))
(define (feed t s) (feed-bv t (string->utf8 s)))
;; feed capability CAP of the "chezterm" entry
(define (cap t name . args) (feed-bv t (apply tput "chezterm" name args)))

(define (cell t row col) (cons (line-cells (grid-line (terminal-grid t) row)) col))
(define (attrs-at t row col) (let ([c (cell t row col)]) (cell-attrs (car c) (cdr c))))
(define (fg-at t row col) (let ([c (cell t row col)]) (cell-fg (car c) (cdr c))))
(define (bg-at t row col) (let ([c (cell t row col)]) (cell-bg (car c) (cdr c))))
(define (char-at t row col)
  (let* ([c (cell t row col)] [cp (cell-ch (car c) (cdr c))]) (if (= cp 0) #\space (integer->char cp))))
(define (cursor t) (list (terminal-cursor-row t) (terminal-cursor-col t)))

;;; Cursor movement, editing ------------------------------------------------

(let ([t (make-term)])
  (cap t "cup" 4 9) (check "cup" '(4 9) (cursor t))
  (cap t "cuu" 2) (check "cuu" '(2 9) (cursor t))
  (cap t "cud" 3) (check "cud" '(5 9) (cursor t))
  (cap t "cuf" 5) (check "cuf" '(5 14) (cursor t))
  (cap t "cub" 4) (check "cub" '(5 10) (cursor t))
  (cap t "hpa" 3) (check "hpa" '(5 3) (cursor t))
  (cap t "vpa" 7) (check "vpa" '(7 3) (cursor t))
  (cap t "home") (check "home" '(0 0) (cursor t))
  (cap t "sc") (cap t "cup" 3 3) (cap t "rc") (check "sc/rc" '(0 0) (cursor t))
  (cap t "ht") (check "ht" '(0 8) (cursor t))
  (cap t "cbt") (check "cbt" '(0 0) (cursor t)))

(let ([t (make-term)])
  (feed t "abcdef")
  (cap t "cup" 0 1) (cap t "dch" 2)
  (check "dch" #\d (char-at t 0 1))
  (cap t "ich" 1) (check "ich" #\space (char-at t 0 1))
  (cap t "ech" 2) (check "ech" #\space (char-at t 0 2))
  (cap t "cup" 0 0) (cap t "rep" (char->integer #\x) 5)
  (check "rep" '(#\x #\x #\x #\x #\x #\space) (map (lambda (c) (char-at t 0 c)) (iota 6)))
  (cap t "el1") (check "el1" #\space (char-at t 0 3))
  (cap t "cup" 0 0) (feed t "zz") (cap t "cup" 0 0) (cap t "el")
  (check "el" #\space (char-at t 0 1)))

(let ([t (make-term)])
  (feed t "1\r\n2\r\n3")
  (cap t "cup" 1 0) (cap t "dl1")
  (check "dl1" #\3 (char-at t 1 0))
  (cap t "il1") (check "il1" #\space (char-at t 1 0))
  (cap t "clear") (check "clear" #\space (char-at t 0 0))
  (check "clear homes" '(0 0) (cursor t)))

(let ([t (make-term)])
  (cap t "csr" 2 5) (cap t "cup" 5 0) (feed t "x") (cap t "ind")
  (check "csr + ind scrolls the region" #\x (char-at t 4 0))
  (cap t "indn" 2) (check "indn" #\space (char-at t 4 0))
  (cap t "rin" 3) (check "rin" #\x (char-at t 5 0)))

(let ([t (make-term)])
  (feed t "1\r\n2\r\n3\r\n4\r\n5\r\n6\r\n7\r\n8\r\n9\r\n10\r\n11\r\n12")
  (check "history before E3" #t (> (grid-hist-count (terminal-grid t)) 0))
  (cap t "E3") (check "E3" 0 (grid-hist-count (terminal-grid t))))

;;; Attributes and colors ---------------------------------------------------

(define (attr-after t cap-name . args)
  (apply cap t cap-name args)
  (feed t "x")
  (let ([a (attrs-at t (terminal-cursor-row t) (- (terminal-cursor-col t) 1))])
    (cap t "sgr0")
    a))

(let ([t (make-term)])
  (check "bold" ATTR-BOLD (fxand ATTR-BOLD (attr-after t "bold")))
  (check "dim" ATTR-DIM (fxand ATTR-DIM (attr-after t "dim")))
  (check "sitm" ATTR-ITALIC (fxand ATTR-ITALIC (attr-after t "sitm")))
  (check "rev" ATTR-REVERSE (fxand ATTR-REVERSE (attr-after t "rev")))
  (check "smso" ATTR-REVERSE (fxand ATTR-REVERSE (attr-after t "smso")))
  (check "invis" ATTR-HIDDEN (fxand ATTR-HIDDEN (attr-after t "invis")))
  (check "smxx" ATTR-STRIKE (fxand ATTR-STRIKE (attr-after t "smxx")))
  (check "blink" ATTR-BLINK (fxand ATTR-BLINK (attr-after t "blink")))
  (check "smul" UL-SINGLE (fxsrl (fxand ATTR-UNDERLINE-MASK (attr-after t "smul")) ATTR-UNDERLINE-SHIFT))
  (for-each
   (lambda (style)
     (check (format "Smulx ~a" style) style
            (fxsrl (fxand ATTR-UNDERLINE-MASK (attr-after t "Smulx" style)) ATTR-UNDERLINE-SHIFT)))
   (list UL-DOUBLE UL-CURLY UL-DOTTED UL-DASHED UL-NONE))
  (cap t "sitm") (cap t "ritm") (feed t "y")
  (check "ritm" 0 (fxand ATTR-ITALIC (attrs-at t 0 (- (terminal-cursor-col t) 1))))
  (check "sgr bold+underline" (fxior ATTR-BOLD (fxsll UL-SINGLE ATTR-UNDERLINE-SHIFT))
         (fxand (fxior ATTR-BOLD ATTR-UNDERLINE-MASK) (attr-after t "sgr" 0 1 0 0 0 1 0 0 0))))

(define (ul-color-at t row col) (line-ul-color (grid-line (terminal-grid t) row) col))

(let ([t (make-term)])
  (for-each
   (lambda (term rgb)
     (feed-bv t (tput term "Setulc" rgb)) (cap t "Smulx" UL-CURLY) (feed t "u")
     (check (format "~a Setulc ~x" term rgb) (fxior COLOR-RGB rgb)
            (ul-color-at t (terminal-cursor-row t) (- (terminal-cursor-col t) 1))))
   '("chezterm" "chezterm" "chezterm-direct" "chezterm-direct")
   '(#x123456 #xFF0000 #x00FF00 #x0000FF))
  (cap t "sgr0") (feed t "v")
  (check "sgr0 resets the underline color" #f
         (ul-color-at t (terminal-cursor-row t) (- (terminal-cursor-col t) 1))))

(let ([t (make-term)])
  (cap t "setaf" 1) (cap t "setab" 12) (feed t "a")
  (check "setaf < 8" 1 (fg-at t 0 0))
  (check "setab 8-15" 12 (bg-at t 0 0))
  (cap t "setaf" 196) (feed t "b")
  (check "setaf 256" 196 (fg-at t 0 1))
  (cap t "op") (feed t "c")
  (check "op" (list COLOR-FG COLOR-BG) (list (fg-at t 0 2) (bg-at t 0 2)))
  (feed-bv t (tput "chezterm-direct" "setaf" #x123456))
  (feed-bv t (tput "chezterm-direct" "setab" #xABCDEF))
  (feed t "d")
  (check "direct setaf" (fxior COLOR-RGB #x123456) (fg-at t 0 3))
  (check "direct setab" (fxior COLOR-RGB #xABCDEF) (bg-at t 0 3))
  (feed-bv t (tput "chezterm-direct" "setaf" 3)) (feed t "e")
  (check "direct setaf < 8 uses the palette" 3 (fg-at t 0 4))
  (cap t "initc" 1 1000 0 0)
  (check "initc" #xff0000 (vector-ref (terminal-palette t) 1))
  (cap t "oc")
  (check "oc" 0 (vector-ref (terminal-palette t) 1)))

(let ([t (make-term)])
  (cap t "smacs") (feed t "q") (cap t "rmacs") (feed t "q")
  (check "smacs/rmacs" '(#\x2500 #\q) (list (char-at t 0 0) (char-at t 0 1))))

;;; Modes --------------------------------------------------------------------

(let ([t (make-term)])
  (feed t "main")
  (cap t "smcup") (check "smcup" #t (terminal-alt-screen? t))
  (cap t "rmcup") (check "rmcup" #f (terminal-alt-screen? t))
  (check "rmcup restores the screen" #\m (char-at t 0 0))
  (cap t "civis") (check "civis" #f (terminal-cursor-visible? t))
  (cap t "cnorm") (check "cnorm" #t (terminal-cursor-visible? t))
  (cap t "cvvis") (check "cvvis blinks" #t (terminal-cursor-blink? t))
  (cap t "smkx") (check "smkx" #t (terminal-app-cursor? t))
  (cap t "rmkx") (check "rmkx" #f (terminal-app-cursor? t))
  (cap t "rmam") (feed t (make-string 50 #\a)) (check "rmam" 0 (terminal-cursor-row t))
  (cap t "smam")
  (cap t "BE") (check "BE" #t (terminal-bracketed-paste? t))
  (cap t "BD") (check "BD" #f (terminal-bracketed-paste? t))
  (cap t "fe") (check "fe" #t (terminal-focus-events? t))
  (cap t "fd") (check "fd" #f (terminal-focus-events? t))
  (cap t "XM" 1) (check "XM on" (list 'click #t) (list (terminal-mouse-mode t) (terminal-mouse-sgr? t)))
  (cap t "XM" 0) (check "XM off" (list #f #f) (list (terminal-mouse-mode t) (terminal-mouse-sgr? t)))
  (cap t "Sync" 1) (check "Sync begin" #t (and (terminal-sync-update? t) #t))
  (cap t "Sync" 2) (check "Sync end" #f (terminal-sync-update? t))
  (cap t "Ss" 6) (check "Ss 6" '(beam #f) (list (terminal-cursor-style t) (terminal-cursor-blink? t)))
  (cap t "Ss" 3) (check "Ss 3" '(underline #t) (list (terminal-cursor-style t) (terminal-cursor-blink? t)))
  (cap t "Se") (check "Se restores the configured cursor" '(block #f)
                      (list (terminal-cursor-style t) (terminal-cursor-blink? t)))
  (cap t "smir") (feed t "\r12\r0") (check "smir" #\1 (char-at t 0 1)) (cap t "rmir")
  (cap t "flash") (check "flash ends in normal video" #f (terminal-reverse-video? t)))

(let ([t (make-term)])
  (cap t "Cs" "rgb:12/34/56")
  (check "Cs" #x123456 (vector-ref (terminal-palette t) COLOR-CURSOR))
  (cap t "Cr")
  (check "Cr" #xffffff (vector-ref (terminal-palette t) COLOR-CURSOR))
  (cap t "tsl") (feed t "window title") (cap t "fsl")
  (check "tsl/fsl" "window title" title)
  (cap t "dsl") (check "dsl" "" title)
  (cap t "Ms" "c" "aGVsbG8=")
  (check "Ms" "hello" clipboard))

(let ([t (make-term)])
  (cap t "cup" 2 4) (cap t "u7")
  ;; u6 (the report format, %i%d;%dR) pops its parameters off the stack,
  ;; so tput hands them over reversed: column first
  (check "u7 answered as u6" (list (utf8->string (tput "chezterm" "u6" 4 2))) responses)
  (set! responses '())
  (cap t "u9") (check "u9 answered" 1 (length responses))
  (set! responses '())
  (cap t "RV") (check "RV answer matches rv" "\x1b;[>1;4000;0c" (car responses))
  (set! responses '())
  (cap t "XR") (check "XR answer" #t (and (pair? responses)
                                          (string=? (substring (car responses) 0 12) "\x1b;P>|chezterm")))
  (cap t "rs1") (check "rs1" '(0 0) (cursor t)))

;;; Keys: what the entry declares is what chezterm sends ----------------------

(define (sends name mods . modes)
  (let ([m (if (null? modes) '(#f #f #f) modes)])
    (string->utf8 (apply encode-key (make-key-event (keysym-by-name name) "" mods) m))))

(define app-mode '(#t #t #f))

(for-each
 (lambda (k)
   (let ([cap-name (car k)] [key (cadr k)] [mods (caddr k)] [app (and (pair? (cdddr k)) (cadddr k))])
     (check (format "key ~a" cap-name) (tput "chezterm" cap-name)
            (if app (apply sends key mods app-mode) (sends key mods)))))
 `(("kcuu1" "Up" 0 #t) ("kcud1" "Down" 0 #t) ("kcuf1" "Right" 0 #t) ("kcub1" "Left" 0 #t)
   ("khome" "Home" 0 #t) ("kend" "End" 0 #t) ("kent" "KP_Enter" 0 #t)
   ("kbs" "BackSpace" 0) ("kcbt" "ISO_Left_Tab" 0)
   ("kich1" "Insert" 0) ("kdch1" "Delete" 0) ("kpp" "Prior" 0) ("knp" "Next" 0)
   ("kf1" "F1" 0) ("kf4" "F4" 0) ("kf5" "F5" 0) ("kf10" "F10" 0) ("kf12" "F12" 0)
   ("kf13" "F1" ,MOD-SHIFT) ("kf17" "F5" ,MOD-SHIFT) ("kf25" "F1" ,MOD-CTRL)
   ("kf29" "F5" ,MOD-CTRL) ("kf37" "F1" ,(fxior MOD-CTRL MOD-SHIFT)) ("kf49" "F1" ,MOD-ALT)
   ("kf60" "F12" ,MOD-ALT) ("kf61" "F1" ,(fxior MOD-ALT MOD-SHIFT))
   ("kri" "Up" ,MOD-SHIFT) ("kind" "Down" ,MOD-SHIFT)
   ("kLFT" "Left" ,MOD-SHIFT) ("kRIT" "Right" ,MOD-SHIFT)
   ("kHOM" "Home" ,MOD-SHIFT) ("kEND" "End" ,MOD-SHIFT)
   ("kIC" "Insert" ,MOD-SHIFT) ("kDC" "Delete" ,MOD-SHIFT)
   ("kPRV" "Prior" ,MOD-SHIFT) ("kNXT" "Next" ,MOD-SHIFT)
   ("kUP3" "Up" ,MOD-ALT) ("kDC3" "Delete" ,MOD-ALT)
   ("kUP5" "Up" ,MOD-CTRL) ("kLFT5" "Left" ,MOD-CTRL) ("kDC5" "Delete" ,MOD-CTRL)
   ("kNXT5" "Next" ,MOD-CTRL) ("kHOM6" "Home" ,(fxior MOD-CTRL MOD-SHIFT))
   ("kEND7" "End" ,(fxior MOD-CTRL MOD-ALT))
   ("kpADD" "KP_Add" 0 #t) ("kpSUB" "KP_Subtract" 0 #t) ("kpMUL" "KP_Multiply" 0 #t)
   ("kpDIV" "KP_Divide" 0 #t) ("kpDOT" "KP_Decimal" 0 #t) ("kpZRO" "KP_0" 0 #t)
   ("kc1" "KP_1" 0 #t) ("kc3" "KP_3" 0 #t) ("ka1" "KP_7" 0 #t) ("ka3" "KP_9" 0 #t)
   ("kb2" "KP_5" 0 #t)))

(let ([t (make-term)])
  (check "focus in key" (tput "chezterm" "kxIN") (string->utf8 "\x1b;[I"))
  (check "paste start" (tput "chezterm" "PS") (string->utf8 "\x1b;[200~")))

(printf "~a passed, ~a failed (terminfo)\n" passes failures)
(exit (if (= failures 0) 0 1))
