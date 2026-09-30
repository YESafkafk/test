;;; Test runner: scheme --libdirs src --script tests/run.ss
(import (chezscheme) (chezterm grid) (chezterm terminal) (chezterm charwidth)
        (chezterm font) (chezterm render) (chezterm selection) (chezterm keyboard)
        (chezterm termenv) (only (chezterm config) config-ref)
        (only (chezterm ffi) xkb_keysym_from_name xkb_keysym_to_utf32))

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

;; UTF-8: decoding whole sequences at once gives the same screen as
;; feeding one byte at a time, including malformed input
(for-each
 (lambda (bytes)
   (let ([a (make-term 3 12)] [b (make-term 3 12)] [bv (u8-list->bytevector bytes)])
     (feed-bytes a bv)
     (for-each (lambda (x) (feed-bytes b (u8-list->bytevector (list x)))) bytes)
     (check (format "utf-8 ~s" bytes) (list (screen b) (cursor b)) (list (screen a) (cursor a)))))
 '((#xC3 #xA9 #x41)                        ; é A
   (#xE6 #x97 #xA5 #xE6 #x9C #xAC)         ; 日本
   (#xF0 #x9F #x98 #x80 #x78)              ; emoji x
   (#x65 #xCC #x81 #x78)                   ; e + combining acute
   (#xC0 #x9B #x5B #x32 #x43 #x78)         ; overlong ESC: CSI 2 C
   (#xC2 #x9B #x41)                        ; C1 CSI as a character
   (#xED #xA0 #x80 #x41)                   ; surrogate
   (#xF4 #x90 #x80 #x80 #x41)              ; above U+10FFFF
   (#xE6 #x97 #x41 #x42)                   ; cut short by ASCII
   (#xC3 #xC3 #xA9)                        ; lead byte instead of continuation
   (#x80 #xBF #xF8 #xFF #x41)))            ; stray continuations, invalid leads

;; CSI sequences: whole sequences in one buffer give the same screen,
;; modes and replies as one byte at a time
(for-each
 (lambda (str)
   (let* ([bytes (bytevector->u8-list (string->utf8 str))]
          [run (lambda (whole?)
                 (let ([t (make-term 4 12)])
                   (feed t "abcdefghijkl\r\nmnopqrstuvwx\r\n")
                   (if whole?
                       (feed-bytes t (u8-list->bytevector bytes))
                       (for-each (lambda (x) (feed-bytes t (u8-list->bytevector (list x)))) bytes))
                   (feed t "Z")
                   (list (screen t) (cursor t) responses (terminal-alt-screen? t)
                         (terminal-app-cursor? t) (terminal-cursor-visible? t) (terminal-cursor-style t)
                         (let ([v (line-cells (grid-line (terminal-grid t) (terminal-cursor-row t)))])
                           (list (cell-attrs v (terminal-cursor-col t)) (cell-fg v 0) (cell-bg v 0))))))])
     (check (format "csi ~s" str) (run #f) (run #t))))
 (list (esc "[2;5H") (esc "[5G") (esc "[1;31;48:2::1:2:3m") (esc "[38;5;100;4:3m")
       (esc "[?1049h") (esc "[?25l") (esc "[?1h") (esc "[>c") (esc "[6n") (esc "[?6n")
       (esc "[2 q") (esc "[!p") (esc "[?1$p")               ; intermediates
       (esc "[2\b;5H") (esc "[1\x18;31m") (esc "[1\x1b;[31m") ; controls inside
       (esc "[?1;?2h") (esc "[1<m") (esc "[;5H") (esc "[:3m")  ; misplaced markers, empty
       (esc "[99999999999;1H") (esc "[" (apply string-append (map (lambda (i) "1;") (iota 40))) "7m")
       (esc "[2;3") (esc "[")))                               ; cut off

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

;;; OSC 8 hyperlinks: parsing and storage
(define (osc8 params uri) (esc "]8;" params ";" uri "\x1b;\\"))
(define (link-id t row col) (line-link (grid-line (terminal-grid t) row) col))
(define (link-at t row col) (terminal-link-uri t (link-id t row col)))
(define (links t row) (map (lambda (c) (link-at t row c)) (iota (terminal-cols t))))

(let ([t (make-term 3 10)])
  (feed t (osc8 "" "http://a.example/") "link" (osc8 "" "") " x")
  (check "osc8: linked cells" (append (make-list 4 "http://a.example/") (make-list 6 #f)) (links t 0))
  (check "osc8: text" "link x" (row-text t 0))
  (feed t "\r\n" (esc "]8;;https://b.example/?q=1;x=2\a") "b" (esc "]8;;\a") "c")
  (check "osc8: BEL-terminated, URI with ;" '("https://b.example/?q=1;x=2" #f) (list (link-at t 1 0) (link-at t 1 1))))

;; blank cells stay all zeros, and a linked cell is stored like any other
(let ([a (make-term 2 10)] [b (make-term 2 10)])
  (feed a (osc8 "" "http://x/") "ab" (esc "[31m") "c" (osc8 "" ""))
  (feed b "ab" (esc "[31m") "c")
  (check "osc8: cells unchanged by links" #t
         (equal? (line-cells (grid-line (terminal-grid a) 0)) (line-cells (grid-line (terminal-grid b) 0))))
  (check "osc8: the rest of the line is all zeros" #t
         (let ([v (line-cells (grid-line (terminal-grid a) 0))])
           (for-all (lambda (i) (= 0 (fxvector-ref v (+ 9 i)))) (iota (* 3 7)))))
  (check "osc8: no extras without links" #f (line-extra (grid-line (terminal-grid b) 0))))

;; ids: runs with the same id and URI are one link; without an id every
;; OSC 8 starts a link of its own
(let ([t (make-term 3 20)])
  (feed t (osc8 "id=x" "http://a/") "ab" (osc8 "" "") "--" (osc8 "id=x" "http://a/") "cd" (osc8 "" ""))
  (check "osc8: same id, same link" #t (= (link-id t 0 0) (link-id t 0 4)))
  (check "osc8: gap between the runs" 0 (link-id t 0 2))
  (feed t "\r\n" (osc8 "" "http://a/") "ab" (osc8 "" "") (osc8 "" "http://a/") "cd" (osc8 "" ""))
  (check "osc8: no id, separate links" #f (= (link-id t 1 0) (link-id t 1 2)))
  (check "osc8: no id, not the id=x link" #f (= (link-id t 1 0) (link-id t 0 0)))
  (feed t "\r\n" (osc8 "id=x" "http://other/") "ab" (osc8 "id=y" "http://a/") "cd"
        (osc8 "foo=bar:id=x" "http://a/") "ef" (osc8 "" ""))
  (check "osc8: same id, other URI" #f (= (link-id t 2 0) (link-id t 0 0)))
  (check "osc8: other id, same URI" #f (= (link-id t 2 2) (link-id t 0 0)))
  (check "osc8: id among other parameters" #t (= (link-id t 2 4) (link-id t 0 0)))
  (check "osc8: a new link replaces the open one" "http://a/" (link-at t 2 2))
  (check "osc8: links in use" 5 (terminal-link-count t)))

;; invalid links are ignored, and end the open link
(let ([t (make-term 3 20)])
  (define long (string-append "http://x/" (make-string (- 2083 9) #\a)))
  (feed t (osc8 "" long) "a" (osc8 "" (string-append long "b")) "b" (osc8 "" ""))
  (check "osc8: 2083 bytes" long (link-at t 0 0))
  (check "osc8: longer URIs are ignored" #f (link-at t 0 1))
  (feed t (osc8 "" "http://a/") "c" (osc8 "" "http://ä/") "d"
        (osc8 "" "http://a/") "e" (esc "]8;http://a/\x1b;\\") "f"
        (osc8 "" "http://a/") "g" (osc8 (string-append "id=" (make-string 257 #\i)) "http://a/") "h"
        (osc8 "" "http://a/b\tc") "i" (osc8 "" ""))
  (check "osc8: invalid ones end the link" '("http://a/" #f "http://a/" #f "http://a/" #f #f)
         (map (lambda (c) (link-at t 0 (+ c 2))) (iota 7))))

;; a link wraps with its text, scrolls into the history, and survives reflow
(let ([t (make-term 3 10 100)])
  (feed t "ab" (osc8 "" "http://wrap.example/") "0123456789XYZ" (osc8 "" "") " end")
  (check "osc8: wrapped" '("ab01234567" "89XYZ end" "") (screen t))
  (check "osc8: one link across the wrap" #t
         (and (= (link-id t 0 2) (link-id t 0 9)) (= (link-id t 0 9) (link-id t 1 4))))
  (check "osc8: not after it" 0 (link-id t 1 5))
  (feed t "\r\n1\r\n2\r\n3\r\n4")
  (check "osc8: in the history" "http://wrap.example/" (link-at t -3 5))
  (check "osc8: in the history, second row" "http://wrap.example/" (link-at t -2 3))
  (terminal-resize! t 3 7)
  (let ([g (terminal-grid t)])
    ;; ab01234 / 56789XY / Z end
    (check "osc8: reflowed narrower" "ab01234" (row-text t (- (grid-hist-count g))))
    (check "osc8: reflowed cells keep the link"
           '(#f #f #t #t #t #t #t)
           (map (lambda (c) (and (link-at t (- (grid-hist-count g)) c) #t)) (iota 7)))
    (check "osc8: reflowed, last piece" '(#t #f)
           (map (lambda (c) (and (link-at t (- 2 (grid-hist-count g)) c) #t)) '(0 1))))
  (terminal-resize! t 3 30)
  (let ([row (- (grid-hist-count (terminal-grid t)))])
    (check "osc8: reflowed wider" "ab0123456789XYZ end" (row-text t row))
    (check "osc8: reflowed wider, link" (append '(#f #f) (make-list 13 #t) '(#f #f))
           (map (lambda (c) (and (link-at t row c) #t)) (iota 17)))))

;; the alternate screen has its own cells; the primary screen's links stay
(let ([t (make-term 3 10)])
  (feed t (osc8 "" "http://main/") "main" (osc8 "" ""))
  (feed t (esc "[?1049h") (osc8 "" "http://alt/") "alt" (osc8 "" ""))
  (check "osc8: on the alternate screen" "http://alt/" (link-at t 0 4))
  (feed t (esc "[?1049l"))
  (check "osc8: back on the primary screen" "http://main/" (link-at t 0 0)))

;; REP repeats the character with the link; overwriting and erasing drop it
(let ([t (make-term 3 10)])
  (feed t (osc8 "" "http://r/") "x" (esc "[3b") (osc8 "" "") "yz")
  (check "osc8: REP" '(#t #t #t #t #f #f) (map (lambda (c) (and (link-at t 0 c) #t)) (iota 6)))
  (feed t (esc "[1;2H") "o")
  (check "osc8: overwritten" '(#t #f #t #t) (map (lambda (c) (and (link-at t 0 c) #t)) (iota 4)))
  (feed t (esc "[1;3H") (esc "[1X"))
  (check "osc8: ECH" '(#t #f #f #t) (map (lambda (c) (and (link-at t 0 c) #t)) (iota 4)))
  (feed t (esc "[1;1H") (esc "[2@"))
  (check "osc8: ICH moves it" '(#f #f #t #f #f #t) (map (lambda (c) (and (link-at t 0 c) #t)) (iota 6)))
  (feed t (esc "[3P"))
  (check "osc8: DCH moves it" '(#f #f #t #f) (map (lambda (c) (and (link-at t 0 c) #t)) (iota 4)))
  (feed t (esc "[1;3H") (esc "[K"))
  (check "osc8: EL" #f (link-at t 0 2))
  (feed t (esc "[H") (osc8 "" "http://r/") "abc" (osc8 "" "") (esc "[2J"))
  (check "osc8: ED" #f (link-at t 0 0))
  (feed t (esc "[H") (osc8 "" "http://r/") "abc" (osc8 "" "") (esc "#8"))
  (check "osc8: DECALN" #f (link-at t 0 0))
  (check "osc8: nothing left on the screen" '(#f #f #f)
         (map (lambda (r) (line-extra (grid-line (terminal-grid t) r))) '(0 1 2))))

;; combining marks and wide characters
(let ([t (make-term 3 10)])
  (feed t (osc8 "" "http://c/") "e\x301;日x" (osc8 "" ""))
  (check "osc8: combining mark on a linked cell" '("\x301;" "http://c/")
         (list (line-marks (grid-line (terminal-grid t) 0) 0) (link-at t 0 0)))
  (check "osc8: wide character: first half" "http://c/" (link-at t 0 1))
  (check "osc8: wide character: spacer" #f (link-at t 0 2))
  (check "osc8: after the wide character" "http://c/" (link-at t 0 3))
  (check "osc8: selection text keeps the mark" "e\x301;日x"
         (begin (terminal-set-selection! t (vector 'stream (terminal-abs-row t 0) 0 (terminal-abs-row t 0) 3))
                (selection-text t))))

;; DECSTR ends the link, RIS forgets all of them
(let ([t (make-term 3 10)])
  (feed t (osc8 "" "http://s/") "a" (esc "[!p") "b")
  (check "osc8: DECSTR ends the link" '(#t #f) (map (lambda (c) (and (link-at t 0 c) #t)) '(0 1)))
  (feed t (osc8 "" "http://s/") "c" (esc "c") "d")
  (check "osc8: RIS" '(0 #f) (list (terminal-link-count t) (link-at t 0 0))))

;; the number of links is capped (16384): links no cell uses are collected,
;; then those only the history uses; beyond that, new links are dropped
(let ([t (make-term 3 10 0)])
  (do ([i 0 (+ i 1)]) ((= i 16384))
    (feed t (osc8 "" (format "http://~a/" i)) "\rx"))
  (check "osc8: table full" 16384 (terminal-link-count t))
  (feed t (osc8 "" "http://new/") "\ry" (osc8 "" ""))
  ;; (the last of them was still open)
  (check "osc8: unused links collected" '(2 "http://new/") (list (terminal-link-count t) (link-at t 0 0))))
(let ([t (make-term 100 200 0)])
  (do ([i 0 (+ i 1)]) ((= i 16384))
    (feed t (osc8 "" (format "http://~a/" i)) "x"))
  (feed t (osc8 "" "") "\r\n")
  (check "osc8: full of live links" 16384 (terminal-link-count t))
  (feed t (osc8 "" "http://dropped/") "y" (osc8 "" ""))
  (check "osc8: no room: dropped" #f (link-at t (terminal-cursor-row t) 0))
  (check "osc8: live links kept" "http://0/" (link-at t 0 0)))
(let ([t (make-term 10 200 1000)])
  (do ([i 0 (+ i 1)]) ((= i 16384))
    (feed t (osc8 "" (format "http://~a/" i)) "x"))
  (feed t (osc8 "" "") (apply string-append (make-list 20 "\r\n")))
  (check "osc8: links in the history" "http://0/" (link-at t (- (grid-hist-count (terminal-grid t))) 0))
  (feed t (osc8 "" "http://new/") "y" (osc8 "" ""))
  (check "osc8: history links make room" "http://new/" (link-at t (terminal-cursor-row t) 0))
  (check "osc8: history links forgotten" #f (link-at t (- (grid-hist-count (terminal-grid t))) 0)))

;;; underline color (SGR 58/59)
(define (ul-at t row col) (line-ul-color (grid-line (terminal-grid t) row) col))
(define (ul-after t sgr)
  (feed t (esc "[" sgr "m") "x")
  (ul-at t (terminal-cursor-row t) (- (terminal-cursor-col t) 1)))

(let ([t (make-term 3 40)])
  (check "ul color: none" #f (ul-after t "4"))
  (check "ul color: 58:2::r:g:b" (logior COLOR-RGB #x0A141E) (ul-after t "58:2::10:20:30"))
  (check "ul color: 58:2:r:g:b" (logior COLOR-RGB #x0B151F) (ul-after t "58:2:11:21:31"))
  (check "ul color: 58;2;r;g;b" (logior COLOR-RGB #x0C1620) (ul-after t "58;2;12;22;32"))
  (check "ul color: 58:5:n" 196 (ul-after t "58:5:196"))
  (check "ul color: 58;5;n" 3 (ul-after t "58;5;3"))
  (check "ul color: white" (logior COLOR-RGB #xFFFFFF) (ul-after t "58:2::255:255:255"))
  (check "ul color: white, the foreground is kept" (logior COLOR-RGB #xFFFFFF)
         (begin (ul-after t "38:2::255:255:255")
                (cell-fg (line-cells (grid-line (terminal-grid t) 0)) (- (terminal-cursor-col t) 1))))
  (check "ul color: 59" #f (ul-after t "59"))
  (check "ul color: parameters after it" (list 100 ATTR-BOLD)
         (list (ul-after t "58;5;100;1")
               (fxand ATTR-BOLD (cell-attrs (line-cells (grid-line (terminal-grid t) 0))
                                            (- (terminal-cursor-col t) 1)))))
  (check "ul color: 0 resets it" #f (ul-after t "0"))
  (ul-after t "58:5:9")
  (check "ul color: empty SGR resets it" #f (ul-after t ""))
  (ul-after t "58:5:9")
  (check "ul color: kept by other SGRs" 9 (ul-after t "4:3;31;1;22;24"))
  (check "ul color: 38 does not set it" 9 (ul-after t "38:2::1:2:3")))

;; stored in the upper bits of the cell's foreground field: the other fields,
;; blank cells and the extras are unchanged
(let ([a (make-term 3 20)] [b (make-term 3 20)])
  (feed a (esc "[4;58:2::255:0:0") "m" "red" (esc "[0m") "\r\n" (esc "[58:5:5m") "日x" (esc "[m") "yz")
  (feed b (esc "[4m") "red" (esc "[0m") "\r\n" "日x" "yz")
  (check "ul color: only the foreground fields differ" #t
         (for-all (lambda (r)
                    (let ([va (line-cells (grid-line (terminal-grid a) r))]
                          [vb (line-cells (grid-line (terminal-grid b) r))])
                      (for-all (lambda (i)
                                 (if (= 1 (mod i 3))
                                     (= (fxand #x3FFFFFF (fxvector-ref va i)) (fxvector-ref vb i))
                                     (= (fxvector-ref va i) (fxvector-ref vb i))))
                               (iota (fxvector-length va)))))
                  '(0 1 2)))
  (check "ul color: same colors" #t
         (equal? (map (lambda (c) (cell-fg (line-cells (grid-line (terminal-grid a) 0)) c)) (iota 20))
                 (map (lambda (c) (cell-fg (line-cells (grid-line (terminal-grid b) 0)) c)) (iota 20))))
  (check "ul color: blank cells are all zeros" #t
         (let ([v (line-cells (grid-line (terminal-grid a) 1))])
           (for-all (lambda (i) (= 0 (fxvector-ref v (+ 15 i)))) (iota (- 60 15)))))
  (check "ul color: no extras" '(#f #f) (map (lambda (r) (line-extra (grid-line (terminal-grid a) r))) '(0 1)))
  (check "ul color: per cell" (list (logior COLOR-RGB #xFF0000) (logior COLOR-RGB #xFF0000) #f)
         (map (lambda (c) (ul-at a 0 c)) '(0 2 3)))
  (check "ul color: wide character and after" '(5 5 5 #f) (map (lambda (c) (ul-at a 1 c)) '(0 1 2 3)))
  (check "ul color: no extras without it" #f (line-extra (grid-line (terminal-grid b) 0))))

;; it goes with its cells: overwritten, erased, scrolled, reflowed
(let ([t (make-term 3 10 100)])
  (feed t (esc "[58:5:1m") "abcdefghijklm" (esc "[m"))
  (check "ul color: wrapped" '(1 1 1 #f) (map (lambda (c) (ul-at t 1 c)) '(0 1 2 3)))
  (feed t (esc "[1;2H") "X" (esc "[1;4H") (esc "[1X") (esc "[1;8H") (esc "[K"))
  (check "ul color: overwritten and erased" '(1 #f 1 #f 1 1 1 #f #f #f)
         (map (lambda (c) (ul-at t 0 c)) (iota 10)))
  (feed t "\r\n\r\n\r\n\r\n")
  (check "ul color: in the history" 1 (ul-at t -2 4))
  (terminal-resize! t 3 5)
  (let ([row (- (grid-hist-count (terminal-grid t)))])
    (check "ul color: reflowed" '(1 #f 1 #f 1) (map (lambda (c) (ul-at t row c)) (iota 5)))))

;; with a hyperlink on the same cell; DECSC/DECRC, DECSTR, RIS
(let ([t (make-term 3 20)])
  (feed t (esc "]8;;http://u/\x1b;\\") (esc "[58:5:2m") "a" (esc "]8;;\x1b;\\") "b")
  (check "ul color: with a link" '(2 "http://u/" 2 #f) (list (ul-at t 0 0) (link-at t 0 0) (ul-at t 0 1) (link-at t 0 1)))
  (feed t (esc "7") (esc "[59m") "c")
  (check "ul color: before DECRC" #f (ul-at t 0 2))
  (feed t (esc "8") "d")
  (check "ul color: DECRC restores it" 2 (ul-at t 0 2))
  (feed t (esc "[!p") "e")
  (check "ul color: DECSTR" #f (ul-at t 0 3))
  (feed t (esc "[58:5:2m") (esc "c") "f")
  (check "ul color: RIS" #f (ul-at t 0 0)))

;; DECRQSS reports SGR, underline color included
(let ([t (make-term 3 20)])
  (define (sgr-report)
    (set! responses '())
    (feed t (esc "P$qm") (esc "\\"))
    (car responses))
  (check "DECRQSS m: default" "\x1b;P1$r0m\x1b;\\" (sgr-report))
  (feed t (esc "[1;3;4:3;7;9;31;104;58:2::1:2:3m"))
  (check "DECRQSS m: attributes and colors" "\x1b;P1$r0;1;3;4:3;7;9;31;104;58:2:1:2:3m\x1b;\\" (sgr-report))
  (feed t (esc "[0;2;4;5;8;38:5:200;48:2::10:20:30;58:5:9m"))
  (check "DECRQSS m: extended colors" "\x1b;P1$r0;2;4;5;8;38:5:200;48:2:10:20:30;58:5:9m\x1b;\\" (sgr-report))
  (feed t (esc "[0;58;5;3m"))
  (check "DECRQSS m: palette underline color" "\x1b;P1$r0;58:5:3m\x1b;\\" (sgr-report))
  (feed t (esc "[59m"))
  (check "DECRQSS m: 59" "\x1b;P1$r0m\x1b;\\" (sgr-report))
  (feed t (esc "[58:2::1:2:3m"))
  (feed-bytes t (let ([s (sgr-report)])
                  (string->utf8 (string-append (esc "[0m") "\x1b;[" (substring s 5 (- (string-length s) 2))))))
  (feed t "x")
  (check "DECRQSS m: the report restores it" (logior COLOR-RGB #x010203)
         (ul-at t (terminal-cursor-row t) (- (terminal-cursor-col t) 1))))

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

;; OSC 8 links: url-at finds an explicit link first, then URLs in the text
(let ([t (make-term 3 80)] [pt (lambda (t row col) (cons (terminal-abs-row t row) col))])
  (feed t (osc8 "" "https://explicit.example/") "see https://text.example/" (osc8 "" "")
        " https://plain.example/ " (osc8 "" "file://host/tmp/x") "日本" (osc8 "" "") "\r\n"
        (osc8 "id=j" "javascript:alert(1)") "js" (osc8 "" "") " " (osc8 "id=j" "javascript:alert(1)")
        "js" (osc8 "" ""))
  (check "url-at: explicit link" "https://explicit.example/" (url-at t (pt t 0 0)))
  (check "url-at: explicit link over a URL in its text" "https://explicit.example/" (url-at t (pt t 0 8)))
  (check "url-at: URL in the text" "https://plain.example/" (url-at t (pt t 0 26)))
  (check "url-at: wide character, second half" "file://host/tmp/x" (url-at t (pt t 0 50)))
  (check "url-at: nothing" #f (url-at t (pt t 2 0)))
  (check "url-at: scheme not allowed, still found" "javascript:alert(1)" (url-at t (pt t 1 0)))
  (check "link-id-at: none" 0 (link-id-at t (pt t 0 25)))
  (check "link-ranges: one run" '((0 25)) (link-ranges t (link-id-at t (pt t 0 3)) (terminal-abs-row t 0)))
  (check "link-ranges: wide characters" '((49 53))
         (link-ranges t (link-id-at t (pt t 0 50)) (terminal-abs-row t 0)))
  (check "link-ranges: same id, two runs" '((0 2) (3 5))
         (link-ranges t (link-id-at t (pt t 1 0)) (terminal-abs-row t 1)))
  (check "link-ranges: other row" '() (link-ranges t (link-id-at t (pt t 1 0)) (terminal-abs-row t 0)))
  (terminal-resize! t 3 30)
  (check "url-at: after reflow" "https://explicit.example/" (url-at t (pt t 0 4)))
  (check "url-at: after reflow, wrapped part" "file://host/tmp/x" (url-at t (pt t 1 20))))

;; Ctrl+click only opens these schemes
(for-each
 (lambda (u ok)
   (check (format "openable-url? ~a" u) ok (openable-url? u)))
 '("http://a/" "https://a/" "HTTPS://a/" "ftp://a/" "file:///tmp/x" "mailto:a@b" "javascript:alert(1)"
   "ssh://host" "data:text/html,x" "x-man-page://ls" "no-scheme" "" "https")
 '(#t #t #t #t #t #t #f #f #f #f #f #f #f))

;;; hint targets: OSC 8 links and URLs found in the text, as
;;; (uri start end label link?) with screen rows (negative in the history)
(define (targets t)
  (map (lambda (x)
         (let ([rel (lambda (p) (cons (terminal-rel-row t (car p)) (cdr p)))])
           (list (target-uri x) (rel (target-start x)) (rel (target-end x)) (rel (target-label x))
                 (> (target-link x) 0))))
       (hint-targets t)))

(let ([t (make-term 3 20)])
  (feed t (osc8 "id=a" "http://a/") "ab" (osc8 "" "") " " (osc8 "id=a" "http://a/") "cd" (osc8 "" "")
        " " (osc8 "" "http://b/") "ef" (osc8 "" "") " " (osc8 "" "javascript:x()") "js" (osc8 "" ""))
  (check "targets: one per link id, at its first run"
         '(("http://a/" (0 . 0) (0 . 2) (0 . 0) #t) ("http://b/" (0 . 6) (0 . 8) (0 . 6) #t)
           ("javascript:x()" (0 . 9) (0 . 11) (0 . 9) #t))
         (targets t)))

(let ([t (make-term 3 10)])
  (feed t "12345" (osc8 "" "http://wrap/") "abcdefgh" (osc8 "" "") " x")
  (check "targets: link wrapping onto the next row"
         '(("http://wrap/" (0 . 5) (1 . 3) (0 . 5) #t)) (targets t)))

(let ([t (make-term 6 20)])
  (feed t "see https://example.com/some/long/path ok\r\nhttp://two/ and (https://en.wikipedia.org/wiki/Foo_(bar)).")
  (check "targets: wrapped URL, brackets balanced, punctuation dropped"
         '(("https://example.com/some/long/path" (0 . 4) (1 . 18) (0 . 4) #f)
           ("http://two/" (3 . 0) (3 . 11) (3 . 0) #f))
         (list-head (targets t) 2))
  (check "text-url-at: wrapped part" "https://example.com/some/long/path"
         (text-url-at t (cons (terminal-abs-row t 1) 5)))
  (check "text-url-at: first part" "https://example.com/some/long/path"
         (url-at t (cons (terminal-abs-row t 0) 19)))
  (check "text-url-at: after the URL" #f (text-url-at t (cons (terminal-abs-row t 1) 19)))
  (check "targets: URL cut off at the bottom" "https://en.wikipedia.org/wiki/Foo_(bar)"
         (let ([t2 (make-term 6 50)])
           (feed t2 "(https://en.wikipedia.org/wiki/Foo_(bar)).")
           (target-uri (car (hint-targets t2)))))
  (check "target-ranges: wrapped URL" '(((4 20)) ((0 18)) ())
         (map (lambda (r) (target-ranges (car (hint-targets t)) (terminal-abs-row t r) 20)) '(0 1 2))))

;; scrolled back: only what is visible, and a URL that starts above the
;; view gets its label at the first visible cell
(let ([t (make-term 3 20 100)])
  (feed t "https://top.example/\r\n" "a https://a.example/xyz\r\nline\r\n" "b http://b/\r\n4\r\n5\r\n6")
  (check "targets: bottom of the screen" '() (targets t))
  (terminal-scroll-display! t 3)
  (check "targets: scrolled back"
         '(("https://a.example/xyz" (-4 . 2) (-3 . 3) (-3 . 0) #f) ("http://b/" (-1 . 2) (-1 . 11) (-1 . 2) #f))
         (targets t))
  (terminal-scroll-display! t 2)
  (check "targets: scrolled to the top"
         '(("https://top.example/" (-5 . 0) (-5 . 20) (-5 . 0) #f) ("https://a.example/xyz" (-4 . 2) (-3 . 3) (-4 . 2) #f))
         (targets t)))

;; URLs next to OSC 8 links
(let ([t (make-term 3 60)])
  (feed t (osc8 "" "https://explicit/") "see https://inside.example/" (osc8 "" "") "https://after.example/ "
        (osc8 "" "http://l/") "link" (osc8 "" "") " https://plain.example/")
  (check "targets: URLs next to links"
         '(("https://explicit/" (0 . 0) (0 . 27) (0 . 0) #t) ("https://after.example/" (0 . 27) (0 . 49) (0 . 27) #f)
           ("http://l/" (0 . 50) (0 . 54) (0 . 50) #t) ("https://plain.example/" (0 . 55) (1 . 17) (0 . 55) #f))
         (targets t)))

;; wide characters: in a URL, in a link, and a wide character that did not
;; fit at the end of a wrapped row
(let ([t (make-term 4 30)])
  (feed t "日本 https://例え.jp/パス x " (osc8 "" "http://w/") "日" (osc8 "" "") "\r\n"
        "https://abcdefghijklmnopqrstu日本 x")
  (check "targets: wide characters"
         '(("https://例え.jp/パス" (0 . 5) (0 . 25) (0 . 5) #f) ("http://w/" (0 . 28) (0 . 30) (0 . 28) #t)
           ("https://abcdefghijklmnopqrstu日本" (1 . 0) (2 . 4) (1 . 0) #f))
         (targets t))
  (check "text-url-at: second half of a wide character" "https://例え.jp/パス"
         (text-url-at t (cons (terminal-abs-row t 0) 24))))

;;; kitty keyboard protocol: flags stacks and their control sequences
(let ([t (make-term 3 10)])
  (define (query) (set! responses '()) (feed t (esc "[?u")) responses)
  (check "kbd: query initially" '("\x1b;[?0u") (query))
  (feed t (esc "[>1u"))
  (check "kbd: push" 1 (terminal-keyboard-flags t))
  (check "kbd: query after push" '("\x1b;[?1u") (query))
  (feed t (esc "[>11u"))
  (check "kbd: push again" 11 (terminal-keyboard-flags t))
  (feed t (esc "[<u"))
  (check "kbd: pop defaults to 1" 1 (terminal-keyboard-flags t))
  (feed t (esc "[<u"))
  (check "kbd: pop to the flags before the first push" 0 (terminal-keyboard-flags t))
  (feed t (esc "[<5u"))
  (check "kbd: pop on an empty stack" '("\x1b;[?0u") (query))
  (feed t (esc "[>u"))
  (check "kbd: push without flags pushes 0" 0 (terminal-keyboard-flags t))
  (feed t (esc "[>255u"))
  (check "kbd: unsupported bits are dropped" 31 (terminal-keyboard-flags t))
  (feed t (esc "[<10u"))
  (check "kbd: popping more entries than there are" 0 (terminal-keyboard-flags t))
  ;; set: 1 replaces, 2 ORs, 3 clears bits; on the empty stack it sets the base
  (feed t (esc "[=5u"))
  (check "kbd: set, mode defaults to 1" 5 (terminal-keyboard-flags t))
  (feed t (esc "[=2;2u"))
  (check "kbd: set mode 2 ORs" 7 (terminal-keyboard-flags t))
  (feed t (esc "[=4;3u"))
  (check "kbd: set mode 3 clears" 3 (terminal-keyboard-flags t))
  (feed t (esc "[=8;1u"))
  (check "kbd: set mode 1 replaces" 8 (terminal-keyboard-flags t))
  (feed t (esc "[=1;9u"))
  (check "kbd: unknown set mode is ignored" 8 (terminal-keyboard-flags t))
  (feed t (esc "[>1u") (esc "[=16;2u"))
  (check "kbd: set changes the top entry only" 17 (terminal-keyboard-flags t))
  (feed t (esc "[<u"))
  (check "kbd: entry below the top is kept" 8 (terminal-keyboard-flags t))
  (feed t (esc "[<u"))
  (check "kbd: popping the set base" 0 (terminal-keyboard-flags t)))

(let ([t (make-term 3 10)])
  ;; overflow: the stack holds 8 entries, including the 0 below the first push
  (do ([i 1 (+ i 1)]) ((> i 7)) (feed t (esc (format "[>~au" i))))
  (feed t (esc "[<7u"))
  (check "kbd: 7 pushes fit" 0 (terminal-keyboard-flags t))
  (do ([i 1 (+ i 1)]) ((> i 9)) (feed t (esc (format "[>~au" i))))
  (check "kbd: overflow keeps the newest" 9 (terminal-keyboard-flags t))
  (feed t (esc "[<7u"))
  (check "kbd: overflow evicts the oldest" 2 (terminal-keyboard-flags t))
  (feed t (esc "[<u"))
  (check "kbd: overflow, then popped empty" 0 (terminal-keyboard-flags t)))

(let ([t (make-term 3 10)])
  ;; each screen has its own stack
  (feed t (esc "[>1u"))
  (feed t (esc "[?1049h"))
  (check "kbd: alternate screen starts at 0" 0 (terminal-keyboard-flags t))
  (feed t (esc "[>15u"))
  (check "kbd: push on the alternate screen" 15 (terminal-keyboard-flags t))
  (feed t (esc "[?1049l"))
  (check "kbd: primary stack unchanged" 1 (terminal-keyboard-flags t))
  (feed t (esc "[<u"))
  (feed t (esc "[?1049h"))
  (check "kbd: alternate stack kept" 15 (terminal-keyboard-flags t))
  (set! responses '())
  (feed t (esc "[?u"))
  (check "kbd: query answers for the current screen" '("\x1b;[?15u") responses)
  (feed t (esc "[?1049l") (esc "[>3u") (esc "[?1049h"))
  (feed t (esc "c"))
  (check "kbd: RIS resets the stacks" 0 (terminal-keyboard-flags t))
  (feed t (esc "[?1049h"))
  (check "kbd: RIS resets the alternate stack" 0 (terminal-keyboard-flags t))
  (feed t (esc "[?1049l"))
  (feed t (esc "[<u"))
  (check "kbd: RIS empties the primary stack" 0 (terminal-keyboard-flags t)))

;; DECSTR (soft reset) empties both stacks too, as in kitty, but stays on
;; the alternate screen
(let ([t (make-term 3 10)])
  (feed t (esc "[>5u") (esc "[>1u") (esc "[?1049h") (esc "[>15u"))
  (feed t (esc "[!p"))
  (check "kbd: DECSTR resets the current stack" 0 (terminal-keyboard-flags t))
  (check "kbd: DECSTR stays on the alternate screen" #t (terminal-alt-screen? t))
  (set! responses '())
  (feed t (esc "[?u"))
  (check "kbd: query after DECSTR" '("\x1b;[?0u") responses)
  (feed t (esc "[?1049l"))
  (check "kbd: DECSTR resets the primary stack" 0 (terminal-keyboard-flags t))
  (feed t (esc "[<u"))
  (check "kbd: DECSTR empties the primary stack" 0 (terminal-keyboard-flags t))
  (feed t (esc "[>3u") (esc "[<u"))
  (check "kbd: push and pop after DECSTR" 0 (terminal-keyboard-flags t))
  (feed t (esc "[=7u"))
  (check "kbd: set after DECSTR" 7 (terminal-keyboard-flags t)))

(let ([t (make-term 3 10)])
  ;; CSI u without a prefix is still SCORC
  (feed t (esc "[2;3H") (esc "[s") (esc "[H") (esc "[u"))
  (check "kbd: CSI u restores the cursor" '(1 2) (cursor t))
  (check "kbd: CSI u leaves the flags alone" 0 (terminal-keyboard-flags t))
  (feed t (esc "[>1u") (esc "[H"))
  (check "kbd: CSI > u does not restore the cursor" '(0 0) (cursor t))
  (feed t (esc "[3;4H") (esc "[s") (esc "[H") (esc "[<u") (esc "[=1u") (esc "[?u"))
  (check "kbd: CSI < u / = u / ? u do not restore the cursor" '(0 0) (cursor t))
  (feed t (esc "[u"))
  (check "kbd: SCORC after the kitty sequences" '(2 3) (cursor t))
  (check "kbd: SCORC keeps the flags" 1 (terminal-keyboard-flags t)))

(check "kbd: enabled by default" #t (config-ref 'kitty-keyboard))

(let ([t (make-term 3 10)])
  ;; disabled: no reply, and the flags stay 0
  (terminal-set-kitty-keyboard! t #f)
  (feed t (esc "[>1u") (esc "[=3u") (esc "[?u"))
  (check "kbd disabled: no reply" '() responses)
  (check "kbd disabled: flags stay 0" 0 (terminal-keyboard-flags t))
  (terminal-set-kitty-keyboard! t #t)
  (check "kbd enabled again: the ignored push left nothing" 0 (terminal-keyboard-flags t))
  (feed t (esc "[>1u"))
  (terminal-set-kitty-keyboard! t #f)
  (check "kbd disabled while flags are set" 0 (terminal-keyboard-flags t)))

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

;;; key events from xkb: a two-layout keymap (us, ru), without compose
(let ()
  (define keymap "xkb_keymap {
  xkb_keycodes { minimum = 8; maximum = 255;
    <ESC> = 9; <AE02> = 11; <TAB> = 23; <LCTL> = 37; <AC01> = 38; <LFSH> = 50;
    <AB03> = 54; <CAPS> = 66; <NMLK> = 77; <KP1> = 87; <RCTL> = 105; <UP> = 111; };
  xkb_types {
    type \"ONE_LEVEL\" { modifiers = none; level_name[Level1] = \"Any\"; };
    type \"TWO_LEVEL\" { modifiers = Shift; map[Shift] = Level2;
      level_name[Level1] = \"Base\"; level_name[Level2] = \"Shift\"; };
    type \"ALPHABETIC\" { modifiers = Shift+Lock; map[Shift] = Level2; map[Lock] = Level2;
      level_name[Level1] = \"Base\"; level_name[Level2] = \"Caps\"; };
    type \"KEYPAD\" { modifiers = Shift+Mod2; map[Mod2] = Level2; map[Shift] = Level2;
      map[Shift+Mod2] = Level1; level_name[Level1] = \"Base\"; level_name[Level2] = \"Number\"; };
  };
  xkb_compat { };
  xkb_symbols {
    key <ESC> { type = \"ONE_LEVEL\", [ Escape ] };
    key <TAB> { type = \"ONE_LEVEL\", [ Tab ] };
    key <UP> { type = \"ONE_LEVEL\", [ Up ] };
    key <LCTL> { type = \"ONE_LEVEL\", [ Control_L ] };
    key <RCTL> { type = \"ONE_LEVEL\", [ Control_R ] };
    key <LFSH> { type = \"ONE_LEVEL\", [ Shift_L ] };
    key <CAPS> { type = \"ONE_LEVEL\", [ Caps_Lock ] };
    key <NMLK> { type = \"ONE_LEVEL\", [ Num_Lock ] };
    key <KP1> { type = \"KEYPAD\", [ KP_End, KP_1 ] };
    key <AE02> { type[Group1] = \"TWO_LEVEL\", type[Group2] = \"TWO_LEVEL\",
      symbols[Group1] = [ 2, at ], symbols[Group2] = [ 2, quotedbl ] };
    key <AC01> { type[Group1] = \"ALPHABETIC\", type[Group2] = \"ALPHABETIC\",
      symbols[Group1] = [ a, A ], symbols[Group2] = [ Cyrillic_ef, Cyrillic_EF ] };
    key <AB03> { type[Group1] = \"ALPHABETIC\", type[Group2] = \"ALPHABETIC\",
      symbols[Group1] = [ c, C ], symbols[Group2] = [ Cyrillic_es, Cyrillic_ES ] };
    modifier_map Shift { <LFSH> }; modifier_map Lock { <CAPS> };
    modifier_map Control { <LCTL>, <RCTL> }; modifier_map Mod2 { <NMLK> };
  };
};")
  ;; evdev keycodes, and xkb's real modifier masks
  (define ESC 1) (define K2 3) (define TAB 15) (define LCTL 29) (define KA 30) (define LSHIFT 42)
  (define KC 46) (define CAPS 58) (define NUMLOCK 69) (define KP1 79) (define RCTL 97) (define UP 103)
  (define shift 1) (define lock 2) (define control 4) (define mod2 16)
  (define kb (make-keyboard))
  (define (mods! depressed locked group) (keyboard-update-modifiers! kb depressed 0 locked group))
  (define (press key) (keyboard-translate kb key KEY-PRESS))
  (define (release key) (keyboard-translate kb key KEY-RELEASE))
  (define (fields ev)
    (list (key-event-text ev) (key-event-mods ev) (key-event-locks ev)
          (utf32 (key-event-key ev)) (key-event-shifted ev) (key-event-base ev)
          (key-event-type ev)))
  (define (utf32 sym) (let ([c (xkb_keysym_to_utf32 sym)]) (if (= c 0) sym c)))
  (define (enc flags ev) (encode-key ev #f #f #f flags))
  (keyboard-set-keymap-string! kb keymap)
  (mods! 0 0 0)
  (check "xkb: a" '("a" 0 0 97 0 0 1) (fields (press KA)))
  (check "xkb: a release" '("" 0 0 97 0 0 3) (fields (release KA)))
  (mods! shift 0 0)
  (check "xkb: shift+a" (list "A" MOD-SHIFT 0 97 65 0 1) (fields (press KA)))
  (check "xkb: shift+2" (list "@" MOD-SHIFT 0 50 64 0 1) (fields (press K2)))
  (check "xkb: shift+2, alternates" "\x1b;[50:64;2u" (enc 12 (press K2)))
  (mods! control 0 0)
  (check "xkb: ctrl+a" (list "\x1;" MOD-CTRL 0 97 0 0 1) (fields (press KA)))
  (check "xkb: ctrl+a, disambiguated" "\x1b;[97;5u" (enc 1 (press KA)))
  (check "xkb: ctrl+a, legacy" "\x1;" (enc 0 (press KA)))
  (mods! 0 lock 0)
  (check "xkb: caps lock: a" (list "A" 0 MOD-CAPS-LOCK 97 65 0 1) (fields (press KA)))
  (check "xkb: caps lock: a, all keys" "\x1b;[97;65u" (enc 8 (press KA)))
  (mods! 0 mod2 0)
  (check "xkb: num lock: KP_1 key" (list "1" 0 MOD-NUM-LOCK 49 0 0 1) (fields (press KP1)))
  (mods! 0 0 0)
  (check "xkb: KP_End" "\x1b;[57424u" (enc 1 (press KP1)))
  (mods! 0 mod2 0)
  (check "xkb: num lock: KP_1" "\x1b;[57400;129u" (enc 8 (press KP1)))
  (check "xkb: num lock: KP_1 text" "1" (enc 1 (press KP1)))
  ;; second layout: the key is Cyrillic, the base key comes from the first layout
  (mods! 0 0 1)
  (check "xkb: ru: es" (list "с" 0 0 1089 0 99 1) (fields (press KC)))
  (check "xkb: ru: 2 has no base key" (list "2" 0 0 50 0 0 1) (fields (press K2)))
  (mods! shift 0 1)
  (check "xkb: ru: shift+es" (list "С" MOD-SHIFT 0 1089 1057 99 1) (fields (press KC)))
  (mods! control 0 1)
  (check "xkb: ru: ctrl+es, alternates" "\x1b;[1089::99;5u" (enc 5 (press KC)))
  (check "xkb: ru: ctrl+es, legacy byte of ctrl+c with flag 2" "\x3;" (enc 2 (press KC)))
  (mods! (logor control shift) 0 1)
  (check "xkb: ru: ctrl+shift+es" "\x1b;[1089:1057:99;6u" (enc 5 (press KC)))
  ;; modifier keys carry their own bit, including the effect of the event
  (mods! 0 0 0)
  (check "xkb: Control_L press" (list MOD-CTRL (xkb_keysym_from_name "Control_L" 0))
         (let ([e (press LCTL)]) (list (key-event-mods e) (key-event-key e))))
  (check "xkb: Control_L press, all keys" "\x1b;[57442;5u" (begin (release LCTL) (enc 8 (press LCTL))))
  (mods! control 0 0)
  (check "xkb: Control_R press while Control_L is held" "\x1b;[57448;5u" (enc 8 (press RCTL)))
  (check "xkb: Control_R release, Control_L still held" "\x1b;[57448;5:3u" (enc 10 (release RCTL)))
  (check "xkb: Control_L release" "\x1b;[57442;1:3u" (enc 10 (release LCTL)))
  (mods! 0 0 0)
  (check "xkb: Shift_L press" "\x1b;[57441;2u" (enc 8 (press LSHIFT)))
  (mods! shift 0 0)
  (check "xkb: Shift_L release" "\x1b;[57441;1:3u" (enc 10 (release LSHIFT)))
  (mods! 0 0 0)
  (check "xkb: Caps_Lock press locks" "\x1b;[57358;65u" (enc 8 (press CAPS)))
  (mods! 0 lock 0)
  (check "xkb: Caps_Lock release keeps the lock" "\x1b;[57358;65:3u" (enc 10 (release CAPS)))
  (check "xkb: Caps_Lock press unlocks" "\x1b;[57358u" (enc 8 (press CAPS)))
  (mods! 0 0 0)
  (check "xkb: Num_Lock press" "\x1b;[57360;129u" (enc 8 (press NUMLOCK)))
  (check "xkb: modifier keys, legacy" #f (enc 0 (press LSHIFT)))
  (check "xkb: Escape" "\x1b;[27u" (enc 1 (press ESC)))
  (check "xkb: Tab" "\t" (enc 1 (press TAB)))
  (mods! shift 0 0)
  (check "xkb: shift+Tab" "\x1b;[9;2u" (enc 1 (press TAB)))
  (mods! 0 0 0)
  (check "xkb: Up release" "\x1b;[1;1:3A" (enc 2 (release UP)))
  (check "xkb: Up repeat" "\x1b;[1;1:2A" (enc 2 (key-event-with-type (press UP) KEY-REPEAT))))

;;; Hyper and Meta: which real modifier each modifier class maps to is
;;; found by pressing the keymap's keys (see modifier-mapping)
(let ()
  ;; a keymap whose modifier keys set modifiers, with Hyper and Meta on the
  ;; real modifiers given, and optionally a second Alt key on another one
  (define (keymap hyper meta alt-r)
    (format "xkb_keymap {
  xkb_keycodes { minimum = 8; maximum = 255;
    <LFSH> = 50; <LCTL> = 37; <LALT> = 64; <LWIN> = 133; <CAPS> = 66; <NMLK> = 77;
    <AC01> = 38; <HYPR> = 207; <META> = 205; <RALT> = 108; };
  xkb_types {
    type \"ONE_LEVEL\" { modifiers = none; level_name[Level1] = \"Any\"; };
    type \"ALPHABETIC\" { modifiers = Shift+Lock; map[Shift] = Level2; map[Lock] = Level2;
      level_name[Level1] = \"Base\"; level_name[Level2] = \"Caps\"; };
  };
  xkb_compat {
    interpret Caps_Lock { action = LockMods(modifiers = modMapMods); };
    interpret Num_Lock { action = LockMods(modifiers = modMapMods); };
    interpret Any + AnyOf(all) { action = SetMods(modifiers = modMapMods); };
  };
  xkb_symbols {
    key <LFSH> { [ Shift_L ] }; key <LCTL> { [ Control_L ] }; key <LALT> { [ Alt_L ] };
    key <RALT> { [ Alt_R ] }; key <LWIN> { [ Super_L ] }; key <CAPS> { [ Caps_Lock ] };
    key <NMLK> { [ Num_Lock ] }; key <HYPR> { [ Hyper_L ] }; key <META> { [ Meta_L ] };
    key <AC01> { type = \"ALPHABETIC\", [ a, A ] };
    modifier_map Shift { <LFSH> }; modifier_map Lock { <CAPS> };
    modifier_map Control { <LCTL> }; modifier_map Mod1 { <LALT> };
    modifier_map ~a { <RALT> }; modifier_map Mod2 { <NMLK> }; modifier_map Mod4 { <LWIN> };
    modifier_map ~a { <HYPR> }; modifier_map ~a { <META> };
  };
};" alt-r hyper meta))
  ;; evdev keycodes, and xkb's real modifier masks
  (define LSHIFT 42) (define LCTL 29) (define LALT 56) (define LWIN 125) (define CAPS 58)
  (define NUMLOCK 69) (define KA 30) (define HYPER 199) (define META 197)
  (define shift 1) (define lock 2) (define control 4) (define mod1 8) (define mod2 16)
  (define mod3 32) (define mod4 64) (define mod5 128)
  (define (sym name) (xkb_keysym_from_name name 0))
  (define (keyboard-with km)
    (let ([kb (make-keyboard)]) (keyboard-set-keymap-string! kb km) kb))
  (define (mods kb depressed . locked)
    (keyboard-update-modifiers! kb depressed 0 (if (pair? locked) (car locked) 0) 0)
    (list (keyboard-mods kb) (keyboard-locks kb)))
  (define (press kb key) (keyboard-translate kb key KEY-PRESS))
  (define (release kb key) (keyboard-translate kb key KEY-RELEASE))
  (define (enc flags ev) (encode-key ev #f #f #f flags))

  ;; the usual layout: Hyper shares Mod4 with Super, Meta shares Mod1 with Alt
  (let ([kb (keyboard-with (keymap "Mod4" "Mod1" "Mod1"))])
    (check "mods: shift" (list MOD-SHIFT 0) (mods kb shift))
    (check "mods: ctrl" (list MOD-CTRL 0) (mods kb control))
    (check "mods: Mod1 is Alt only" (list MOD-ALT 0) (mods kb mod1))
    (check "mods: Mod4 is Super only" (list MOD-SUPER 0) (mods kb mod4))
    (check "mods: locks" (list 0 (logior MOD-CAPS-LOCK MOD-NUM-LOCK)) (mods kb 0 (logior lock mod2)))
    (check "mods: Mod3 and Mod5 are nothing" (list 0 0) (mods kb (logior mod3 mod5)))
    (mods kb 0)
    (check "mods: Hyper_L on Super's modifier sets Super"
           (list MOD-SUPER (sym "Hyper_L")) (let ([e (press kb HYPER)]) (list (key-event-mods e) (key-event-key e))))
    (check "mods: Hyper_L, all keys" "\x1b;[57445;9u" (begin (release kb HYPER) (enc 8 (press kb HYPER))))
    (release kb HYPER)
    (check "mods: Meta_L on Alt's modifier sets Alt" "\x1b;[57446;3u" (enc 8 (press kb META)))
    (release kb META)
    (check "mods: Super_L" "\x1b;[57444;9u" (enc 8 (press kb LWIN))))

  ;; Hyper on Mod3 and Meta on Mod5, modifiers of their own
  (let ([kb (keyboard-with (keymap "Mod3" "Mod5" "Mod1"))])
    (check "mods: Mod3 is Hyper" (list MOD-HYPER 0) (mods kb mod3))
    (check "mods: Mod5 is Meta" (list MOD-META 0) (mods kb mod5))
    (check "mods: Mod4 is still Super" (list MOD-SUPER 0) (mods kb mod4))
    (check "mods: Hyper+Super+Ctrl" (list (logior MOD-HYPER MOD-SUPER MOD-CTRL) 0)
           (mods kb (logior mod3 mod4 control)))
    (mods kb mod3)
    (let ([e (press kb KA)])
      (check "mods: hyper+a" (list "a" MOD-HYPER) (list (key-event-text e) (key-event-mods e)))
      (check "mods: hyper+a, disambiguated" "\x1b;[97;17u" (enc 1 e))
      (check "mods: hyper+a, legacy ignores Hyper" "a" (enc 0 e))
      (check "mods: hyper+a, bindings ignore Hyper" 0 (key-event-legacy-mods e)))
    (mods kb (logior mod5 control))
    (let ([e (press kb KA)])
      (check "mods: ctrl+meta+a, disambiguated" "\x1b;[97;37u" (enc 1 e))
      (check "mods: ctrl+meta+a, legacy" "\x1;" (enc 0 e))
      (check "mods: ctrl+meta+a, bindings see Ctrl" MOD-CTRL (key-event-legacy-mods e)))
    (mods kb 0)
    (check "mods: Hyper_L press" "\x1b;[57445;17u" (enc 8 (press kb HYPER)))
    (mods kb mod3)
    (check "mods: Hyper_L release" "\x1b;[57445;1:3u" (enc 10 (release kb HYPER)))
    (mods kb 0)
    (check "mods: Meta_L press" "\x1b;[57446;33u" (enc 8 (press kb META)))
    (mods kb mod5)
    (check "mods: Meta_L release" "\x1b;[57446;1:3u" (enc 10 (release kb META)))
    (mods kb 0)
    (check "mods: Hyper_L, legacy" #f (enc 0 (press kb HYPER)))
    (release kb HYPER)
    ;; leaving the window forgets modifiers and held modifier keys
    (mods kb (logior mod3 control) lock)
    (press kb LCTL)
    (keyboard-reset-modifiers! kb)
    (check "mods: reset" (list 0 0) (list (keyboard-mods kb) (keyboard-locks kb)))
    (check "mods: a after reset" 0 (key-event-mods (press kb KA))))

  ;; two Alt keys on different modifiers: no reliable mapping, so modifiers
  ;; are taken by name and Hyper and Meta are not reported
  (let ([kb (keyboard-with (keymap "Mod3" "Mod5" "Mod3"))])
    (check "mods: fallback: Mod1 is Alt" (list MOD-ALT 0) (mods kb mod1))
    (check "mods: fallback: Mod3 is nothing" (list 0 0) (mods kb mod3))
    (check "mods: fallback: Mod4 is Super" (list MOD-SUPER 0) (mods kb mod4))
    (mods kb 0)
    (check "mods: fallback: Hyper_L sets nothing" "\x1b;[57445u" (enc 8 (press kb HYPER)))))

;;; kitty keyboard protocol: encoding
(let ()
  ;; (kev keysym-name text mods option value ...), options: key (keysym name
  ;; of the unmodified key), shifted, base (code points), locks, type, composed
  (define (sym name) (xkb_keysym_from_name name 0))     ; case-sensitive
  (define (kev name text mods . opts)
    (let* ([ev (make-key-event (sym name) text mods)]
           [opt (lambda (k default) (let ([m (memq k opts)]) (if m (cadr m) default)))])
      (make-key-event (key-event-sym ev) text mods (opt 'locks 0)
                      (let ([k (opt 'key #f)]) (if k (sym k) (key-event-key ev)))
                      (opt 'shifted (key-event-shifted ev)) (opt 'base 0)
                      (opt 'type KEY-PRESS) (opt 'composed #f))))
  (define (enc flags ev . modes)
    (let ([m (if (null? modes) '(#f #f #f) modes)])
      (encode-key ev (car m) (cadr m) (caddr m) flags)))
  (define S MOD-SHIFT) (define A MOD-ALT) (define C MOD-CTRL) (define W MOD-SUPER)
  (define CS (logor C S)) (define CA (logor C A)) (define SA (logor S A))
  (define NUM MOD-NUM-LOCK) (define CAPS MOD-CAPS-LOCK)
  (define R KEY-RELEASE) (define RP KEY-REPEAT)
  (define (x . parts) (apply string-append "\x1b;[" parts))
  (define (check-table name flags rows)
    (for-each (lambda (r)
                (check (format "kitty ~a ~a: ~a" name flags (car r)) (caddr r) (enc flags (cadr r))))
              rows))

  ;; flags 0: repeats encode like presses, releases send nothing
  (check "kitty 0: repeat" "a" (enc 0 (kev "a" "a" 0 'type RP)))
  (check "kitty 0: release" #f (enc 0 (kev "a" "a" 0 'type R)))
  (check "kitty 0: release of Up" #f (enc 0 (kev "Up" "" 0 'type R)))

  ;; 1: disambiguate escape codes
  (check-table "disambiguate" 1
    `(("a" ,(kev "a" "a" 0) "a")
      ("shift+a" ,(kev "A" "A" S) "A")
      ("é" ,(kev "eacute" "é" 0) "é")
      ("ctrl+a" ,(kev "a" "\x1;" C) ,(x "97;5u"))
      ("ctrl+i" ,(kev "i" "\t" C) ,(x "105;5u"))
      ("ctrl+shift+i" ,(kev "I" "\t" CS) ,(x "105;6u"))
      ("alt+a" ,(kev "a" "a" A) ,(x "97;3u"))
      ("ctrl+alt+a" ,(kev "a" "\x1;" CA) ,(x "97;7u"))
      ("shift+alt+a" ,(kev "A" "A" SA) ,(x "97;4u"))
      ("super+a" ,(kev "a" "a" W) ,(x "97;9u"))
      ("ctrl+super+a" ,(kev "a" "\x1;" (logor C W)) ,(x "97;13u"))
      ("alt+[" ,(kev "bracketleft" "[" A) ,(x "91;3u"))
      ("ctrl+space" ,(kev "space" " " C) ,(x "32;5u"))
      ("space" ,(kev "space" " " 0) " ")
      ("Escape" ,(kev "Escape" "\x1b;" 0) ,(x "27u"))
      ("alt+Escape" ,(kev "Escape" "\x1b;" A) ,(x "27;3u"))
      ("Enter" ,(kev "Return" "\r" 0) "\r")
      ("shift+Enter" ,(kev "Return" "\r" S) ,(x "13;2u"))
      ("ctrl+Enter" ,(kev "Return" "\r" C) ,(x "13;5u"))
      ("alt+Enter" ,(kev "Return" "\r" A) ,(x "13;3u"))
      ("Tab" ,(kev "Tab" "\t" 0) "\t")
      ("shift+Tab" ,(kev "ISO_Left_Tab" "" S) ,(x "9;2u"))
      ("ctrl+shift+Tab" ,(kev "ISO_Left_Tab" "" CS) ,(x "9;6u"))
      ("Backspace" ,(kev "BackSpace" "\b" 0) "\x7f;")
      ("ctrl+Backspace" ,(kev "BackSpace" "\b" C) ,(x "127;5u"))
      ("alt+Backspace" ,(kev "BackSpace" "\b" A) ,(x "127;3u"))
      ("Up" ,(kev "Up" "" 0) ,(x "A"))
      ("Down" ,(kev "Down" "" 0) ,(x "B"))
      ("Right" ,(kev "Right" "" 0) ,(x "C"))
      ("Left" ,(kev "Left" "" 0) ,(x "D"))
      ("ctrl+Up" ,(kev "Up" "" C) ,(x "1;5A"))
      ("shift+alt+Left" ,(kev "Left" "" SA) ,(x "1;4D"))
      ("Home" ,(kev "Home" "" 0) ,(x "H"))
      ("End" ,(kev "End" "" 0) ,(x "F"))
      ("Insert" ,(kev "Insert" "" 0) ,(x "2~"))
      ("Delete" ,(kev "Delete" "" 0) ,(x "3~"))
      ("PageUp" ,(kev "Prior" "" 0) ,(x "5~"))
      ("ctrl+PageDown" ,(kev "Next" "" C) ,(x "6;5~"))
      ("F1" ,(kev "F1" "" 0) ,(x "P"))
      ("F2" ,(kev "F2" "" 0) ,(x "Q"))
      ("F3" ,(kev "F3" "" 0) ,(x "13~"))
      ("F4" ,(kev "F4" "" 0) ,(x "S"))
      ("F5" ,(kev "F5" "" 0) ,(x "15~"))
      ("F6" ,(kev "F6" "" 0) ,(x "17~"))
      ("F7" ,(kev "F7" "" 0) ,(x "18~"))
      ("F8" ,(kev "F8" "" 0) ,(x "19~"))
      ("F9" ,(kev "F9" "" 0) ,(x "20~"))
      ("F10" ,(kev "F10" "" 0) ,(x "21~"))
      ("F11" ,(kev "F11" "" 0) ,(x "23~"))
      ("F12" ,(kev "F12" "" 0) ,(x "24~"))
      ("ctrl+F1" ,(kev "F1" "" C) ,(x "1;5P"))
      ("shift+F3" ,(kev "F3" "" S) ,(x "13;2~"))
      ("shift+F5" ,(kev "F5" "" S) ,(x "15;2~"))
      ("F13" ,(kev "F13" "" 0) ,(x "57376u"))
      ("F35" ,(kev "F35" "" 0) ,(x "57398u"))
      ("KP_1 with text" ,(kev "KP_1" "1" 0 'locks NUM) "1")
      ("ctrl+KP_1" ,(kev "KP_1" "1" C 'locks NUM) ,(x "57400;133u"))
      ("KP_End" ,(kev "KP_End" "" 0) ,(x "57424u"))
      ("KP_Prior" ,(kev "KP_Prior" "" 0) ,(x "57421u"))
      ("ctrl+KP_Prior" ,(kev "KP_Prior" "" C) ,(x "57421;5u"))
      ("KP_Up" ,(kev "KP_Up" "" 0) ,(x "57419u"))
      ("KP_Enter" ,(kev "KP_Enter" "\r" 0) ,(x "57414u"))
      ("KP_Begin" ,(kev "KP_Begin" "" 0) ,(x "E"))
      ("KP_Add" ,(kev "KP_Add" "+" 0) "+")
      ("Menu" ,(kev "Menu" "" 0) ,(x "57363u"))
      ("Print" ,(kev "Print" "" 0) ,(x "57361u"))
      ("Pause" ,(kev "Pause" "" 0) ,(x "57362u"))
      ("Scroll_Lock" ,(kev "Scroll_Lock" "" 0) ,(x "57359u"))
      ("XF86AudioPlay" ,(kev "XF86AudioPlay" "" 0) ,(x "57428u"))
      ("XF86AudioMute" ,(kev "XF86AudioMute" "" 0) ,(x "57440u"))
      ("XF86AudioRaiseVolume" ,(kev "XF86AudioRaiseVolume" "" 0) ,(x "57439u"))
      ("Shift_L is not reported" ,(kev "Shift_L" "" S) #f)
      ("Caps_Lock is not reported" ,(kev "Caps_Lock" "" 0 'locks CAPS) #f)
      ;; lock modifiers: not reported for text, reported otherwise
      ("num lock: a" ,(kev "a" "a" 0 'locks NUM) "a")
      ("caps lock: A" ,(kev "A" "A" 0 'key "a" 'locks CAPS) "A")
      ("num lock: ctrl+a" ,(kev "a" "\x1;" C 'locks NUM) ,(x "97;133u"))
      ("caps lock: ctrl+a" ,(kev "a" "\x1;" C 'locks CAPS) ,(x "97;69u"))
      ("num lock: Enter" ,(kev "Return" "\r" 0 'locks NUM) "\r")
      ("num lock: Escape" ,(kev "Escape" "\x1b;" 0 'locks NUM) ,(x "27;129u"))
      ("num lock: Up" ,(kev "Up" "" 0 'locks NUM) ,(x "1;129A"))
      ;; compose results are text, sent as it is
      ("compose é" ,(kev "eacute" "é" 0 'composed #t 'key "e") "é")))
  (check "kitty 1: app cursor mode does not change Up" (x "A") (enc 1 (kev "Up" "" 0) #t #f #f))
  (check "kitty 1: app keypad mode does not change KP_1" "1" (enc 1 (kev "KP_1" "1" 0) #f #t #f))
  (check "kitty 1: newline mode does not change Enter" "\r" (enc 1 (kev "Return" "\r" 0) #f #f #t))
  (check "kitty 1: releases need flag 2" #f (enc 1 (kev "a" "a" C 'type R)))
  (check "kitty 1: repeat is a press" (x "97;5u") (enc 1 (kev "a" "\x1;" C 'type RP)))

  ;; 2: report event types
  (check-table "event types" 2
    `(("a press" ,(kev "a" "a" 0) "a")
      ;; text keys send their text on press and repeat, as kitty does
      ("a repeat" ,(kev "a" "a" 0 'type RP) "a")
      ("a release" ,(kev "a" "a" 0 'type R) ,(x "97;1:3u"))
      ("shift+a release" ,(kev "A" "A" S 'type R) ,(x "97;2:3u"))
      ;; not disambiguated: the legacy bytes of the specification
      ("ctrl+a press" ,(kev "a" "\x1;" C) "\x1;")
      ("ctrl+a repeat" ,(kev "a" "\x1;" C 'type RP) ,(x "97;5:2u"))
      ("ctrl+a release" ,(kev "a" "\x1;" C 'type R) ,(x "97;5:3u"))
      ("Up press" ,(kev "Up" "" 0) ,(x "A"))
      ("Up repeat" ,(kev "Up" "" 0 'type RP) ,(x "1;1:2A"))
      ("Up release" ,(kev "Up" "" 0 'type R) ,(x "1;1:3A"))
      ("ctrl+Up release" ,(kev "Up" "" C 'type R) ,(x "1;5:3A"))
      ("F5 release" ,(kev "F5" "" 0 'type R) ,(x "15;1:3~"))
      ("F1 release" ,(kev "F1" "" 0 'type R) ,(x "1;1:3P"))
      ;; kitty sends ESC here; a release must not look like a press
      ("Escape press" ,(kev "Escape" "\x1b;" 0) "\x1b;")
      ("Escape release" ,(kev "Escape" "\x1b;" 0 'type R) ,(x "27;1:3u"))
      ("Enter press" ,(kev "Return" "\r" 0) "\r")
      ("Enter release" ,(kev "Return" "\r" 0 'type R) #f)
      ("Tab release" ,(kev "Tab" "\t" 0 'type R) #f)
      ("Backspace repeat" ,(kev "BackSpace" "\b" 0 'type RP) "\x7f;")
      ("Backspace release" ,(kev "BackSpace" "\b" 0 'type R) #f)
      ("ctrl+Enter release" ,(kev "Return" "\r" C 'type R) ,(x "13;5:3u"))
      ("Shift_L press is not reported" ,(kev "Shift_L" "" S) #f)
      ;; Ctrl+С on a Cyrillic layout: not disambiguated, so Ctrl+C's byte
      ("ctrl+es, base c" ,(kev "Cyrillic_es" "с" C 'base 99) "\x3;")
      ("alt+es, base c" ,(kev "Cyrillic_es" "с" A 'base 99) "\x1b;c")))
  (check-table "disambiguate + event types" 3
    `(("Backspace press" ,(kev "BackSpace" "\b" 0) "\x7f;")
      ("Backspace release" ,(kev "BackSpace" "\b" 0 'type R) #f)
      ("locks: Enter press" ,(kev "Return" "\r" 0 'locks (logor NUM CAPS)) "\r")
      ("locks: Enter release" ,(kev "Return" "\r" 0 'locks (logor NUM CAPS) 'type R) #f)
      ("a release" ,(kev "a" "a" 0 'type R) ,(x "97;1:3u"))
      ("ctrl+a press" ,(kev "a" "\x1;" C) ,(x "97;5u"))
      ("ctrl+a release" ,(kev "a" "\x1;" C 'type R) ,(x "97;5:3u"))
      ("Escape press" ,(kev "Escape" "\x1b;" 0) ,(x "27u"))
      ("KP_End release" ,(kev "KP_End" "" 0 'type R) ,(x "57424;1:3u"))
      ("compose release" ,(kev "eacute" "é" 0 'composed #t 'type R) #f)))

  ;; 2 alone keeps the legacy text keys of the specification's example table
  (for-each
   (lambda (row)
     (let ([name (car row)] [sym (cadr row)] [shifted-name (caddr row)] [cp (cadddr row)])
       (for-each
        (lambda (mods expected)
          (check (format "kitty 2: legacy text key ~a mods ~a" name mods) expected
                 (enc 2 (if (logtest mods S)
                            (kev shifted-name "" mods 'key sym 'shifted cp)
                            (kev sym "" mods 'shifted 0)))))
        (list A C SA CA CS)
        (list-tail row 4))))
   `(("i" "i" "I" 73 "\x1b;i" "\t" "\x1b;I" "\x1b;\t" ,(x "105;6u"))
     ("3" "3" "numbersign" 35 "\x1b;3" "\x1b;" "\x1b;#" "\x1b;\x1b;" ,(x "51;6u"))
     (";" "semicolon" "colon" 58 "\x1b;;" ";" "\x1b;:" "\x1b;;" ,(x "59;6u"))))
  (check "kitty 2: ctrl+shift+space" "\x0;" (enc 2 (kev "space" "" CS)))
  (check "kitty 2: super+a is not legacy" (x "97;9u") (enc 2 (kev "a" "a" W)))

  ;; 4: report alternate keys (shifted key, and the key in the first layout)
  (check-table "alternates" 4
    `(("a" ,(kev "a" "a" 0) "a")
      ("shift+a has text" ,(kev "A" "A" S) "A")
      ("ctrl+a" ,(kev "a" "\x1;" C) "\x1;")
      ("ctrl+shift+a" ,(kev "A" "\x1;" CS) ,(x "97:65;6u"))
      ("ctrl+es" ,(kev "Cyrillic_es" "с" C 'base 99) ,(x "1089::99;5u"))))
  (check-table "disambiguate + alternates" 5
    `(("a" ,(kev "a" "a" 0) "a")
      ("ctrl+a" ,(kev "a" "\x1;" C) ,(x "97;5u"))
      ("ctrl+shift+a" ,(kev "A" "\x1;" CS) ,(x "97:65;6u"))
      ("alt+shift+2" ,(kev "at" "@" SA 'key "2" 'shifted 64) ,(x "50:64;4u"))
      ("ctrl+a, shifted key without shift" ,(kev "a" "\x1;" C 'shifted 65) ,(x "97;5u"))
      ("es" ,(kev "Cyrillic_es" "с" 0 'base 99) "с")
      ("ctrl+es" ,(kev "Cyrillic_es" "с" C 'base 99) ,(x "1089::99;5u"))
      ("ctrl+shift+ES" ,(kev "Cyrillic_ES" "С" CS 'key "Cyrillic_es" 'base 99) ,(x "1089:1057:99;6u"))
      ("functional keys have no alternates" ,(kev "Up" "" S 'base 65) ,(x "1;2A"))))

  ;; 8: report all keys as escape codes
  (check-table "all keys" 8
    `(("a" ,(kev "a" "a" 0) ,(x "97u"))
      ("a repeat" ,(kev "a" "a" 0 'type RP) ,(x "97u"))
      ("a release" ,(kev "a" "a" 0 'type R) #f)
      ("shift+a" ,(kev "A" "A" S) ,(x "97;2u"))
      ("ctrl+a" ,(kev "a" "\x1;" C) ,(x "97;5u"))
      ("é" ,(kev "eacute" "é" 0) ,(x "233u"))
      ("space" ,(kev "space" " " 0) ,(x "32u"))
      ("num lock: a" ,(kev "a" "a" 0 'locks NUM) ,(x "97;129u"))
      ("Up" ,(kev "Up" "" 0) ,(x "A"))
      ("F1" ,(kev "F1" "" 0) ,(x "P"))
      ("Escape" ,(kev "Escape" "\x1b;" 0) ,(x "27u"))
      ("Enter" ,(kev "Return" "\r" 0) ,(x "13u"))
      ("ctrl+Enter" ,(kev "Return" "\r" C) ,(x "13;5u"))
      ("Tab" ,(kev "Tab" "\t" 0) ,(x "9u"))
      ("Backspace" ,(kev "BackSpace" "\b" 0) ,(x "127u"))
      ("KP_1" ,(kev "KP_1" "1" 0 'locks NUM) ,(x "57400;129u"))
      ("KP_Enter" ,(kev "KP_Enter" "\r" 0) ,(x "57414u"))
      ;; modifier keys, with their own bit set on press
      ("Shift_L" ,(kev "Shift_L" "" S) ,(x "57441;2u"))
      ("Shift_R" ,(kev "Shift_R" "" S) ,(x "57447;2u"))
      ("Control_L" ,(kev "Control_L" "" C) ,(x "57442;5u"))
      ("Control_R" ,(kev "Control_R" "" C) ,(x "57448;5u"))
      ("Alt_L" ,(kev "Alt_L" "" A) ,(x "57443;3u"))
      ("Alt_R" ,(kev "Alt_R" "" A) ,(x "57449;3u"))
      ("Super_L" ,(kev "Super_L" "" W) ,(x "57444;9u"))
      ("Super_R" ,(kev "Super_R" "" W) ,(x "57450;9u"))
      ("Hyper_L" ,(kev "Hyper_L" "" 0) ,(x "57445u"))
      ("Meta_L" ,(kev "Meta_L" "" 0) ,(x "57446u"))
      ("Caps_Lock" ,(kev "Caps_Lock" "" 0 'locks CAPS) ,(x "57358;65u"))
      ("Num_Lock" ,(kev "Num_Lock" "" 0 'locks NUM) ,(x "57360;129u"))
      ("ISO_Level3_Shift" ,(kev "ISO_Level3_Shift" "" 0) ,(x "57453u"))
      ("ISO_Level5_Shift" ,(kev "ISO_Level5_Shift" "" 0) ,(x "57454u"))
      ("compose é" ,(kev "eacute" "é" 0 'composed #t) "é")))
  (check-table "all keys + event types" 10
    `(("a release" ,(kev "a" "a" 0 'type R) ,(x "97;1:3u"))
      ("Enter release" ,(kev "Return" "\r" 0 'type R) ,(x "13;1:3u"))
      ("Tab release" ,(kev "Tab" "\t" 0 'type R) ,(x "9;1:3u"))
      ("Backspace release" ,(kev "BackSpace" "\b" 0 'type R) ,(x "127;1:3u"))
      ("Control_L release" ,(kev "Control_L" "" 0 'type R) ,(x "57442;1:3u"))
      ("Shift_L release, other shift held" ,(kev "Shift_L" "" S 'type R) ,(x "57441;2:3u"))))

  ;; 16 (with 8): report associated text
  (check-table "all keys + text" 24
    `(("shift+a" ,(kev "A" "A" S) ,(x "97;2;65u"))
      ("a" ,(kev "a" "a" 0) ,(x "97;;97u"))
      ("é" ,(kev "eacute" "é" 0) ,(x "233;;233u"))
      ("shift+a, two code points" ,(kev "A" "AB" S) ,(x "97;2;65:66u"))
      ("ctrl+a has no text" ,(kev "a" "\x1;" C) ,(x "97;5u"))
      ("alt+a has no text" ,(kev "a" "a" A) ,(x "97;3u"))
      ("Enter has no text" ,(kev "Return" "\r" 0) ,(x "13u"))
      ("Escape has no text" ,(kev "Escape" "\x1b;" 0) ,(x "27u"))
      ("KP_1" ,(kev "KP_1" "1" 0 'locks NUM) ,(x "57400;129;49u"))
      ;; text without a key, as the specification's alt+a on macOS: key 0
      ("text event å" ,(kev "aring" "å" 0 'composed #t) ,(x "0;;229u"))
      ("compose é" ,(kev "eacute" "é" 0 'composed #t 'key "e") ,(x "0;;233u"))))
  (check-table "all flags" 31
    `(("shift+a" ,(kev "A" "A" S) ,(x "97:65;2;65u"))
      ("shift+a repeat" ,(kev "A" "A" S 'type RP) ,(x "97:65;2:2;65u"))
      ("shift+a release" ,(kev "A" "A" S 'type R) ,(x "97:65;2:3u"))
      ("es" ,(kev "Cyrillic_es" "с" 0 'base 99) ,(x "1089::99;;1089u"))
      ("Left" ,(kev "Left" "" 0) ,(x "D"))
      ("Left release" ,(kev "Left" "" 0 'type R) ,(x "1;1:3D"))
      ("compose release" ,(kev "eacute" "é" 0 'composed #t 'type R) #f)))
  (check-table "text without all keys" 16
    `(("a" ,(kev "a" "a" 0) "a")
      ("shift+a" ,(kev "A" "A" S) "A"))))

;;; legacy key encoding (no kitty keyboard flags), recorded from the encoder
;;; before the kitty keyboard protocol was added: it must not change.  A row
;;; is (keysym text shifted-keysym shifted-text (app-cursor app-keypad
;;; newline-mode) results), with one result per entry of legacy-mods.  As
;;; with xkb, Shift selects the shifted keysym and text, and Ctrl turns
;;; ASCII text into a control character.
(let ()
  (define legacy-mods '(0 1 2 4 5 6 3 7 8 12))
  (define (ctrl-text t mods)
    (if (and (logtest mods MOD-CTRL) (= (string-length t) 1)
             (<= 64 (char->integer (string-ref t 0)) 126))
        (string (integer->char (logand (char->integer (string-ref t 0)) 31)))
        t))
  (define legacy-key-table
    '(("a" "a" "A" "A" (#f #f #f) ("a" "A" "\x1B;a" "\x1;" "\x1;" "\x1B;\x1;" "\x1B;A" "\x1B;\x1;" "a" "\x1;"))
    ("i" "i" "I" "I" (#f #f #f) ("i" "I" "\x1B;i" "\t" "\t" "\x1B;\t" "\x1B;I" "\x1B;\t" "i" "\t"))
    ("m" "m" "M" "M" (#f #f #f) ("m" "M" "\x1B;m" "\r" "\r" "\x1B;\r" "\x1B;M" "\x1B;\r" "m" "\r"))
    ("c" "c" "C" "C" (#f #f #f) ("c" "C" "\x1B;c" "\x3;" "\x3;" "\x1B;\x3;" "\x1B;C" "\x1B;\x3;" "c" "\x3;"))
    ("2" "2" "at" "@" (#f #f #f) ("2" "@" "\x1B;2" "\x0;" "\x0;" "\x1B;\x0;" "\x1B;@" "\x1B;\x0;" "2" "\x0;"))
    ("3" "3" "numbersign" "#" (#f #f #f) ("3" "#" "\x1B;3" "\x1B;" "#" "\x1B;\x1B;" "\x1B;#" "\x1B;#" "3" "\x1B;"))
    ("8" "8" "asterisk" "*" (#f #f #f) ("8" "*" "\x1B;8" "\x7F;" "*" "\x1B;\x7F;" "\x1B;*" "\x1B;*" "8" "\x7F;"))
    ("0" "0" "parenright" ")" (#f #f #f) ("0" ")" "\x1B;0" "0" ")" "\x1B;0" "\x1B;)" "\x1B;)" "0" "0"))
    ("semicolon" ";" "colon" ":" (#f #f #f) (";" ":" "\x1B;;" ";" ":" "\x1B;;" "\x1B;:" "\x1B;:" ";" ";"))
    ("bracketleft" "[" "braceleft" "{" (#f #f #f) ("[" "{" "\x1B;[" "\x1B;" "\x1B;" "\x1B;\x1B;" "\x1B;{" "\x1B;\x1B;" "[" "\x1B;"))
    ("slash" "/" "question" "?" (#f #f #f) ("/" "?" "\x1B;/" "\x1F;" "\x7F;" "\x1B;\x1F;" "\x1B;?" "\x1B;\x7F;" "/" "\x1F;"))
    ("grave" "`" "asciitilde" "~" (#f #f #f) ("`" "~" "\x1B;`" "\x0;" "\x1E;" "\x1B;\x0;" "\x1B;~" "\x1B;\x1E;" "`" "\x0;"))
    ("space" " " "space" " " (#f #f #f) (" " " " "\x1B; " "\x0;" "\x0;" "\x1B;\x0;" "\x1B; " "\x1B;\x0;" " " "\x0;"))
    ("eacute" "é" "Eacute" "É" (#f #f #f) ("é" "É" "\x1B;é" "é" "É" "\x1B;é" "\x1B;É" "\x1B;É" "é" "é"))
    ("Return" "\r" "Return" "\r" (#f #f #f) ("\r" "\r" "\x1B;\r" "\r" "\r" "\x1B;\r" "\x1B;\r" "\x1B;\r" "\r" "\r"))
    ("Return" "\r" "Return" "\r" (#t #f #f) ("\r" "\r" "\x1B;\r" "\r" "\r" "\x1B;\r" "\x1B;\r" "\x1B;\r" "\r" "\r"))
    ("Return" "\r" "Return" "\r" (#f #t #f) ("\r" "\r" "\x1B;\r" "\r" "\r" "\x1B;\r" "\x1B;\r" "\x1B;\r" "\r" "\r"))
    ("Return" "\r" "Return" "\r" (#f #f #t) ("\r\n" "\r\n" "\x1B;\r\n" "\r\n" "\r\n" "\x1B;\r\n" "\x1B;\r\n" "\x1B;\r\n" "\r\n" "\r\n"))
    ("KP_Enter" "\r" "KP_Enter" "\r" (#f #f #f) ("\r" "\r" "\x1B;\r" "\r" "\r" "\x1B;\r" "\x1B;\r" "\x1B;\r" "\r" "\r"))
    ("KP_Enter" "\r" "KP_Enter" "\r" (#t #f #f) ("\r" "\r" "\x1B;\r" "\r" "\r" "\x1B;\r" "\x1B;\r" "\x1B;\r" "\r" "\r"))
    ("KP_Enter" "\r" "KP_Enter" "\r" (#f #t #f) ("\x1B;OM" "\r" "\x1B;\r" "\r" "\r" "\x1B;\r" "\x1B;\r" "\x1B;\r" "\r" "\r"))
    ("KP_Enter" "\r" "KP_Enter" "\r" (#f #f #t) ("\r\n" "\r\n" "\x1B;\r\n" "\r\n" "\r\n" "\x1B;\r\n" "\x1B;\r\n" "\x1B;\r\n" "\r\n" "\r\n"))
    ("Tab" "\t" "ISO_Left_Tab" "" (#f #f #f) ("\t" "\x1B;[Z" "\x1B;\t" "\t" "\x1B;[Z" "\x1B;\t" "\x1B;[Z" "\x1B;[Z" "\t" "\t"))
    ("BackSpace" "\b" "BackSpace" "\b" (#f #f #f) ("\x7F;" "\x7F;" "\x1B;\x7F;" "\b" "\b" "\x1B;\b" "\x1B;\x7F;" "\x1B;\b" "\x7F;" "\b"))
    ("Escape" "\x1B;" "Escape" "\x1B;" (#f #f #f) ("\x1B;" "\x1B;" "\x1B;\x1B;" "\x1B;" "\x1B;" "\x1B;\x1B;" "\x1B;\x1B;" "\x1B;\x1B;" "\x1B;" "\x1B;"))
    ("Up" "" "Up" "" (#f #f #f) ("\x1B;[A" "\x1B;[1;2A" "\x1B;[1;3A" "\x1B;[1;5A" "\x1B;[1;6A" "\x1B;[1;7A" "\x1B;[1;4A" "\x1B;[1;8A" "\x1B;[1;9A" "\x1B;[1;13A"))
    ("Up" "" "Up" "" (#t #f #f) ("\x1B;OA" "\x1B;[1;2A" "\x1B;[1;3A" "\x1B;[1;5A" "\x1B;[1;6A" "\x1B;[1;7A" "\x1B;[1;4A" "\x1B;[1;8A" "\x1B;[1;9A" "\x1B;[1;13A"))
    ("Up" "" "Up" "" (#f #t #f) ("\x1B;[A" "\x1B;[1;2A" "\x1B;[1;3A" "\x1B;[1;5A" "\x1B;[1;6A" "\x1B;[1;7A" "\x1B;[1;4A" "\x1B;[1;8A" "\x1B;[1;9A" "\x1B;[1;13A"))
    ("Up" "" "Up" "" (#f #f #t) ("\x1B;[A" "\x1B;[1;2A" "\x1B;[1;3A" "\x1B;[1;5A" "\x1B;[1;6A" "\x1B;[1;7A" "\x1B;[1;4A" "\x1B;[1;8A" "\x1B;[1;9A" "\x1B;[1;13A"))
    ("Down" "" "Down" "" (#f #f #f) ("\x1B;[B" "\x1B;[1;2B" "\x1B;[1;3B" "\x1B;[1;5B" "\x1B;[1;6B" "\x1B;[1;7B" "\x1B;[1;4B" "\x1B;[1;8B" "\x1B;[1;9B" "\x1B;[1;13B"))
    ("Down" "" "Down" "" (#t #f #f) ("\x1B;OB" "\x1B;[1;2B" "\x1B;[1;3B" "\x1B;[1;5B" "\x1B;[1;6B" "\x1B;[1;7B" "\x1B;[1;4B" "\x1B;[1;8B" "\x1B;[1;9B" "\x1B;[1;13B"))
    ("Down" "" "Down" "" (#f #t #f) ("\x1B;[B" "\x1B;[1;2B" "\x1B;[1;3B" "\x1B;[1;5B" "\x1B;[1;6B" "\x1B;[1;7B" "\x1B;[1;4B" "\x1B;[1;8B" "\x1B;[1;9B" "\x1B;[1;13B"))
    ("Down" "" "Down" "" (#f #f #t) ("\x1B;[B" "\x1B;[1;2B" "\x1B;[1;3B" "\x1B;[1;5B" "\x1B;[1;6B" "\x1B;[1;7B" "\x1B;[1;4B" "\x1B;[1;8B" "\x1B;[1;9B" "\x1B;[1;13B"))
    ("Left" "" "Left" "" (#f #f #f) ("\x1B;[D" "\x1B;[1;2D" "\x1B;[1;3D" "\x1B;[1;5D" "\x1B;[1;6D" "\x1B;[1;7D" "\x1B;[1;4D" "\x1B;[1;8D" "\x1B;[1;9D" "\x1B;[1;13D"))
    ("Left" "" "Left" "" (#t #f #f) ("\x1B;OD" "\x1B;[1;2D" "\x1B;[1;3D" "\x1B;[1;5D" "\x1B;[1;6D" "\x1B;[1;7D" "\x1B;[1;4D" "\x1B;[1;8D" "\x1B;[1;9D" "\x1B;[1;13D"))
    ("Left" "" "Left" "" (#f #t #f) ("\x1B;[D" "\x1B;[1;2D" "\x1B;[1;3D" "\x1B;[1;5D" "\x1B;[1;6D" "\x1B;[1;7D" "\x1B;[1;4D" "\x1B;[1;8D" "\x1B;[1;9D" "\x1B;[1;13D"))
    ("Left" "" "Left" "" (#f #f #t) ("\x1B;[D" "\x1B;[1;2D" "\x1B;[1;3D" "\x1B;[1;5D" "\x1B;[1;6D" "\x1B;[1;7D" "\x1B;[1;4D" "\x1B;[1;8D" "\x1B;[1;9D" "\x1B;[1;13D"))
    ("Right" "" "Right" "" (#f #f #f) ("\x1B;[C" "\x1B;[1;2C" "\x1B;[1;3C" "\x1B;[1;5C" "\x1B;[1;6C" "\x1B;[1;7C" "\x1B;[1;4C" "\x1B;[1;8C" "\x1B;[1;9C" "\x1B;[1;13C"))
    ("Right" "" "Right" "" (#t #f #f) ("\x1B;OC" "\x1B;[1;2C" "\x1B;[1;3C" "\x1B;[1;5C" "\x1B;[1;6C" "\x1B;[1;7C" "\x1B;[1;4C" "\x1B;[1;8C" "\x1B;[1;9C" "\x1B;[1;13C"))
    ("Right" "" "Right" "" (#f #t #f) ("\x1B;[C" "\x1B;[1;2C" "\x1B;[1;3C" "\x1B;[1;5C" "\x1B;[1;6C" "\x1B;[1;7C" "\x1B;[1;4C" "\x1B;[1;8C" "\x1B;[1;9C" "\x1B;[1;13C"))
    ("Right" "" "Right" "" (#f #f #t) ("\x1B;[C" "\x1B;[1;2C" "\x1B;[1;3C" "\x1B;[1;5C" "\x1B;[1;6C" "\x1B;[1;7C" "\x1B;[1;4C" "\x1B;[1;8C" "\x1B;[1;9C" "\x1B;[1;13C"))
    ("Home" "" "Home" "" (#f #f #f) ("\x1B;[H" "\x1B;[1;2H" "\x1B;[1;3H" "\x1B;[1;5H" "\x1B;[1;6H" "\x1B;[1;7H" "\x1B;[1;4H" "\x1B;[1;8H" "\x1B;[1;9H" "\x1B;[1;13H"))
    ("Home" "" "Home" "" (#t #f #f) ("\x1B;OH" "\x1B;[1;2H" "\x1B;[1;3H" "\x1B;[1;5H" "\x1B;[1;6H" "\x1B;[1;7H" "\x1B;[1;4H" "\x1B;[1;8H" "\x1B;[1;9H" "\x1B;[1;13H"))
    ("Home" "" "Home" "" (#f #t #f) ("\x1B;[H" "\x1B;[1;2H" "\x1B;[1;3H" "\x1B;[1;5H" "\x1B;[1;6H" "\x1B;[1;7H" "\x1B;[1;4H" "\x1B;[1;8H" "\x1B;[1;9H" "\x1B;[1;13H"))
    ("Home" "" "Home" "" (#f #f #t) ("\x1B;[H" "\x1B;[1;2H" "\x1B;[1;3H" "\x1B;[1;5H" "\x1B;[1;6H" "\x1B;[1;7H" "\x1B;[1;4H" "\x1B;[1;8H" "\x1B;[1;9H" "\x1B;[1;13H"))
    ("End" "" "End" "" (#f #f #f) ("\x1B;[F" "\x1B;[1;2F" "\x1B;[1;3F" "\x1B;[1;5F" "\x1B;[1;6F" "\x1B;[1;7F" "\x1B;[1;4F" "\x1B;[1;8F" "\x1B;[1;9F" "\x1B;[1;13F"))
    ("End" "" "End" "" (#t #f #f) ("\x1B;OF" "\x1B;[1;2F" "\x1B;[1;3F" "\x1B;[1;5F" "\x1B;[1;6F" "\x1B;[1;7F" "\x1B;[1;4F" "\x1B;[1;8F" "\x1B;[1;9F" "\x1B;[1;13F"))
    ("End" "" "End" "" (#f #t #f) ("\x1B;[F" "\x1B;[1;2F" "\x1B;[1;3F" "\x1B;[1;5F" "\x1B;[1;6F" "\x1B;[1;7F" "\x1B;[1;4F" "\x1B;[1;8F" "\x1B;[1;9F" "\x1B;[1;13F"))
    ("End" "" "End" "" (#f #f #t) ("\x1B;[F" "\x1B;[1;2F" "\x1B;[1;3F" "\x1B;[1;5F" "\x1B;[1;6F" "\x1B;[1;7F" "\x1B;[1;4F" "\x1B;[1;8F" "\x1B;[1;9F" "\x1B;[1;13F"))
    ("KP_Begin" "" "KP_Begin" "" (#f #f #f) ("\x1B;[E" "\x1B;[1;2E" "\x1B;[1;3E" "\x1B;[1;5E" "\x1B;[1;6E" "\x1B;[1;7E" "\x1B;[1;4E" "\x1B;[1;8E" "\x1B;[1;9E" "\x1B;[1;13E"))
    ("KP_Begin" "" "KP_Begin" "" (#t #f #f) ("\x1B;OE" "\x1B;[1;2E" "\x1B;[1;3E" "\x1B;[1;5E" "\x1B;[1;6E" "\x1B;[1;7E" "\x1B;[1;4E" "\x1B;[1;8E" "\x1B;[1;9E" "\x1B;[1;13E"))
    ("KP_Begin" "" "KP_Begin" "" (#f #t #f) ("\x1B;[E" "\x1B;[1;2E" "\x1B;[1;3E" "\x1B;[1;5E" "\x1B;[1;6E" "\x1B;[1;7E" "\x1B;[1;4E" "\x1B;[1;8E" "\x1B;[1;9E" "\x1B;[1;13E"))
    ("KP_Begin" "" "KP_Begin" "" (#f #f #t) ("\x1B;[E" "\x1B;[1;2E" "\x1B;[1;3E" "\x1B;[1;5E" "\x1B;[1;6E" "\x1B;[1;7E" "\x1B;[1;4E" "\x1B;[1;8E" "\x1B;[1;9E" "\x1B;[1;13E"))
    ("Insert" "" "Insert" "" (#f #f #f) ("\x1B;[2~" "\x1B;[2;2~" "\x1B;[2;3~" "\x1B;[2;5~" "\x1B;[2;6~" "\x1B;[2;7~" "\x1B;[2;4~" "\x1B;[2;8~" "\x1B;[2;9~" "\x1B;[2;13~"))
    ("Delete" "" "Delete" "" (#f #f #f) ("\x1B;[3~" "\x1B;[3;2~" "\x1B;[3;3~" "\x1B;[3;5~" "\x1B;[3;6~" "\x1B;[3;7~" "\x1B;[3;4~" "\x1B;[3;8~" "\x1B;[3;9~" "\x1B;[3;13~"))
    ("Prior" "" "Prior" "" (#f #f #f) ("\x1B;[5~" "\x1B;[5;2~" "\x1B;[5;3~" "\x1B;[5;5~" "\x1B;[5;6~" "\x1B;[5;7~" "\x1B;[5;4~" "\x1B;[5;8~" "\x1B;[5;9~" "\x1B;[5;13~"))
    ("Next" "" "Next" "" (#f #f #f) ("\x1B;[6~" "\x1B;[6;2~" "\x1B;[6;3~" "\x1B;[6;5~" "\x1B;[6;6~" "\x1B;[6;7~" "\x1B;[6;4~" "\x1B;[6;8~" "\x1B;[6;9~" "\x1B;[6;13~"))
    ("F1" "" "F1" "" (#f #f #f) ("\x1B;OP" "\x1B;[1;2P" "\x1B;[1;3P" "\x1B;[1;5P" "\x1B;[1;6P" "\x1B;[1;7P" "\x1B;[1;4P" "\x1B;[1;8P" "\x1B;[1;9P" "\x1B;[1;13P"))
    ("F2" "" "F2" "" (#f #f #f) ("\x1B;OQ" "\x1B;[1;2Q" "\x1B;[1;3Q" "\x1B;[1;5Q" "\x1B;[1;6Q" "\x1B;[1;7Q" "\x1B;[1;4Q" "\x1B;[1;8Q" "\x1B;[1;9Q" "\x1B;[1;13Q"))
    ("F3" "" "F3" "" (#f #f #f) ("\x1B;OR" "\x1B;[1;2R" "\x1B;[1;3R" "\x1B;[1;5R" "\x1B;[1;6R" "\x1B;[1;7R" "\x1B;[1;4R" "\x1B;[1;8R" "\x1B;[1;9R" "\x1B;[1;13R"))
    ("F4" "" "F4" "" (#f #f #f) ("\x1B;OS" "\x1B;[1;2S" "\x1B;[1;3S" "\x1B;[1;5S" "\x1B;[1;6S" "\x1B;[1;7S" "\x1B;[1;4S" "\x1B;[1;8S" "\x1B;[1;9S" "\x1B;[1;13S"))
    ("F5" "" "F5" "" (#f #f #f) ("\x1B;[15~" "\x1B;[15;2~" "\x1B;[15;3~" "\x1B;[15;5~" "\x1B;[15;6~" "\x1B;[15;7~" "\x1B;[15;4~" "\x1B;[15;8~" "\x1B;[15;9~" "\x1B;[15;13~"))
    ("F6" "" "F6" "" (#f #f #f) ("\x1B;[17~" "\x1B;[17;2~" "\x1B;[17;3~" "\x1B;[17;5~" "\x1B;[17;6~" "\x1B;[17;7~" "\x1B;[17;4~" "\x1B;[17;8~" "\x1B;[17;9~" "\x1B;[17;13~"))
    ("F7" "" "F7" "" (#f #f #f) ("\x1B;[18~" "\x1B;[18;2~" "\x1B;[18;3~" "\x1B;[18;5~" "\x1B;[18;6~" "\x1B;[18;7~" "\x1B;[18;4~" "\x1B;[18;8~" "\x1B;[18;9~" "\x1B;[18;13~"))
    ("F8" "" "F8" "" (#f #f #f) ("\x1B;[19~" "\x1B;[19;2~" "\x1B;[19;3~" "\x1B;[19;5~" "\x1B;[19;6~" "\x1B;[19;7~" "\x1B;[19;4~" "\x1B;[19;8~" "\x1B;[19;9~" "\x1B;[19;13~"))
    ("F9" "" "F9" "" (#f #f #f) ("\x1B;[20~" "\x1B;[20;2~" "\x1B;[20;3~" "\x1B;[20;5~" "\x1B;[20;6~" "\x1B;[20;7~" "\x1B;[20;4~" "\x1B;[20;8~" "\x1B;[20;9~" "\x1B;[20;13~"))
    ("F10" "" "F10" "" (#f #f #f) ("\x1B;[21~" "\x1B;[21;2~" "\x1B;[21;3~" "\x1B;[21;5~" "\x1B;[21;6~" "\x1B;[21;7~" "\x1B;[21;4~" "\x1B;[21;8~" "\x1B;[21;9~" "\x1B;[21;13~"))
    ("F11" "" "F11" "" (#f #f #f) ("\x1B;[23~" "\x1B;[23;2~" "\x1B;[23;3~" "\x1B;[23;5~" "\x1B;[23;6~" "\x1B;[23;7~" "\x1B;[23;4~" "\x1B;[23;8~" "\x1B;[23;9~" "\x1B;[23;13~"))
    ("F12" "" "F12" "" (#f #f #f) ("\x1B;[24~" "\x1B;[24;2~" "\x1B;[24;3~" "\x1B;[24;5~" "\x1B;[24;6~" "\x1B;[24;7~" "\x1B;[24;4~" "\x1B;[24;8~" "\x1B;[24;9~" "\x1B;[24;13~"))
    ("F13" "" "F13" "" (#f #f #f) ("\x1B;[25~" "\x1B;[25;2~" "\x1B;[25;3~" "\x1B;[25;5~" "\x1B;[25;6~" "\x1B;[25;7~" "\x1B;[25;4~" "\x1B;[25;8~" "\x1B;[25;9~" "\x1B;[25;13~"))
    ("F20" "" "F20" "" (#f #f #f) ("\x1B;[34~" "\x1B;[34;2~" "\x1B;[34;3~" "\x1B;[34;5~" "\x1B;[34;6~" "\x1B;[34;7~" "\x1B;[34;4~" "\x1B;[34;8~" "\x1B;[34;9~" "\x1B;[34;13~"))
    ("KP_1" "1" "KP_1" "1" (#f #f #f) ("1" "1" "\x1B;1" "1" "1" "\x1B;1" "\x1B;1" "\x1B;1" "1" "1"))
    ("KP_1" "1" "KP_1" "1" (#t #f #f) ("1" "1" "\x1B;1" "1" "1" "\x1B;1" "\x1B;1" "\x1B;1" "1" "1"))
    ("KP_1" "1" "KP_1" "1" (#f #t #f) ("\x1B;Oq" "1" "\x1B;1" "1" "1" "\x1B;1" "\x1B;1" "\x1B;1" "1" "1"))
    ("KP_1" "1" "KP_1" "1" (#f #f #t) ("1" "1" "\x1B;1" "1" "1" "\x1B;1" "\x1B;1" "\x1B;1" "1" "1"))
    ("KP_End" "" "KP_End" "" (#f #f #f) ("\x1B;[F" "\x1B;[1;2F" "\x1B;[1;3F" "\x1B;[1;5F" "\x1B;[1;6F" "\x1B;[1;7F" "\x1B;[1;4F" "\x1B;[1;8F" "\x1B;[1;9F" "\x1B;[1;13F"))
    ("KP_End" "" "KP_End" "" (#t #f #f) ("\x1B;OF" "\x1B;[1;2F" "\x1B;[1;3F" "\x1B;[1;5F" "\x1B;[1;6F" "\x1B;[1;7F" "\x1B;[1;4F" "\x1B;[1;8F" "\x1B;[1;9F" "\x1B;[1;13F"))
    ("KP_End" "" "KP_End" "" (#f #t #f) ("\x1B;[F" "\x1B;[1;2F" "\x1B;[1;3F" "\x1B;[1;5F" "\x1B;[1;6F" "\x1B;[1;7F" "\x1B;[1;4F" "\x1B;[1;8F" "\x1B;[1;9F" "\x1B;[1;13F"))
    ("KP_End" "" "KP_End" "" (#f #f #t) ("\x1B;[F" "\x1B;[1;2F" "\x1B;[1;3F" "\x1B;[1;5F" "\x1B;[1;6F" "\x1B;[1;7F" "\x1B;[1;4F" "\x1B;[1;8F" "\x1B;[1;9F" "\x1B;[1;13F"))
    ("KP_Up" "" "KP_Up" "" (#f #f #f) ("\x1B;[A" "\x1B;[1;2A" "\x1B;[1;3A" "\x1B;[1;5A" "\x1B;[1;6A" "\x1B;[1;7A" "\x1B;[1;4A" "\x1B;[1;8A" "\x1B;[1;9A" "\x1B;[1;13A"))
    ("KP_Up" "" "KP_Up" "" (#t #f #f) ("\x1B;OA" "\x1B;[1;2A" "\x1B;[1;3A" "\x1B;[1;5A" "\x1B;[1;6A" "\x1B;[1;7A" "\x1B;[1;4A" "\x1B;[1;8A" "\x1B;[1;9A" "\x1B;[1;13A"))
    ("KP_Up" "" "KP_Up" "" (#f #t #f) ("\x1B;[A" "\x1B;[1;2A" "\x1B;[1;3A" "\x1B;[1;5A" "\x1B;[1;6A" "\x1B;[1;7A" "\x1B;[1;4A" "\x1B;[1;8A" "\x1B;[1;9A" "\x1B;[1;13A"))
    ("KP_Up" "" "KP_Up" "" (#f #f #t) ("\x1B;[A" "\x1B;[1;2A" "\x1B;[1;3A" "\x1B;[1;5A" "\x1B;[1;6A" "\x1B;[1;7A" "\x1B;[1;4A" "\x1B;[1;8A" "\x1B;[1;9A" "\x1B;[1;13A"))
    ("KP_Add" "+" "KP_Add" "+" (#f #f #f) ("+" "+" "\x1B;+" "+" "+" "\x1B;+" "\x1B;+" "\x1B;+" "+" "+"))
    ("KP_Add" "+" "KP_Add" "+" (#t #f #f) ("+" "+" "\x1B;+" "+" "+" "\x1B;+" "\x1B;+" "\x1B;+" "+" "+"))
    ("KP_Add" "+" "KP_Add" "+" (#f #t #f) ("\x1B;Ok" "+" "\x1B;+" "+" "+" "\x1B;+" "\x1B;+" "\x1B;+" "+" "+"))
    ("KP_Add" "+" "KP_Add" "+" (#f #f #t) ("+" "+" "\x1B;+" "+" "+" "\x1B;+" "\x1B;+" "\x1B;+" "+" "+"))
    ("KP_Decimal" "." "KP_Decimal" "." (#f #f #f) ("." "." "\x1B;." "." "." "\x1B;." "\x1B;." "\x1B;." "." "."))
    ("KP_Decimal" "." "KP_Decimal" "." (#t #f #f) ("." "." "\x1B;." "." "." "\x1B;." "\x1B;." "\x1B;." "." "."))
    ("KP_Decimal" "." "KP_Decimal" "." (#f #t #f) ("\x1B;On" "." "\x1B;." "." "." "\x1B;." "\x1B;." "\x1B;." "." "."))
    ("KP_Decimal" "." "KP_Decimal" "." (#f #f #t) ("." "." "\x1B;." "." "." "\x1B;." "\x1B;." "\x1B;." "." "."))
    ("Shift_L" "" "Shift_L" "" (#f #f #f) (#f #f #f #f #f #f #f #f #f #f))
    ("Control_L" "" "Control_L" "" (#f #f #f) (#f #f #f #f #f #f #f #f #f #f))
    ("Menu" "" "Menu" "" (#f #f #f) (#f #f #f #f #f #f #f #f #f #f))
    ("Caps_Lock" "" "Caps_Lock" "" (#f #f #f) (#f #f #f #f #f #f #f #f #f #f))))
  (for-each
   (lambda (row)
     (let ([modes (list-ref row 4)])
       (for-each
        (lambda (mods expected)
          (let* ([shift (logtest mods MOD-SHIFT)]
                 [sym (if shift (list-ref row 2) (list-ref row 0))]
                 [text (ctrl-text (if shift (list-ref row 3) (list-ref row 1)) mods)])
            (check (format "legacy key ~a mods ~a modes ~a" (car row) mods modes)
                   expected
                   (apply encode-key (make-key-event (keysym-by-name sym) text mods) modes))))
        legacy-mods (list-ref row 5))))
   legacy-key-table)
  ;; kitty-keyboard-legacy-csi-u changes none of these, except keys that
  ;; sent nothing
  (for-each
   (lambda (row)
     (let ([modes (list-ref row 4)])
       (for-each
        (lambda (mods expected)
          (let* ([shift (logtest mods MOD-SHIFT)]
                 [sym (if shift (list-ref row 2) (list-ref row 0))]
                 [text (ctrl-text (if shift (list-ref row 3) (list-ref row 1)) mods)])
            (when expected
              (check (format "legacy key ~a mods ~a modes ~a, legacy CSI u" (car row) mods modes)
                     expected
                     (apply encode-key (make-key-event (keysym-by-name sym) text mods)
                            (append modes (list 0 #t)))))))
        legacy-mods (list-ref row 5))))
   legacy-key-table))

;;; keys without a legacy encoding: nothing by default, CSI u (as kitty sends
;;; with flags 0) with kitty-keyboard-legacy-csi-u
(let ()
  (define (sym name) (xkb_keysym_from_name name 0))     ; case-sensitive
  (define (enc name mods csi-u . type)
    (encode-key (let ([ev (make-key-event (sym name) "" mods)])
                  (if (pair? type) (key-event-with-type ev (car type)) ev))
                #f #f #f 0 csi-u))
  (for-each
   (lambda (k)
     (let ([name (car k)] [mods (cadr k)] [bytes (caddr k)])
       (check (format "legacy CSI u: ~a mods ~a, off" name mods) #f (enc name mods #f))
       (check (format "legacy CSI u: ~a mods ~a" name mods) bytes (enc name mods #t))))
   `(("XF86AudioPlay" 0 "\x1b;[57428u") ("XF86AudioMute" 0 "\x1b;[57440u")
     ("XF86AudioRaiseVolume" ,MOD-CTRL "\x1b;[57439;5u") ("XF86AudioNext" ,MOD-SHIFT "\x1b;[57435;2u")
     ("Menu" 0 "\x1b;[29~") ("Menu" ,MOD-ALT "\x1b;[29;3~")
     ("Print" 0 "\x1b;[57361u") ("Pause" 0 "\x1b;[57362u") ("Scroll_Lock" 0 "\x1b;[57359u")
     ("F21" 0 "\x1b;[57384u") ("F35" 0 "\x1b;[57398u") ("F24" ,MOD-SHIFT "\x1b;[57387;2u")
     ("F30" ,(logior MOD-CTRL MOD-ALT) "\x1b;[57393;7u") ("F21" ,MOD-HYPER "\x1b;[57384;17u")))
  (check "legacy CSI u: no release" #f (enc "XF86AudioPlay" 0 #t KEY-RELEASE))
  (check "legacy CSI u: repeat" "\x1b;[57428u" (enc "XF86AudioPlay" 0 #t KEY-REPEAT))
  (for-each
   (lambda (name)
     (check (format "legacy CSI u: modifier key ~a" name) #f (enc name 0 #t)))
   '("Shift_L" "Control_R" "Alt_L" "Super_L" "Hyper_L" "Meta_R" "Caps_Lock" "Num_Lock"
     "ISO_Level3_Shift"))
  (check "legacy CSI u: F13 keeps its legacy code" "\x1b;[25~" (enc "F13" 0 #t))
  (check "legacy CSI u: F20 keeps its legacy code" "\x1b;[34;5~" (enc "F20" MOD-CTRL #t))
  (check "legacy CSI u: Up keeps its legacy code" "\x1b;[1;5A" (enc "Up" MOD-CTRL #t))
  (check "legacy CSI u: a key without a kitty number" #f (enc "XF86Calculator" 0 #t)))

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
  ;; underline colors: every style is drawn in the underline color when the
  ;; cell has one, otherwise in the foreground color
  (let* ([t (make-term 6 20)]
         [r (make-renderer f 3 3 1.0 #f #f #x444444 #t)]
         [cw (font-cell-width f)] [chh (font-cell-height f)]
         [colors-in (lambda (row c0 c1)
                      (let loop ([y (+ 3 (* row chh))] [x (+ 3 (* c0 cw))] [acc '()])
                        (cond [(= y (+ 3 (* (+ row 1) chh))) acc]
                              [(= x (+ 3 (* c1 cw))) (loop (+ y 1) (+ 3 (* c0 cw)) acc)]
                              [else
                               (let ([p (logand #xFFFFFF (foreign-ref 'unsigned-32 (renderer-pixels r)
                                                                      (* 4 (+ x (* y (renderer-width r))))))])
                                 (loop y (+ x 1) (if (memv p acc) acc (cons p acc))))])))]
         [styles (lambda (ul)
                   (apply string-append
                          (map (lambda (s) (string-append (esc (format "[4:~a~am" s ul)) "  " (esc "[24m") " "))
                               '(1 2 3 4 5))))])
    (renderer-resize! r (+ 6 (* 20 cw)) (+ 6 (* 6 chh)))
    (feed t (esc "[38:2::255:0:0m") (styles ";58:2::0:200:0") "\r\n" (styles ";59") "\r\n"
          (styles ";58:5:21") "\r\n" (esc "[8;4;58:2::0:200:0m") "  " (esc "[m"))
    (renderer-render! r t #t #t (lambda (a) '()) #f)
    (check "ul color: render = fresh" #t (equal? (snapshot r) (fresh-render t)))
    (for-each
     (lambda (s)
       (let ([c0 (* 3 (- s 1))])
         (check (format "ul color: style ~a in the underline color" s) '(#x00C800 #x000000)
                (list-sort > (colors-in 0 c0 (+ c0 2))))
         (check (format "ul color: style ~a in the foreground" s) '(#xFF0000 #x000000)
                (list-sort > (colors-in 1 c0 (+ c0 2))))
         (check (format "ul color: style ~a in a palette color" s) '(#x0000FF #x000000)
                (list-sort > (colors-in 2 c0 (+ c0 2))))))
     '(1 2 3 4 5))
    (check "ul color: hidden cells show no underline color" #f (memv #x00C800 (colors-in 3 0 2)))
    ;; only the underline color changes: the row is redrawn
    (feed t (esc "[1;1H") (esc "[4;58:2::0:0:255m") "  " (esc "[2;7H") (esc "[4:3;58:5:21m") "  ")
    (renderer-render! r t #t #t (lambda (a) '()) #f)
    (check "ul color: changed = fresh" #t (equal? (snapshot r) (fresh-render t)))
    (check "ul color: changed color drawn" '(#x0000FF #x000000) (list-sort > (colors-in 0 0 2)))
    (feed t (esc "[1;1H") (esc "[59m") "  ")
    (renderer-render! r t #t #t (lambda (a) '()) #f)
    (check "ul color: reset = fresh" #t (equal? (snapshot r) (fresh-render t)))
    (feed t "\r\n\r\n\r\n\r\n")
    (renderer-render! r t #t #t (lambda (a) '()) #f)
    (check "ul color: scrolled = fresh" #t (equal? (snapshot r) (fresh-render t)))
    (renderer-free! r))
  ;; a hovered link is underlined through the highlights
  (let* ([t (make-term 6 20)]
         [r (make-renderer f 3 3 1.0 #f #f #x444444 #t)]
         [hl (lambda (a) (if (= a (terminal-abs-row t 1)) '((2 6 link) (8 10 link)) '()))]
         [fresh (lambda (hl)
                  (let ([r (make-renderer f 3 3 1.0 #f #f #x444444 #t)])
                    (renderer-resize! r (+ 6 (* 20 (font-cell-width f))) (+ 6 (* 6 (font-cell-height f))))
                    (renderer-render! r t #t #t hl #f)
                    (let ([s (snapshot r)]) (renderer-free! r) s)))])
    (renderer-resize! r (+ 6 (* 20 (font-cell-width f))) (+ 6 (* 6 (font-cell-height f))))
    (feed t "row 0\r\n" (osc8 "id=a" "http://a/") "ab" (osc8 "" "") "linked 日本 text")
    (renderer-render! r t #t #t (lambda (a) '()) #f)
    (let ([before (snapshot r)])
      (renderer-render! r t #t #t hl #f)
      (check "hovered link = fresh" #t (equal? (snapshot r) (fresh hl)))
      (check "hovered link drawn" #f (equal? (snapshot r) before))
      (renderer-render! r t #t #t (lambda (a) '()) #f)
      (check "hover ends = fresh" #t (equal? (snapshot r) before)))
    (renderer-free! r))
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
