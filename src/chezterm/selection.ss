;;; Text extraction from the grid: selections, word / line boundaries,
;;; search matches and URLs.  Rows are absolute (see terminal-abs-row).
(library (chezterm selection)
  (export line-at-abs cell-char word-bounds logical-line-bounds selection-text
          line-text line-matches url-at link-id-at link-ranges openable-url?)
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
            (let ([marks (and ex (line-marks l i))])
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

  ;; The id of the OSC 8 link at PT ((abs . col)), or 0.  The second half of
  ;; a wide character has the first half's link.
  (define (link-id-at term pt)
    (let ([l (line-at-abs term (car pt))] [col (cdr pt)])
      (if (and l (< -1 col (line-cols l)))
          (line-link l (if (and (> col 0) (fxlogtest (cell-attrs (line-cells l) col) ATTR-SPACER))
                           (- col 1)
                           col))
          0)))

  ;; Column ranges ((c0 c1) ...), end exclusive, of the cells of absolute
  ;; row ABS that belong to link ID.
  (define (link-ranges term id abs)
    (let ([l (line-at-abs term abs)])
      (if (or (not l) (not (line-extra l)) (= id 0))
          '()
          (let ([v (line-cells l)] [cols (line-cols l)])
            (let loop ([i 0] [start #f] [acc '()])
              (let ([in (and (< i cols)
                             (= id (line-link l (if (and (> i 0) (fxlogtest (cell-attrs v i) ATTR-SPACER))
                                                    (- i 1)
                                                    i))))])
                (cond
                  [(= i cols) (reverse (if start (cons (list start i) acc) acc))]
                  [(and in (not start)) (loop (+ i 1) i acc)]
                  [(and (not in) start) (loop (+ i 1) #f (cons (list start i) acc))]
                  [else (loop (+ i 1) start acc)])))))))

  ;; Only these schemes are opened: an OSC 8 link's URI comes from whatever
  ;; runs in the terminal.
  (define (openable-url? u)
    (let ([colon (let loop ([i 0])
                   (cond [(= i (string-length u)) #f]
                         [(char=? (string-ref u i) #\:) i]
                         [else (loop (+ i 1))]))])
      (and colon
           (member (string-downcase (substring u 0 colon)) '("http" "https" "ftp" "file" "mailto"))
           #t)))

  ;; URL at PT (for ctrl+click): the OSC 8 link there, or else a URL found
  ;; in the text
  (define (url-at term pt)
    (or (terminal-link-uri term (link-id-at term pt))
        (text-url-at term pt)))

  (define (text-url-at term pt)
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
