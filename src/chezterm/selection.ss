;;; Text extraction from the grid: selections, word / line boundaries,
;;; search matches and URLs.  Rows are absolute (see terminal-abs-row).
(library (chezterm selection)
  (export line-at-abs cell-char word-bounds logical-line-bounds selection-text
          line-text line-matches url-at text-url-at link-id-at link-ranges openable-url? uri-to-open
          target? target-uri target-start target-end target-label target-link
          hint-targets text-url-target-at target-ranges prompt-view-offset)
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

  ;; What xdg-open is given to open URI, or #f when it is not opened: URIs
  ;; that openable-url? refuses, and, as in kitty, file URIs on another
  ;; host.  A file URI whose host is empty, localhost or HOSTNAME (this
  ;; machine's name) loses its host: file://localhost/tmp/x opens as
  ;; file:///tmp/x.  As in kitty (Python's urlparse), the host is the part
  ;; before the first / ? or #, up to a port after a colon.
  (define (uri-to-open uri hostname)
    (and (openable-url? uri)
         (let ([n (string-length uri)])
           (if (not (and (>= n 7) (string-ci=? (substring uri 0 7) "file://")))
               uri
               (let* ([end (let loop ([i 7])
                             (if (or (= i n) (memv (string-ref uri i) '(#\/ #\? #\#))) i (loop (+ i 1))))]
                      [netloc (substring uri 7 end)]
                      [host (let loop ([i 0])
                              (cond [(= i (string-length netloc)) netloc]
                                    [(char=? (string-ref netloc i) #\:) (substring netloc 0 i)]
                                    [else (loop (+ i 1))]))])
                 (cond
                   [(string=? netloc "") uri]
                   [(member host (list "" "localhost" hostname))
                    (string-append "file://" (substring uri end n))]
                   [else #f]))))))

  ;; URL at PT (for ctrl+click): the OSC 8 link there, or else a URL found
  ;; in the text
  (define (url-at term pt)
    (or (terminal-link-uri term (link-id-at term pt))
        (text-url-at term pt)))

  ;; The URL found in the text at PT, or #f.
  (define (text-url-at term pt)
    (let ([t (text-url-target-at term pt)]) (and t (target-uri t))))

  ;;; Targets: OSC 8 links and URLs found in the text ----------------------

  ;; What keyboard hints label and Ctrl+hover underlines.  START is the
  ;; (abs . col) of the first cell, END the (abs . col) just past the last
  ;; one (the column is exclusive, the row is the last cell's), LABEL the
  ;; (abs . col) of the first visible cell, LINK the OSC 8 link id (0 for a
  ;; URL found in the text).
  (define-record-type target (fields uri start end label link))

  ;; A logical line is followed at most this many rows beyond the rows it
  ;; is looked at from (as in Alacritty).
  (define max-wrap-lines 100)

  ;; First and last absolute row of the logical line containing ABS, at
  ;; most max-wrap-lines rows above LO and below HI.
  (define (logical-span term abs lo hi)
    (cons (let loop ([a abs])
            (let ([prev (and (> a (- lo max-wrap-lines)) (line-at-abs term (- a 1)))])
              (if (and prev (line-wrapped prev)) (loop (- a 1)) a)))
          (let loop ([a abs])
            (let ([l (line-at-abs term a)])
              (if (and l (line-wrapped l) (< a (+ hi max-wrap-lines)) (line-at-abs term (+ a 1)))
                  (loop (+ a 1))
                  a)))))

  ;; The text of absolute rows [from, to] with one character per cell,
  ;; empty cells as spaces.  The second halves of wide characters are left
  ;; out, and so is the blank a wrapped row ends with when a wide character
  ;; did not fit.  Returns (values text rows cols ends links): for each
  ;; character its absolute row, its column, the column after it and its
  ;; OSC 8 link id.
  (define (span-text term from to)
    (let loop ([abs to] [chars '()] [rows '()] [cols '()] [ends '()] [links '()])
      (if (< abs from)
          (values (list->string chars) (list->vector rows) (list->vector cols)
                  (list->vector ends) (list->vector links))
          (let* ([l (line-at-abs term abs)] [v (line-cells l)] [n (line-cols l)]
                 [ex (line-extra l)]
                 [next (and (line-wrapped l) (< abs to) (line-at-abs term (+ abs 1)))]
                 [n (if (and next (> n 1) (cell-empty? v (- n 1))
                             (> (line-cols next) 0)
                             (fxlogtest (cell-attrs (line-cells next) 0) ATTR-WIDE))
                        (- n 1)
                        n)])
            (let cell ([i (- n 1)] [chars chars] [rows rows] [cols cols] [ends ends] [links links])
              (cond
                [(< i 0) (loop (- abs 1) chars rows cols ends links)]
                [(fxlogtest (cell-attrs v i) ATTR-SPACER) (cell (- i 1) chars rows cols ends links)]
                [else
                 (cell (- i 1) (cons (cell-char l i) chars) (cons abs rows) (cons i cols)
                       (cons (if (fxlogtest (cell-attrs v i) ATTR-WIDE) (min n (+ i 2)) (+ i 1)) ends)
                       (cons (if ex (line-link l i) 0) links))]))))))

  (define url-schemes '("https://" "http://" "file://" "ftp://" "mailto:"))

  ;; Characters a URL ends before, as in Alacritty's URL hint regex.
  (define (url-char? c)
    (not (or (char<=? c #\space) (char<=? #\x7f c #\x9f) (char-whitespace? c)
             (memv c '(#\" #\' #\< #\> #\` #\{ #\| #\} #\^ #\\ #\x27E8 #\x27E9)))))

  (define (prefix-at? s i pat)
    (let ([m (string-length pat)])
      (and (<= (+ i m) (string-length s))
           (let loop ([k 0])
             (or (= k m) (and (char=? (string-ref s (+ i k)) (string-ref pat k)) (loop (+ k 1))))))))

  ;; The end of the URL in TEXT from START (after its scheme SCHEME-END) to
  ;; RAW-END, after Alacritty's hint post-processing: an unbalanced ) or ]
  ;; ends it, and trailing characters that are more likely punctuation
  ;; around it than part of it are dropped.
  (define (url-end text start raw-end)
    (let* ([end (let loop ([i start] [parens 0] [brackets 0])
                  (if (= i raw-end)
                      i
                      (case (string-ref text i)
                        [(#\() (loop (+ i 1) (+ parens 1) brackets)]
                        [(#\[) (loop (+ i 1) parens (+ brackets 1))]
                        [(#\)) (if (= parens 0) i (loop (+ i 1) (- parens 1) brackets))]
                        [(#\]) (if (= brackets 0) i (loop (+ i 1) parens (- brackets 1)))]
                        [else (loop (+ i 1) parens brackets)])))])
      (let loop ([end end])
        (if (and (> end (+ start 1))
                 (memv (string-ref text (- end 1)) '(#\. #\, #\: #\; #\? #\! #\( #\[ #\')))
            (loop (- end 1))
            end))))

  ;; The URLs in TEXT: a list of (start . end), end exclusive.  LINKS holds
  ;; the link id of each character: a URL never crosses the start or end of
  ;; a link.
  (define (url-spans text links)
    (let ([n (string-length text)])
      (let loop ([i 0] [acc '()])
        (if (>= i n)
            (reverse acc)
            (let ([scheme (find (lambda (s) (prefix-at? text i s)) url-schemes)])
              (if (not scheme)
                  (loop (+ i 1) acc)
                  (let* ([body (+ i (string-length scheme))]
                         [id (vector-ref links i)]
                         [raw-end (let e ([j (+ i 1)])
                                    (if (and (< j n) (= id (vector-ref links j))
                                             (or (< j body) (url-char? (string-ref text j))))
                                        (e (+ j 1))
                                        j))]
                         [end (url-end text i raw-end)])
                    (if (> end body)
                        (loop end (cons (cons i end) acc))
                        (loop (+ i 1) acc)))))))))

  ;; The targets of absolute rows [from, to], a logical line or part of
  ;; one, that have a cell in the rows [top, bottom].  Links whose id is in
  ;; SEEN are left out, and the others are added to it: a link gets one
  ;; target, at its first visible run.  A URL found in the text of a link
  ;; is left out as well, since the link is what Ctrl+click opens there.
  (define (span-targets term from to top bottom seen)
    (let-values ([(text rows cols ends links) (span-text term from to)])
      (let* ([n (string-length text)]
             [visible (lambda (i j)       ; the first visible character in [i, j)
                        (let loop ([k i])
                          (cond [(or (= k j) (> (vector-ref rows k) bottom)) #f]
                                [(>= (vector-ref rows k) top) k]
                                [else (loop (+ k 1))])))]
             [make (lambda (uri i j link)
                     (let ([k (visible i j)])
                       (and k (make-target uri
                                           (cons (vector-ref rows i) (vector-ref cols i))
                                           (cons (vector-ref rows (- j 1)) (vector-ref ends (- j 1)))
                                           (cons (vector-ref rows k) (vector-ref cols k))
                                           link))))]
             [link-targets
              (let loop ([i 0] [acc '()])
                (if (= i n)
                    acc
                    (let ([id (vector-ref links i)])
                      (if (= id 0)
                          (loop (+ i 1) acc)
                          (let* ([j (let e ([j (+ i 1)]) (if (and (< j n) (= id (vector-ref links j))) (e (+ j 1)) j))]
                                 [uri (and (not (hashtable-ref seen id #f)) (terminal-link-uri term id))]
                                 [t (and uri (make uri i j id))])
                            (when t (hashtable-set! seen id #t))
                            (loop j (if t (cons t acc) acc)))))))])
        (fold-left (lambda (acc s)
                     (let ([i (car s)] [j (cdr s)])
                       (if (terminal-link-uri term (vector-ref links i))
                           acc
                           (let ([t (make (substring text i j) i j 0)]) (if t (cons t acc) acc)))))
                   link-targets
                   (url-spans text links)))))

  (define (label<? a b)
    (let ([p (target-label a)] [q (target-label b)])
      (or (< (car p) (car q)) (and (= (car p) (car q)) (< (cdr p) (cdr q))))))

  ;; The targets in TERM's view (also when it is scrolled back), in the
  ;; order of their first visible cells.
  (define (hint-targets term)
    (let* ([rows (terminal-rows term)]
           [top (terminal-abs-row term (- (terminal-display-offset term)))]
           [bottom (+ top rows -1)]
           [seen (make-eqv-hashtable)])
      (let loop ([abs top] [acc '()])
        (if (> abs bottom)
            (list-sort label<? acc)
            (let ([span (logical-span term abs top bottom)])
              (loop (+ (cdr span) 1)
                    (append (span-targets term (if (= abs top) (car span) abs) (cdr span) top bottom seen)
                            acc)))))))

  ;; The URL found in the text at PT, as a target, or #f.
  (define (text-url-target-at term pt)
    (let ([abs (car pt)] [col (cdr pt)])
      (and (line-at-abs term abs)
           (let ([span (logical-span term abs abs abs)])
             (let-values ([(text rows cols ends links) (span-text term (car span) (cdr span))])
               (let ([k (let loop ([k 0])
                          (cond [(= k (vector-length rows)) #f]
                                [(and (= abs (vector-ref rows k)) (<= (vector-ref cols k) col)
                                      (< col (vector-ref ends k)))
                                 k]
                                [else (loop (+ k 1))]))])
                 (and k
                      (let ([s (find (lambda (s) (and (<= (car s) k) (< k (cdr s)))) (url-spans text links))])
                        (and s
                             (make-target (substring text (car s) (cdr s))
                                          (cons (vector-ref rows (car s)) (vector-ref cols (car s)))
                                          (cons (vector-ref rows (- (cdr s) 1)) (vector-ref ends (- (cdr s) 1)))
                                          pt 0))))))))))

  ;; Column ranges ((c0 c1)), end exclusive, of target T's cells in
  ;; absolute row ABS of a terminal with COLS columns.
  (define (target-ranges t abs cols)
    (let ([s (target-start t)] [e (target-end t)])
      (if (<= (car s) abs (car e))
          (list (list (if (= abs (car s)) (cdr s) 0) (if (= abs (car e)) (cdr e) cols)))
          '())))

;;; Shell integration: jumping between prompts ----------------------------

  ;; The display offset that puts the previous (DIR -1) or next (DIR 1)
  ;; prompt at the top of the view, or #f when there is none, as kitty's
  ;; scroll_to_prompt and foot's prompt-prev / prompt-next do: prompts are
  ;; lines marked by OSC 133;A (not secondary prompts), searched from the
  ;; line after the view's top line, so the prompt at the top is skipped.
  ;; A next prompt on the screen scrolls to the bottom.  Only the primary
  ;; screen has prompts to jump to.
  (define (prompt-view-offset term dir)
    (and (not (terminal-alt-screen? term))
         (let* ([g (terminal-grid term)]
                [first (- (grid-hist-count g))]
                [last (- (grid-rows g) 1)])
           (let loop ([row (+ (- (terminal-display-offset term)) dir)])
             (cond
               [(or (< row first) (> row last)) #f]
               [(fxlogtest (line-marks-field (grid-line g row)) MARK-PROMPT) (max 0 (- row))]
               [else (loop (+ row dir))])))))

)
