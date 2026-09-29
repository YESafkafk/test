;;; Text extraction from the grid: selections, word / line boundaries,
;;; search matches and URLs.  Rows are absolute (see terminal-abs-row).
(library (chezterm selection)
  (export line-at-abs cell-char word-bounds logical-line-bounds selection-text
          line-text line-matches url-at)
  (import (chezscheme) (chezterm grid) (chezterm terminal))

  (define (line-at-abs term abs)
    (let ([row (terminal-rel-row term abs)] [g (terminal-grid term)])
      (and (>= row (- (grid-hist-count g))) (< row (grid-rows g))
           (grid-line g row))))

  (define (cell-char l col)
    (let ([v (line-cells l)])
      (if (or (< col 0) (>= col (line-cols l))) #\space
          (let ([c (cell-ch v col)]) (if (= c 0) #\space (integer->char c))))))

  (define (word-char? c separators)
    (not (or (char=? c #\space) (memv c (string->list separators)))))

  (define (word-bounds term separators abs col)
    (let ([l (line-at-abs term abs)])
      (if (not l)
          (cons col col)
          (let ([ch (cell-char l col)] [cols (line-cols l)])
            (if (not (word-char? ch separators))
                (cons col col)
                (let ([start (let loop ([c col])
                               (if (and (> c 0) (word-char? (cell-char l (- c 1)) separators)) (loop (- c 1)) c))]
                      [end (let loop ([c col])
                             (if (and (< c (- cols 1)) (word-char? (cell-char l (+ c 1)) separators)) (loop (+ c 1)) c))])
                  (cons start end)))))))

  ;; start/end rows of the logical (wrapped) line containing ABS
  (define (logical-line-bounds term abs)
    (let ([start (let loop ([a abs])
                   (let ([prev (line-at-abs term (- a 1))])
                     (if (and prev (line-wrapped prev)) (loop (- a 1)) a)))]
          [end (let loop ([a abs])
                 (let ([l (line-at-abs term a)])
                   (if (and l (line-wrapped l) (line-at-abs term (+ a 1))) (loop (+ a 1)) a)))])
      (cons start end)))

  ;; Text of the current selection.
  (define (selection-text term)
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
                 (let ([l (line-at-abs term abs)])
                   (when l
                     (let* ([cols (line-cols l)]
                            [from (cond [block (min sc ec)] [(= abs r0) c0] [else 0])]
                            [to (cond [block (+ 1 (max sc ec))] [(= abs r1) (+ c1 1)] [else cols])]
                            [to (min to cols)]
                            [content (line-content-length l)]
                            [trimmed-to (if (or block (not (line-wrapped l)) (= abs r1)) (min to content) to)])
                       (let ([text (line-text l from trimmed-to)])
                         ;; like xterm, drop trailing blanks at line ends
                         (put-string out (if (or block (not (line-wrapped l)) (= abs r1))
                                             (string-trim-right text)
                                             text)))
                       (when (and (< abs r1) (or block (not (line-wrapped l))))
                         (newline out)))))
                 (loop (+ abs 1))))
             (let ([s (get-output-string out)])
               (and (> (string-length s) 0) s))))))

  (define (string-trim-right s)
    (let loop ([k (string-length s)])
      (if (and (> k 0) (char=? (string-ref s (- k 1)) #\space))
          (loop (- k 1))
          (substring s 0 k))))

  (define (line-text l from to)
    (let ([v (line-cells l)] [ex (line-extra l)] [out (open-output-string)])
      (do ([i from (+ i 1)]) ((>= i to))
        (unless (fxlogtest (cell-attrs v i) ATTR-SPACER)
          (let ([c (cell-ch v i)])
            (write-char (if (= c 0) #\space (integer->char c)) out)
            (let ([marks (and ex (hashtable-ref ex i #f))])
              (when marks (put-string out marks))))))
      (get-output-string out)))

    (define (smart-case-equal? query)
    (if (string=? query (string-downcase query)) char-ci=? char=?))

  ;; Matches of the search query in absolute row ABS: list of (c0 c1)
  ;; (cell columns, end exclusive).
  (define (line-matches term query abs)
    (let ([l (line-at-abs term abs)] [q query])
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

  ;; URL under the pointer (for ctrl+click)
  (define (url-at term pt)
    (let ([l (line-at-abs term (car pt))])
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

)
