;;; Character grid with scrollback and reflow.
;;;
;;; A line stores its cells in an fxvector, three fixnums per cell:
;;;   [codepoint | attrs << 21, foreground color, background color]
;;; Code point 0 marks a never-written (empty) cell.  Colors are 0-255 for
;;; palette entries, COLOR-FG / COLOR-BG for the defaults, or
;;; COLOR-RGB | #xRRGGBB for direct colors.  Combining characters are kept in
;;; a per-line table mapping a column to a string.
(library (chezterm grid)
  (export ATTR-BOLD ATTR-DIM ATTR-ITALIC ATTR-UNDERLINE-MASK ATTR-UNDERLINE-SHIFT
          ATTR-BLINK ATTR-REVERSE ATTR-HIDDEN ATTR-STRIKE ATTR-WIDE ATTR-SPACER
          UL-NONE UL-SINGLE UL-DOUBLE UL-CURLY UL-DOTTED UL-DASHED
          COLOR-FG COLOR-BG COLOR-CURSOR COLOR-RGB
          cell-ch cell-attrs cell-fg cell-bg cell-set! cell-copy! cell-empty?
          make-line line? line-cells line-cols line-wrapped line-wrapped-set!
          line-extra line-extra-set! line-clear! line-fill! line-content-length
          line-copy
          make-grid grid? grid-rows grid-cols grid-line grid-screen-line
          grid-hist-count grid-hist-capacity grid-scroll-counter
          grid-scroll-up! grid-scroll-down! grid-clear-history! grid-resize!
          grid-set-hist-capacity!)
  (import (chezscheme))

  (define ATTR-BOLD 1)
  (define ATTR-DIM 2)
  (define ATTR-ITALIC 4)
  (define ATTR-UNDERLINE-SHIFT 3)
  (define ATTR-UNDERLINE-MASK (fxsll 7 3))
  (define ATTR-BLINK 64)
  (define ATTR-REVERSE 128)
  (define ATTR-HIDDEN 256)
  (define ATTR-STRIKE 512)
  (define ATTR-WIDE 1024)      ; first half of a double-width character
  (define ATTR-SPACER 2048)    ; second half of a double-width character

  (define UL-NONE 0) (define UL-SINGLE 1) (define UL-DOUBLE 2)
  (define UL-CURLY 3) (define UL-DOTTED 4) (define UL-DASHED 5)

  (define COLOR-FG 256)
  (define COLOR-BG 257)
  (define COLOR-CURSOR 258)
  (define COLOR-RGB #x1000000)

  (define-syntax cell-ch
    (syntax-rules () [(_ v i) (fxand (fxvector-ref v (fx* 3 i)) #x1FFFFF)]))
  (define-syntax cell-attrs
    (syntax-rules () [(_ v i) (fxsrl (fxvector-ref v (fx* 3 i)) 21)]))
  (define-syntax cell-fg
    (syntax-rules () [(_ v i) (fxvector-ref v (fx+ 1 (fx* 3 i)))]))
  (define-syntax cell-bg
    (syntax-rules () [(_ v i) (fxvector-ref v (fx+ 2 (fx* 3 i)))]))
  (define-syntax cell-empty?
    (syntax-rules () [(_ v i) (fx= 0 (fxvector-ref v (fx* 3 i)))]))

  (define (cell-set! v i ch attrs fg bg)
    (let ([k (fx* 3 i)])
      (fxvector-set! v k (fxior ch (fxsll attrs 21)))
      (fxvector-set! v (fx+ k 1) fg)
      (fxvector-set! v (fx+ k 2) bg)))

  (define (cell-copy! src si dst di)
    (let ([a (fx* 3 si)] [b (fx* 3 di)])
      (fxvector-set! dst b (fxvector-ref src a))
      (fxvector-set! dst (fx+ b 1) (fxvector-ref src (fx+ a 1)))
      (fxvector-set! dst (fx+ b 2) (fxvector-ref src (fx+ a 2)))))

  ;;; Lines ---------------------------------------------------------------

  (define-record-type line
    (fields (mutable cells) (mutable wrapped) (mutable extra))
    (protocol
     (lambda (new)
       (lambda (cols)
         (let ([v (make-fxvector (fx* 3 cols) 0)])
           (do ([i 0 (fx+ i 1)]) ((fx= i cols))
             (fxvector-set! v (fx+ 1 (fx* 3 i)) COLOR-FG)
             (fxvector-set! v (fx+ 2 (fx* 3 i)) COLOR-BG))
           (new v #f #f))))))

  (define (line-cols l) (fxquotient (fxvector-length (line-cells l)) 3))

  ;; Clear cells [from, to) to empty with background BG.
  (define (line-fill! l from to bg)
    (let ([v (line-cells l)])
      (do ([i from (fx+ i 1)]) ((fx>= i to))
        (let ([k (fx* 3 i)])
          (fxvector-set! v k 0)
          (fxvector-set! v (fx+ k 1) COLOR-FG)
          (fxvector-set! v (fx+ k 2) bg)))
      (let ([ex (line-extra l)])
        (when ex
          (do ([i from (fx+ i 1)]) ((fx>= i to))
            (hashtable-delete! ex i))))))

  (define (line-clear! l bg)
    (line-fill! l 0 (line-cols l) bg)
    (line-extra-set! l #f)
    (line-wrapped-set! l #f))

  (define (line-copy l)
    (let ([n (make-line 0)])
      (line-cells-set! n (fxvector-copy (line-cells l)))
      (line-wrapped-set! n (line-wrapped l))
      (line-extra-set! n (and (line-extra l) (hashtable-copy (line-extra l) #t)))
      n))

  ;; Number of columns up to and including the last non-blank cell.
  (define (line-content-length l)
    (let ([v (line-cells l)])
      (let loop ([i (fx- (line-cols l) 1)])
        (cond
          [(fx< i 0) 0]
          [(and (cell-empty? v i) (fx= (cell-bg v i) COLOR-BG)) (loop (fx- i 1))]
          [else (fx+ i 1)]))))

  ;;; Grid ----------------------------------------------------------------

  (define-record-type grid
    (fields (mutable rows) (mutable cols)
            (mutable screen)          ; vector of lines, index 0 = top row
            (mutable hist)            ; ring buffer of lines
            (mutable hist-start)      ; index of oldest line in ring
            (mutable hist-count)
            (mutable scroll-counter)) ; total lines ever pushed to history
    (protocol
     (lambda (new)
       (lambda (rows cols hist-capacity)
         (let ([screen (make-vector rows)])
           (do ([i 0 (fx+ i 1)]) ((fx= i rows))
             (vector-set! screen i (make-line cols)))
           (new rows cols screen (make-vector hist-capacity #f) 0 0 0))))))

  (define (grid-hist-capacity g) (vector-length (grid-hist g)))

  (define (grid-screen-line g row) (vector-ref (grid-screen g) row))

  ;; row ranges over [-hist-count, rows)
  (define (grid-line g row)
    (if (fx>= row 0)
        (vector-ref (grid-screen g) row)
        (let ([cap (vector-length (grid-hist g))])
          (vector-ref (grid-hist g)
                      (fxmodulo (fx+ (grid-hist-start g) (fx+ (grid-hist-count g) row)) cap)))))

  ;; Append L to history; returns a line object that may be reused (the
  ;; evicted oldest line) or #f.
  (define (hist-push! g l)
    (let ([cap (vector-length (grid-hist g))])
      (grid-scroll-counter-set! g (fx+ 1 (grid-scroll-counter g)))
      (cond
        [(fx= cap 0) l]
        [(fx< (grid-hist-count g) cap)
         (vector-set! (grid-hist g)
                      (fxmodulo (fx+ (grid-hist-start g) (grid-hist-count g)) cap) l)
         (grid-hist-count-set! g (fx+ 1 (grid-hist-count g)))
         #f]
        [else
         (let* ([i (grid-hist-start g)] [old (vector-ref (grid-hist g) i)])
           (vector-set! (grid-hist g) i l)
           (grid-hist-start-set! g (fxmodulo (fx+ i 1) cap))
           old)])))

  (define (blank-line g recycled bg)
    (if (and recycled (fx= (line-cols recycled) (grid-cols g)))
        (begin (line-clear! recycled bg) recycled)
        (let ([l (make-line (grid-cols g))])
          (unless (fx= bg COLOR-BG) (line-fill! l 0 (grid-cols g) bg))
          l)))

  ;; Scroll lines [top, bottom] up by N; new lines at the bottom are blank
  ;; with background BG.  When SAVE? and top is 0, lines leaving the screen
  ;; go to the scrollback history.
  (define (grid-scroll-up! g top bottom n bg save?)
    (let* ([screen (grid-screen g)]
           [n (fxmin n (fx+ 1 (fx- bottom top)))])
      (do ([k 0 (fx+ k 1)]) ((fx= k n))
        (let* ([gone (vector-ref screen top)]
               [recycled (if (and save? (fx= top 0)) (hist-push! g gone) gone)])
          (do ([i top (fx+ i 1)]) ((fx= i bottom))
            (vector-set! screen i (vector-ref screen (fx+ i 1))))
          (vector-set! screen bottom (blank-line g recycled bg))))))

  (define (grid-scroll-down! g top bottom n bg)
    (let* ([screen (grid-screen g)]
           [n (fxmin n (fx+ 1 (fx- bottom top)))])
      (do ([k 0 (fx+ k 1)]) ((fx= k n))
        (let ([gone (vector-ref screen bottom)])
          (do ([i bottom (fx- i 1)]) ((fx= i top))
            (vector-set! screen i (vector-ref screen (fx- i 1))))
          (vector-set! screen top (blank-line g gone bg))))))

  (define (grid-clear-history! g)
    (vector-fill! (grid-hist g) #f)
    (grid-hist-start-set! g 0)
    (grid-hist-count-set! g 0))

  (define (grid-set-hist-capacity! g cap)
    (let* ([n (fxmin cap (grid-hist-count g))]
           [lines (let loop ([i 0] [acc '()])
                    (if (fx= i n) acc
                        (loop (fx+ i 1) (cons (grid-line g (fx- -1 i)) acc))))]
           [v (make-vector cap #f)])
      (let loop ([ls lines] [i 0])
        (unless (null? ls) (vector-set! v i (car ls)) (loop (cdr ls) (fx+ i 1))))
      (grid-hist-set! g v)
      (grid-hist-start-set! g 0)
      (grid-hist-count-set! g n)))

  ;;; Resize & reflow -----------------------------------------------------

  ;; A logical line: concatenated cells (fxvector), and combining extras as
  ;; an alist (offset . string).
  (define (logical-lines lines)
    ;; lines: list of line objects, oldest first.  Returns a list of
    ;; (cells-list-of-lines . was-last-wrapped) grouped by wrap flags.
    (let loop ([ls lines] [cur '()] [acc '()])
      (cond
        [(null? ls) (reverse (if (null? cur) acc (cons (reverse cur) acc)))]
        [(line-wrapped (car ls)) (loop (cdr ls) (cons (car ls) cur) acc)]
        [else (loop (cdr ls) '() (cons (reverse (cons (car ls) cur)) acc))])))

  (define (join-logical group)
    ;; returns (values cells extras length) where length excludes trailing blanks
    (let* ([total (apply fx+ (map line-cols group))]
           [v (make-fxvector (fx* 3 total) 0)]
           [extras '()])
      (let loop ([ls group] [off 0])
        (unless (null? ls)
          (let* ([l (car ls)] [c (line-cols l)] [src (line-cells l)])
            ;; a wrapped line may end in a padding cell left before a wide
            ;; character that did not fit; those are marked as spacers.
            (do ([i 0 (fx+ i 1)]) ((fx= i (fx* 3 c)))
              (fxvector-set! v (fx+ (fx* 3 off) i) (fxvector-ref src i)))
            (when (line-extra l)
              (let-values ([(ks vs) (hashtable-entries (line-extra l))])
                (vector-for-each (lambda (k s) (set! extras (cons (cons (fx+ off k) s) extras)))
                                 ks vs)))
            (loop (cdr ls) (fx+ off c)))))
      (let ([len (let trim ([i (fx- total 1)])
                   (cond
                     [(fx< i 0) 0]
                     [(and (cell-empty? v i) (fx= (cell-bg v i) COLOR-BG)) (trim (fx- i 1))]
                     [else (fx+ i 1)]))])
        (values v extras len))))

  ;; Split a logical line into physical lines of COLS columns.  Returns the
  ;; list of lines and a vector mapping logical offsets to (row . col).
  (define (split-logical v extras len cols want-offset)
    ;; returns (values lines cursor-pos) where cursor-pos is (row . col) of
    ;; want-offset (or #f)
    (let loop ([i 0] [lines '()] [cur (make-line cols)] [col 0] [pos #f])
      (let ([pos (if (and want-offset (not pos) (fx= i want-offset))
                     (cons (length lines) (fxmin col (fx- cols 1)))
                     pos)])
        (cond
          [(fx>= i len)
           (let* ([lines (reverse (cons cur lines))]
                  [pos (or pos
                           (and want-offset
                                ;; cursor beyond content: continue counting
                                (let* ([extra (fx- want-offset len)]
                                       [c (fx+ col extra)]
                                       [row (fx+ (fx- (length lines) 1) (fxquotient c cols))])
                                  (cons row (fxmin (fxremainder c cols) (fx- cols 1))))))])
             (values lines pos))]
          [else
           (let* ([attrs (cell-attrs v i)]
                  [w (if (fxlogtest attrs ATTR-WIDE) 2 1)])
             (cond
               [(fxlogtest attrs ATTR-SPACER)
                ;; skip spacer halves; they are regenerated with the wide char
                (loop (fx+ i 1) lines cur col pos)]
               [(fx> (fx+ col w) cols)
                ;; wrap
                (line-wrapped-set! cur #t)
                (loop i (cons cur lines) (make-line cols) 0 pos)]
               [else
                (cell-copy! v i (line-cells cur) col)
                (let ([ex (assv i extras)])
                  (when ex
                    (unless (line-extra cur) (line-extra-set! cur (make-eqv-hashtable)))
                    (hashtable-set! (line-extra cur) col (cdr ex))))
                (when (fx= w 2)
                  (let ([c (line-cells cur)] [k (fx* 3 (fx+ col 1))] [j (fx* 3 i)])
                    (fxvector-set! c k (fxsll ATTR-SPACER 21))
                    (fxvector-set! c (fx+ k 1) (fxvector-ref v (fx+ j 1)))
                    (fxvector-set! c (fx+ k 2) (fxvector-ref v (fx+ j 2)))))
                (loop (fx+ i 1) lines cur (fx+ col w) pos)]))]))))

  (define (resize-line l cols)
    (let* ([old (line-cols l)] [n (make-line cols)] [m (fxmin old cols)])
      (do ([i 0 (fx+ i 1)]) ((fx= i m))
        (cell-copy! (line-cells l) i (line-cells n) i))
      ;; don't leave half of a wide character at the edge
      (when (and (fx> m 0) (fxlogtest (cell-attrs (line-cells n) (fx- m 1)) ATTR-WIDE))
        (line-fill! n (fx- m 1) m COLOR-BG))
      (when (line-extra l)
        (let ([ex (make-eqv-hashtable)])
          (let-values ([(ks vs) (hashtable-entries (line-extra l))])
            (vector-for-each (lambda (k s) (when (fx< k cols) (hashtable-set! ex k s))) ks vs))
          (line-extra-set! n ex)))
      (line-wrapped-set! n (and (fx>= cols old) (line-wrapped l)))
      n))

  ;; Resize to ROWS x COLS.  When REFLOW? is true, wrapped lines are rejoined
  ;; and re-split at the new width.  Returns the cursor's new position as
  ;; (values row col).
  (define (grid-resize! g rows cols reflow? crow ccol)
    (if (and reflow? (not (fx= cols (grid-cols g))))
        (reflow! g rows cols crow ccol)
        (simple-resize! g rows cols crow ccol)))

  (define (simple-resize! g rows cols crow ccol)
    (let* ([old-rows (grid-rows g)]
           [lines (append (let loop ([i (fx- (grid-hist-count g))] [acc '()])
                            (if (fx= i 0) (reverse acc) (loop (fx+ i 1) (cons (grid-line g i) acc))))
                          (vector->list (grid-screen g)))]
           [lines (if (fx= cols (grid-cols g)) lines (map (lambda (l) (resize-line l cols)) lines))]
           ;; drop blank lines below the cursor when shrinking
           [excess (fx- old-rows rows)]
           [trim (if (fx> excess 0)
                     (let loop ([k 0] [r (fx- old-rows 1)])
                       (if (and (fx< k excess) (fx> r crow)
                                (fx= 0 (line-content-length (vector-ref (grid-screen g) r))))
                           (loop (fx+ k 1) (fx- r 1))
                           k))
                     0)]
           [lines (list-head lines (fx- (length lines) trim))])
      (install-lines! g rows cols lines (fx+ (grid-hist-count g) crow) ccol)))

  (define (reflow! g rows cols crow ccol)
    (let* ([hist (let loop ([i (fx- (grid-hist-count g))] [acc '()])
                   (if (fx= i 0) (reverse acc) (loop (fx+ i 1) (cons (grid-line g i) acc))))]
           ;; screen lines up to the last with content or the cursor
           [last (let loop ([r (fx- (grid-rows g) 1)])
                   (cond [(fx<= r crow) crow]
                         [(fx> (line-content-length (vector-ref (grid-screen g) r)) 0) r]
                         [else (loop (fx- r 1))]))]
           [screen (let loop ([r 0] [acc '()])
                     (if (fx> r last) (reverse acc)
                         (loop (fx+ r 1) (cons (vector-ref (grid-screen g) r) acc))))]
           [all (append hist screen)]
           [cursor-line (list-ref all (fx+ (length hist) crow))]
           [groups (logical-lines all)])
      (let loop ([gs groups] [out '()] [cpos #f])
        (if (null? gs)
            (let ([lines (reverse out)])
              (install-lines! g rows cols lines (car cpos) (cdr cpos)))
            (let* ([group (car gs)]
                   [ci (let find ([ls group] [off 0])
                         (cond [(null? ls) #f]
                               [(eq? (car ls) cursor-line) (fx+ off ccol)]
                               [else (find (cdr ls) (fx+ off (line-cols (car ls))))]))])
              (let-values ([(v extras len) (join-logical group)])
                (let-values ([(new pos) (split-logical v extras len cols ci)])
                  (loop (cdr gs)
                        (append (reverse new) out)
                        (or cpos (and pos (cons (fx+ (length out) (car pos)) (cdr pos))))))))))))

  ;; Install LINES (oldest first) as history + screen such that the line
  ;; with index CLINE is on screen; returns the cursor position.
  (define (install-lines! g rows cols lines cline ccol)
    (let* ([n (length lines)]
           [cline (fxmin cline (fx- n 1))]
           ;; screen starts at the latest point that keeps all lines up to
           ;; the end visible, but never below the cursor line
           [start (fxmax 0 (fxmin (fx- n rows) cline))]
           [start (if (fx< (fx- cline start) rows) start (fx+ 1 (fx- cline rows)))]
           [screen (make-vector rows #f)]
           [cap (vector-length (grid-hist g))]
           [hist-lines (list-head lines start)]
           [hist-lines (if (fx> (length hist-lines) cap)
                           (list-tail hist-lines (fx- (length hist-lines) cap))
                           hist-lines)]
           [dropped (fx- start (length hist-lines))])
      (let loop ([i 0] [ls (list-tail lines start)])
        (when (fx< i rows)
          (vector-set! screen i (if (null? ls) (make-line cols) (car ls)))
          (loop (fx+ i 1) (if (null? ls) ls (cdr ls)))))
      ;; the last line on screen can't be wrapped into nothing
      (let ([hv (make-vector cap #f)])
        (let loop ([i 0] [ls hist-lines])
          (unless (null? ls) (vector-set! hv i (car ls)) (loop (fx+ i 1) (cdr ls))))
        (grid-hist-set! g hv)
        (grid-hist-start-set! g 0)
        (grid-hist-count-set! g (length hist-lines)))
      (grid-scroll-counter-set! g (fx+ (grid-scroll-counter g) dropped))
      (grid-screen-set! g screen)
      (grid-rows-set! g rows)
      (grid-cols-set! g cols)
      (values (fx- cline start) (fxmin ccol (fx- cols 1))))))
