;;; Test runner: scheme --libdirs src --script tests/run.ss
(import (chezscheme) (chezterm grid) (chezterm terminal) (chezterm charwidth)
        (chezterm font) (chezterm render) (chezterm selection) (chezterm keyboard)
        (chezterm termenv))

(define failures 0)
(define passes 0)

(define-syntax check
  (syntax-rules ()
    [(_ name expected expr)
     (let ([e expected] [v (guard (c [#t (list 'exception (condition-message-string c))]) expr)])
       (if (equal? e v)
           (set! passes (+ passes 1))
           (begin
             (set! failures (+ failures 1))
             (printf "FAIL ~a\n  expected: ~s\n  got:      ~s\n" name e v))))]))

(define (condition-message-string c)
  (if (message-condition? c)
      (apply format (condition-message c)
             (if (irritants-condition? c) (condition-irritants c) '()))
      (format "~s" c)))

(init-charwidth!)

(define palette
  (make-default-palette (make-list 8 0) (make-list 8 0) #xffffff 0 #xffffff))

(define responses '())

(define (make-term rows cols . hist)
  (let ([t (make-terminal rows cols (if (pair? hist) (car hist) 100) palette 'block #f)])
    (set! responses '())
    (terminal-set-callbacks! t
      (lambda (s) (set! responses (cons s responses)))
      (lambda (s) (void)) (lambda () (void)) (lambda (s) (void)))
    t))

(define (feed t . strs)
  (let ([bv (string->utf8 (apply string-append strs))])
    (terminal-feed! t bv (bytevector-length bv))))

(define (feed-bytes t bv) (terminal-feed! t bv (bytevector-length bv)))

(define (row-text t row)
  (let* ([l (grid-line (terminal-grid t) row)] [v (line-cells l)] [n (line-cols l)])
    (let loop ([i 0] [acc '()])
      (if (= i n)
          (let* ([s (list->string (reverse acc))])
            ;; trim right
            (let trim ([k (string-length s)])
              (if (and (> k 0) (char=? (string-ref s (- k 1)) #\space))
                  (trim (- k 1))
                  (substring s 0 k))))
          (let ([a (cell-attrs v i)])
            (loop (+ i 1)
                  (if (fxlogtest a ATTR-SPACER)
                      acc
                      (cons (let ([c (cell-ch v i)]) (if (= c 0) #\space (integer->char c))) acc))))))))

(define (screen t)
  (let loop ([r (- (terminal-rows t) 1)] [acc '()])
    (if (< r 0) acc (loop (- r 1) (cons (row-text t r) acc)))))

(define (cursor t) (list (terminal-cursor-row t) (terminal-cursor-col t)))

(define (esc . parts) (apply string-append "\x1b;" parts))

;;; ---------------------------------------------------------------------------

(let ([t (make-term 3 10)])
  (feed t "hello\r\nworld")
  (check "basic text" '("hello" "world" "") (screen t))
  (check "cursor after text" '(1 5) (cursor t)))

(let ([t (make-term 3 5)])
  (feed t "abcdefg")
  (check "autowrap" '("abcde" "fg" "") (screen t))
  (check "wrap flag" #t (line-wrapped (grid-line (terminal-grid t) 0))))

(let ([t (make-term 3 5)])
  (feed t "abcde")
  (check "pending wrap keeps cursor" '(0 4) (cursor t))
  (feed t "\r\n")
  (check "no extra line after exact fill" '(1 0) (cursor t)))

(let ([t (make-term 3 5)])
  (feed t "1\r\n2\r\n3\r\n4")
  (check "scroll" '("2" "3" "4") (screen t))
  (check "history" "1" (row-text t -1)))

(let ([t (make-term 4 10)])
  (feed t (esc "[2;3HX"))
  (check "CUP" '("" "  X" "" "") (screen t))
  (feed t (esc "[A") (esc "[2DY"))
  (check "CUU/CUB" '(" Y" "  X" "" "") (screen t)))

(let ([t (make-term 3 10)])
  (feed t "abcdefghij")
  (feed t (esc "[1;4H") (esc "[K"))
  (check "EL 0" '("abc" "" "") (screen t))
  (feed t "XYZ" (esc "[1;2H") (esc "[1K"))
  (check "EL 1" '("  cXYZ" "" "") (screen t)))

(let ([t (make-term 3 10)])
  (feed t "abcdef" (esc "[1;2H") (esc "[2P"))
  (check "DCH" '("adef" "" "") (screen t))
  (feed t (esc "[3@"))
  (check "ICH" '("a   def" "" "") (screen t))
  (feed t (esc "[2X"))
  (check "ECH" '("a   def" "" "") (screen t)))

(let ([t (make-term 4 10)])
  (feed t "1\r\n2\r\n3\r\n4" (esc "[2;3r") (esc "[2;1H") (esc "[L"))
  (check "IL in region" '("1" "" "2" "4") (screen t))
  (feed t (esc "[M"))
  (check "DL in region" '("1" "2" "" "4") (screen t)))

(let ([t (make-term 4 10)])
  (feed t "1\r\n2\r\n3\r\n4" (esc "[2;3r") (esc "[3;1H") "\n")
  (check "LF scrolls region" '("1" "3" "" "4") (screen t))
  (check "region scroll keeps history empty" 0 (grid-hist-count (terminal-grid t))))

(let ([t (make-term 3 10)])
  (feed t "a" (esc "M"))
  (check "RI at top scrolls down" '("" "a" "") (screen t)))

(let ([t (make-term 3 10)])
  (feed t "\t1\tX")
  (check "tabs" '("        1X") (list (row-text t 0)))
  (check "tab stop clamps at edge" '(0 9) (cursor t)))

(let ([t (make-term 3 20)])
  (feed t (esc "[1;31mR") (esc "[38;5;100mI") (esc "[38;2;1;2;3mT") (esc "[48:2::4:5:6mC") (esc "[0m"))
  (let ([v (line-cells (grid-line (terminal-grid t) 0))])
    (check "sgr red" 1 (cell-fg v 0))
    (check "sgr bold" ATTR-BOLD (fxand ATTR-BOLD (cell-attrs v 0)))
    (check "sgr 256" 100 (cell-fg v 1))
    (check "sgr rgb" (fxior COLOR-RGB #x010203) (cell-fg v 2))
    (check "sgr rgb colon" (fxior COLOR-RGB #x040506) (cell-bg v 3))))

(let ([t (make-term 3 20)])
  (feed t (esc "[4:3mA") (esc "[24mB"))
  (let ([v (line-cells (grid-line (terminal-grid t) 0))])
    (check "curly underline" UL-CURLY (fxsrl (fxand ATTR-UNDERLINE-MASK (cell-attrs v 0)) ATTR-UNDERLINE-SHIFT))
    (check "underline off" 0 (fxand ATTR-UNDERLINE-MASK (cell-attrs v 1)))))

(let ([t (make-term 3 10)])
  (feed t "日本x")
  (check "wide chars" '("日本x" "" "") (screen t))
  (check "wide cursor" '(0 5) (cursor t))
  (feed t (esc "[1;2Hy"))
  (check "overwrite half wide" '(" y本x" "" "") (screen t)))

(let ([t (make-term 3 5)])
  (feed t "abcd日")
  (check "wide wraps at edge" '("abcd" "日" "") (screen t)))

(let ([t (make-term 3 10)])
  (feed t "e\x301;x")
  (check "combining char doesn't advance" '(0 2) (cursor t))
  (check "combining stored" "\x301;"
         (hashtable-ref (line-extra (grid-line (terminal-grid t) 0)) 0 #f)))

;; erasing with a colored background, then partly and wholly with the
;; default one: cells are stored differently for default colors
(let ([t (make-term 3 6)])
  (define (colors row)
    (let ([v (line-cells (grid-line (terminal-grid t) row))])
      (map (lambda (i) (list (cell-fg v i) (cell-bg v i))) (iota 6))))
  (feed t (esc "[31;44m") (esc "[2K") "ab")
  (check "BCE erase" (append '((1 4) (1 4)) (make-list 4 (list COLOR-FG 4))) (colors 0))
  (feed t (esc "[0m") (esc "[1;4H") (esc "[K"))
  (check "partial default erase"
         (append '((1 4) (1 4)) (list (list COLOR-FG 4)) (make-list 3 (list COLOR-FG COLOR-BG)))
         (colors 0))
  (feed t (esc "[2J"))
  (check "whole default erase" (make-list 6 (list COLOR-FG COLOR-BG)) (colors 0))
  (check "erased cells are empty" "" (row-text t 0))
  (feed t (esc "[42m") (esc "[3;1H") "\n")
  (check "scrolled-in line takes the background" (make-list 6 (list COLOR-FG 2)) (colors 2)))

;; combining marks go away with their cells, whether there are fewer marks
;; than cleared cells or more
(define (mark-cols t row)
  (let ([ex (line-extra (grid-line (terminal-grid t) row))])
    (if ex (list-sort < (vector->list (hashtable-keys ex))) '())))

(let ([t (make-term 3 10)])
  (feed t "a\x301;bc\x301;de\x301;fg\x301;h")
  (check "marks stored" '(0 2 4 6) (mark-cols t 0))
  (feed t (esc "[1;3H") "\x3b1;")
  (check "overwrite drops a mark" '(0 4 6) (mark-cols t 0))
  (feed t (esc "[1;4H") (esc "[3X"))
  (check "erase drops marks" '(0 6) (mark-cols t 0))
  (feed t (esc "[1;1H") "YZ")
  (check "ASCII run drops a mark" '(6) (mark-cols t 0))
  (feed t (esc "[1;7H") (esc "[K"))
  (check "last mark dropped" '() (mark-cols t 0))
  (check "text after mark changes" "YZα" (row-text t 0)))

(let ([t (make-term 3 10)])
  (feed t "main" (esc "[?1049h") "alt")
  (check "alt screen (cursor kept)" '("    alt" "" "") (screen t))
  (feed t (esc "[?1049l"))
  (check "back to primary" '("main" "" "") (screen t))
  (check "cursor restored" '(0 4) (cursor t)))

(let ([t (make-term 5 10)])
  (feed t (esc "[3;4H") (esc "[6n"))
  (check "CPR" '("\x1b;[3;4R") responses))

(let ([t (make-term 5 10)])
  (feed t (esc "[c"))
  (check "DA1" '("\x1b;[?62;22c") responses))

(let ([t (make-term 5 10)])
  (feed t (esc "[?2004h"))
  (check "bracketed paste" #t (terminal-bracketed-paste? t))
  (feed t (esc "[?1000;1006h"))
  (check "mouse mode" 'click (terminal-mouse-mode t))
  (check "sgr mouse" #t (terminal-mouse-sgr? t))
  (feed t (esc "[?2004$p"))
  (check "DECRQM" "\x1b;[?2004;1$y" (car responses)))

(let ([t (make-term 5 10)] [title #f])
  (terminal-set-callbacks! t (lambda (s) (void)) (lambda (s) (set! title s)) void void)
  (feed t (esc "]0;hello world\a"))
  (check "OSC title BEL" "hello world" title)
  (feed t (esc "]2;second" "\x1b;\\"))
  (check "OSC title ST" "second" title))

(let ([t (make-term 5 10)] [clip #f])
  (terminal-set-callbacks! t (lambda (s) (void)) void void (lambda (s) (set! clip s)))
  (feed t (esc "]52;c;aGVsbG8gd29ybGQ=\a"))
  (check "OSC 52" "hello world" clip))

(let ([t (make-term 5 10)])
  (feed t (esc "]11;rgb:12/34/56\a"))
  (check "OSC 11 set" #x123456 (vector-ref (terminal-palette t) COLOR-BG))
  (feed t (esc "]11;?\a"))
  (check "OSC 11 query" "\x1b;]11;rgb:1212/3434/5656\a" (car responses)))

(let ([t (make-term 3 10)])
  (feed t (esc "(0") "qx" (esc "(B") "q")
  (check "DEC graphics" '("─│q" "" "") (screen t)))

(let ([t (make-term 3 10)])
  (feed t "x" (esc "[5b"))
  (check "REP" '("xxxxxx" "" "") (screen t)))

(let ([t (make-term 3 10)])
  (feed t "abc" (esc "7") (esc "[3;5H") (esc "8") "Z")
  (check "DECSC/DECRC" '("abcZ" "" "") (screen t)))

(let ([t (make-term 3 10)])
  (feed t (esc "#8"))
  (check "DECALN" '("EEEEEEEEEE" "EEEEEEEEEE" "EEEEEEEEEE") (screen t)))

(let ([t (make-term 3 10)])
  (feed t (esc "[?7l") "abcdefghijklm")
  (check "no autowrap" '("abcdefghim" "" "") (screen t)))

(let ([t (make-term 3 10)])
  (feed t (esc "[4h") "abc" (esc "[1;1H") "X")
  (check "insert mode" '("Xabc" "" "") (screen t)))

(let ([t (make-term 3 10)])
  (feed-bytes t #vu8(#xff 111 107))
  (check "invalid utf8" '("\xfffd;ok" "" "") (screen t)))

(let ([t (make-term 3 10)])
  ;; sequence split across feeds
  (feed t "\x1b;[3")
  (feed-bytes t #vu8(49 109 65 #xe2 #x82))
  (feed-bytes t #vu8(#xac))
  (check "split input" '("A€" "" "") (screen t))
  (check "split sgr" 1 (cell-fg (line-cells (grid-line (terminal-grid t) 0)) 0)))

;;; reflow
(let ([t (make-term 3 10)])
  (feed t "0123456789abcdef\r\nxy")
  (terminal-resize! t 3 5)
  (check "reflow narrower" '("abcde" "f" "xy") (screen t))
  (check "reflow history" '("01234" "56789") (list (row-text t -2) (row-text t -1)))
  (terminal-resize! t 3 20)
  (check "reflow wider" '("0123456789abcdef" "xy" "") (screen t))
  (check "reflow cursor" '(1 2) (cursor t)))

(let ([t (make-term 4 10)])
  (feed t "a\r\nb")
  (terminal-resize! t 2 10)
  (check "shrink rows keeps cursor line" '("a" "b") (screen t))
  (terminal-resize! t 6 10)
  (check "grow rows" '("a" "b" "" "" "" "") (screen t)))

(let ([t (make-term 3 10)])
  (feed t "1\r\n2\r\n3\r\n4\r\n5")
  (terminal-resize! t 5 10)
  (check "grow pulls history" '("1" "2" "3" "4" "5") (screen t))
  (check "grow cursor" '(4 1) (cursor t)))

(let ([t (make-term 3 4)])
  (feed t "ab日本")
  (terminal-resize! t 3 3)
  (check "reflow wide" '("ab" "日" "本") (screen t)))

;;; scrollback view anchoring
(let ([t (make-term 2 5)])
  (feed t "1\r\n2\r\n3\r\n4")
  (terminal-scroll-display! t 1)
  (check "display offset" 1 (terminal-display-offset t))
  (feed t "\r\n5")
  (check "display anchored" 2 (terminal-display-offset t)))

(let ([t (make-term 3 10)])
  (feed t (esc "[2 q"))
  (check "DECSCUSR" 'block (terminal-cursor-style t))
  (feed t (esc "[5 q"))
  (check "DECSCUSR beam" 'beam (terminal-cursor-style t))
  (check "DECSCUSR blink" #t (terminal-cursor-blink? t)))

(let ([t (make-term 3 10)])
  (feed t "abc" (esc "c"))
  (check "RIS" '("" "" "") (screen t)))

(let ([t (make-term 3 10)])
  (feed t (esc "[18t"))
  (check "report size" "\x1b;[8;3;10t" (car responses)))

;;; regressions from code review
(let ([t (make-term 24 80)])
  ;; resize in the alt screen with a saved cursor below the new size
  (feed t (esc "[24;1H") (esc "7"))
  (terminal-resize! t 10 80)
  (feed t (esc "[?1047h"))
  (check "alt resize with stale saved cursor" #t
         (begin (terminal-resize! t 10 60) (= 10 (terminal-rows t)))))

(let ([t (make-term 3 4)])
  (feed t "漢")
  (terminal-resize! t 3 1)
  (check "resize to one column with wide char terminates" 1 (terminal-cols t)))

(let ([t (make-term 6 20)])
  (feed t "1\r\n2\r\n3\r\n4\r\n5\r\n6" (esc "[?1047h"))
  (terminal-resize! t 3 10)
  (feed t (esc "[?1047l"))
  (check "alt resize keeps primary content" '("4" "5" "6") (screen t))
  (check "alt resize history" "3" (row-text t -1)))

(let ([t (make-term 4 20)])
  (feed t "top\r\n" (esc "[15C") "\r\nbelow" (esc "[2;16H"))
  (terminal-resize! t 4 10)
  (feed t "X")
  (check "reflow cursor beyond content" "below" (row-text t (+ 1 (terminal-cursor-row t))))
  (check "reflow cursor row has X" "     X" (row-text t (terminal-cursor-row t))))

(let ([t (make-term 10 20)])
  (feed t (esc "[5;10r") (esc "[?6h") (esc "[2d"))
  (check "VPA in origin mode" 5 (terminal-cursor-row t)))

(let ([t (make-term 5 10)])
  (feed t (esc "[?1049h") "a\r\nb\r\nc\r\nd\r\ne")
  (terminal-set-selection! t (vector 'stream (terminal-abs-row t 2) 0 (terminal-abs-row t 2) 0))
  (feed t "\r\nf")
  (check "alt screen scroll clears selection" #f (terminal-selection t)))

(let ([t (make-term 3 20)])
  (feed t "cafe\x301; xyz" (esc "[1;10H") (esc "[@"))
  (check "ICH keeps combining marks" "\x301;"
         (hashtable-ref (line-extra (grid-line (terminal-grid t) 0)) 3 #f))
  (feed t (esc "[1;1H") (esc "[P"))
  (check "DCH shifts combining marks" "\x301;"
         (hashtable-ref (line-extra (grid-line (terminal-grid t) 0)) 2 #f)))

(let ([t (make-term 3 5)])
  (feed t "abcde\bX")
  (check "BS with pending wrap" '("abcXe" "" "") (screen t)))

(let ([t (make-term 3 10)])
  (for-each (lambda (s) (feed t s))
            (list (esc "]4;1.5;?\a") (esc "]11;rgb:ffffffffffffffffffff/0/0\a")
                  (esc "]7;file://h/a%-1b\a") (esc "]11;rgb:-1/0/0\a") (esc "]104;abc\a")))
  (check "malformed OSC ignored" #xffffff (vector-ref (terminal-palette t) COLOR-FG))
  (check "negative color rejected" 0 (vector-ref (terminal-palette t) COLOR-BG))
  (feed t "ok")
  (check "terminal alive after bad OSC" '("ok" "" "") (screen t)))

;;; selection text
(let* ([t (make-term 4 10)]
       [sel (lambda (mode a ac b bc)
              (terminal-set-selection! t (vector mode (terminal-abs-row t a) ac (terminal-abs-row t b) bc))
              (selection-text t))])
  (feed t "hello world\r\nfoo  \r\n日本 bar")
  (check "selection single line" "llo" (sel 'stream 0 2 0 4))
  (check "selection across wrap has no newline" "world" (sel 'stream 0 6 1 0))
  (check "selection multi line trims" "d\nfoo\n日本" (sel 'stream 1 0 3 3))
  (check "selection backwards" "llo" (sel 'stream 0 4 0 2))
  (check "block selection" "ll\n\no\n本" (sel 'block 0 2 3 3))
  (check "word bounds" '(6 . 9) (word-bounds t " " (terminal-abs-row t 0) 7))
  (check "logical line" (cons (terminal-abs-row t 0) (terminal-abs-row t 1))
         (logical-line-bounds t (terminal-abs-row t 1)))
  (check "search matches" '((1 2) (2 3)) (line-matches t "o" (terminal-abs-row t 2)))
  (check "search wide" '((0 4)) (line-matches t "日本" (terminal-abs-row t 3))))

(let ([t (make-term 2 40)])
  (feed t "see https://example.com/a?b=1, ok")
  (check "url at" "https://example.com/a?b=1" (url-at t (cons (terminal-abs-row t 0) 10)))
  (check "no url" #f (url-at t (cons (terminal-abs-row t 0) 1))))

;;; key encoding
(let ()
  (define (key name text mods . modes)
    (let ([m (if (null? modes) '(#f #f #f) modes)])
      (apply encode-key (make-key-event (keysym-by-name name) text mods) m)))
  (check "key up" "\x1b;[A" (key "Up" "" 0))
  (check "key up app" "\x1b;OA" (key "Up" "" 0 #t #f #f))
  (check "key ctrl+up" "\x1b;[1;5A" (key "Up" "" MOD-CTRL))
  (check "key F1" "\x1b;OP" (key "F1" "" 0))
  (check "key shift+F5" "\x1b;[15;2~" (key "F5" "" MOD-SHIFT))
  (check "key del" "\x1b;[3~" (key "Delete" "" 0))
  (check "key backspace" "\x7f;" (key "BackSpace" "" 0))
  (check "key ctrl+c" "\x3;" (key "c" "c" MOD-CTRL))
  (check "key ctrl+space" "\x0;" (key "space" " " MOD-CTRL))
  (check "key alt+x" "\x1b;x" (key "x" "x" MOD-ALT))
  (check "key shift+tab" "\x1b;[Z" (key "Tab" "" MOD-SHIFT))
  (check "key enter" "\r" (key "Return" "\r" 0))
  (check "key text" "é" (key "eacute" "é" 0))
  (check "keypad app" "\x1b;Oq" (key "KP_1" "1" 0 #f #t #f))
  (check "binding parse" (cons (fxior MOD-CTRL MOD-SHIFT) (keysym-by-name "c"))
         (parse-key-binding "ctrl+shift+c")))

;;; TERM selection
(let* ([env (lambda (alist) (lambda (k) (let ([e (assoc k alist)]) (and e (cdr e)))))]
       [files (lambda (paths) (lambda (p) (and (member p paths) #t)))])
  (check "term: configured value wins" '(("TERM" . "xterm"))
         (term-environment "xterm" "/b" (env '()) (files '("/usr/share/terminfo/c/chezterm"))))
  (check "term: system entry" '(("TERM" . "chezterm"))
         (term-environment #f "/b" (env '()) (files '("/usr/share/terminfo/c/chezterm"))))
  (check "term: hashed directory layout" '(("TERM" . "chezterm"))
         (term-environment #f #f (env '(("HOME" . "/h"))) (files '("/h/.terminfo/63/chezterm"))))
  (check "term: bundled entry extends TERMINFO_DIRS" '(("TERM" . "chezterm") ("TERMINFO_DIRS" . "/b:"))
         (term-environment #f "/b" (env '()) (files '("/b/c/chezterm"))))
  (check "term: bundled entry keeps the user's TERMINFO_DIRS"
         '(("TERM" . "chezterm") ("TERMINFO_DIRS" . "/b:/x:"))
         (term-environment #f "/b" (env '(("TERMINFO_DIRS" . "/x:"))) (files '("/b/c/chezterm"))))
  (check "term: TERMINFO_DIRS entry found" '(("TERM" . "chezterm"))
         (term-environment #f "/b" (env '(("TERMINFO_DIRS" . "/x"))) (files '("/x/c/chezterm" "/b/c/chezterm"))))
  (check "term: fallback" '(("TERM" . "xterm-256color"))
         (term-environment #f "/b" (env '()) (files '()))))

;;; renderer: incremental rendering (including the scroll optimisation)
;;; must produce the same pixels as a full redraw
(let ()
  (define f (make-font "monospace" 10.0 96.0 1 #f #f))
  (define (snapshot r)
    (let* ([n (* (renderer-width r) (renderer-height r))] [bv (make-bytevector (* 4 n))])
      (do ([i 0 (+ i 1)]) ((= i n) bv)
        (bytevector-u32-native-set! bv (* 4 i) (foreign-ref 'unsigned-32 (renderer-pixels r) (* 4 i))))))
  (define (fresh-render t . opts)
    (let* ([f (if (pair? opts) (car opts) f)]
           [opacity (if (and (pair? opts) (pair? (cdr opts))) (cadr opts) 1.0)]
           [r (make-renderer f 3 3 opacity #f #f #x444444 #t)])
      (renderer-resize! r (+ 6 (* 20 (font-cell-width f))) (+ 6 (* 6 (font-cell-height f))))
      (renderer-render! r t #t #t (lambda (a) '()) #f)
      (let ([s (snapshot r)]) (renderer-free! r) s)))
  (let ([t (make-term 6 20)]
        [r (make-renderer f 3 3 1.0 #f #f #x444444 #t)])
    (renderer-resize! r (+ 6 (* 20 (font-cell-width f))) (+ 6 (* 6 (font-cell-height f))))
    (feed t "line 1\r\nline 2 \x1b;[31mred\x1b;[0m\r\n\x1b;[44mblue bg\x1b;[0m\r\nline 4")
    (renderer-render! r t #t #t (lambda (a) '()) #f)
    (check "render initial = fresh" #t (equal? (snapshot r) (fresh-render t)))
    (feed t "\r\nline 5\r\nline 6\r\nline 7 ┌─┐")
    (let ([damage (renderer-render! r t #t #t (lambda (a) '()) #f)])
      (check "render after scroll = fresh" #t (equal? (snapshot r) (fresh-render t)))
      (check "scroll damage is partial" #t (< (length damage) 6))
      (check "scroll damage covers moved rows" #t
             (exists (lambda (d) (and (<= (car d) 3) (>= (cdr d) (+ 3 (* 3 (font-cell-height f)))))) damage)))
    (terminal-scroll-display! t 2)
    (renderer-render! r t #t #t (lambda (a) '()) #f)
    (check "render scrolled back = fresh" #t (equal? (snapshot r) (fresh-render t)))
    (terminal-set-selection! t (vector 'stream (terminal-abs-row t 0) 2 (terminal-abs-row t 1) 3))
    (renderer-render! r t #t #t (lambda (a) '()) #f)
    (check "render selection = fresh" #t (equal? (snapshot r) (fresh-render t)))
    (check "no damage when unchanged" '() (renderer-render! r t #t #t (lambda (a) '()) #f))
    ;; glyphs actually reach the image, through tiles and the overhang path
    (let* ([t2 (make-term 2 20)]
           [r2 (make-renderer f 0 0 1.0 #f #f #x444444 #t)]
           [cw (font-cell-width f)] [chh (font-cell-height f)]
           [ink? (lambda (col)
                   (let loop ([y 0] [x (* col cw)])
                     (cond [(= y chh) #f]
                           [(= x (* (+ col 1) cw)) (loop (+ y 1) (* col cw))]
                           [(not (= (foreign-ref 'unsigned-32 (renderer-pixels r2)
                                                 (* 4 (+ x (* y (renderer-width r2)))))
                                    #xff000000))
                            #t]
                           [else (loop y (+ x 1))])))])
      (renderer-resize! r2 (* 20 cw) (* 2 chh))
      (feed t2 "A \x1b;[3mf\x1b;[0m 日─")
      (renderer-render! r2 t2 #f #t (lambda (a) '()) #f)
      (check "glyph drawn" #t (ink? 0))
      (check "space left blank" #f (ink? 1))
      (check "italic drawn" #t (ink? 2))
      (check "wide glyph drawn" #t (ink? 4))
      (check "box drawing drawn" #t (ink? 6)))
    (feed t (esc "[?5h"))
    (check "DECSCNM redraws" #t (pair? (renderer-render! r t #t #t (lambda (a) '()) #f)))
    (check "DECSCNM = fresh" #t (equal? (snapshot r) (fresh-render t))))
  ;; a full redraw sets every pixel, also in a window that is not a whole
  ;; number of cells and has more rows and columns than the terminal
  (let ([t (make-term 4 15)])
    (feed t (esc "[44m") "blue" (esc "[0m") " text\r\n" (esc "[7m") "rev")
    (let ([over (lambda (garbage)
                  (let ([r (make-renderer f 3 3 1.0 #f #f #x444444 #t)])
                    (renderer-resize! r (+ 11 (* 20 (font-cell-width f))) (+ 13 (* 6 (font-cell-height f))))
                    (do ([i 0 (+ i 1)]) ((= i (* (renderer-width r) (renderer-height r))))
                      (foreign-set! 'unsigned-32 (renderer-pixels r) (* 4 i) garbage))
                    (renderer-render! r t #t #t (lambda (a) '()) #f)
                    (let ([s (snapshot r)]) (renderer-free! r) s)))])
      (check "full redraw sets every pixel" #t (equal? (over #xABABABAB) (over #x5C5C5C5C)))))
  ;; the tile cache: more glyph/color combinations than it holds (8192), so
  ;; entries are evicted, and earlier screens drawn again after that
  (let* ([t (make-term 6 20)]
         [r (make-renderer f 3 3 1.0 #f #f #x444444 #t)]
         [screen (lambda (n)
                   (apply string-append
                          (esc "[H")
                          (map (lambda (i)
                                 (let ([c (+ i (* 120 n))])
                                   (format "~a~c"
                                           (esc (format "[38;2;~a;~a;~am\x1b;[48;2;~a;~a;~am"
                                                        (mod c 256) (mod (* 7 n) 256) 200
                                                        (mod (* 3 c) 256) 40 (mod n 256)))
                                           (integer->char (+ 33 (mod (+ i n) 94))))))
                               (iota 119))))]
         [ok #t])
    (renderer-resize! r (+ 6 (* 20 (font-cell-width f))) (+ 6 (* 6 (font-cell-height f))))
    (do ([n 0 (+ n 1)]) ((= n 80))
      (feed t (screen n))
      (renderer-render! r t #t #t (lambda (a) '()) #f)
      (when (and ok (= 0 (mod n 8)))
        (set! ok (equal? (snapshot r) (fresh-render t)))))
    (check "tile cache: many colors = fresh" #t ok)
    (check "tile cache: bounded" #t (<= 8000 (renderer-tile-count r) 8192))
    (do ([n 0 (+ n 1)]) ((= n 3))
      (feed t (screen n))
      (renderer-render! r t #t #t (lambda (a) '()) #f)
      (when ok (set! ok (equal? (snapshot r) (fresh-render t)))))
    (check "tile cache: evicted entries redrawn = fresh" #t ok)
    ;; a font change clears the tiles: none of the old size may be used
    (let ([f2 (make-font "monospace" 14.0 96.0 1 #f #f)])
      (renderer-set-font! r f2)
      (check "font change clears the tiles" 0 (renderer-tile-count r))
      (renderer-resize! r (+ 6 (* 20 (font-cell-width f2))) (+ 6 (* 6 (font-cell-height f2))))
      (feed t (esc "[0m") "\r\n\x1b;[3mitalic\x1b;[0m 日本 ─┼─ \x1b;[1mbold")
      (renderer-render! r t #t #t (lambda (a) '()) #f)
      (check "render after font change = fresh" #t (equal? (snapshot r) (fresh-render t f2)))
      (renderer-set-font! r f)
      (renderer-resize! r (+ 6 (* 20 (font-cell-width f))) (+ 6 (* 6 (font-cell-height f))))
      (renderer-render! r t #t #t (lambda (a) '()) #f)
      (check "render after font change back = fresh" #t (equal? (snapshot r) (fresh-render t))))
    (renderer-free! r)
    (check "renderer-free! frees the tiles" 0 (renderer-tile-count r)))
  ;; opacity < 1: default backgrounds (behind glyphs too) are premultiplied
  (let* ([t (make-term 6 20)]
         [r (make-renderer f 3 3 0.8 #f #f #x444444 #t)]
         [pixel (lambda (x y) (foreign-ref 'unsigned-32 (renderer-pixels r) (* 4 (+ x (* y (renderer-width r))))))]
         [cw (font-cell-width f)])
    (renderer-resize! r (+ 6 (* 20 cw)) (+ 6 (* 6 (font-cell-height f))))
    (feed t "_A\x1b;[44m_B\x1b;[0m\r\nline 2")
    (renderer-render! r t #t #t (lambda (a) '()) #f)
    (check "opacity = fresh" #t (equal? (snapshot r) (fresh-render t f 0.8)))
    (feed t "\r\n\x1b;[31mred \x1b;[7mreverse")
    (renderer-render! r t #t #t (lambda (a) '()) #f)
    (check "opacity incremental = fresh" #t (equal? (snapshot r) (fresh-render t f 0.8)))
    (let ([p (pixel 3 3)])                 ; top left of the "_" cell
      (check "opacity: default background alpha" 204 (bitwise-arithmetic-shift-right p 24))
      (check "opacity: premultiplied" #t
             (for-all (lambda (s) (<= (bitwise-and #xFF (bitwise-arithmetic-shift-right p s)) 204))
                      '(0 8 16))))
    (check "opacity: colored background opaque" 255
           (bitwise-arithmetic-shift-right (pixel (+ 3 (* 2 cw)) 3) 24))
    (renderer-free! r)))

(printf "~a passed, ~a failed\n" passes failures)
(exit (if (= failures 0) 0 1))
