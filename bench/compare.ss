;;; Compare benchmark results.
;;;
;;;   scheme --libdirs tools --script bench/compare.ss OLD.json NEW.json [options]
;;;   scheme --libdirs tools --script bench/compare.ss --old A1.json A2.json ... --new B1.json ... [options]
;;;
;;; Options:
;;;   --threshold PCT   smallest change reported (default 5)
;;;   --alpha P         significance level (default 0.05)
;;;   --fail            exit with status 1 if anything got slower
;;;   --no-correction   do not adjust p-values for multiple comparisons
;;;
;;; Samples of the same benchmark from several files are merged (bench/ab.sh
;;; produces such files by interleaving the two builds).  A benchmark is
;;; called faster or slower only when both
;;;   - the medians differ by at least the threshold, and
;;;   - a two-sided Mann-Whitney U test finds the sample sets different
;;;     (p < alpha), i.e. the difference is larger than the noise.
;;; The p-values are Holm-Bonferroni adjusted for the number of benchmarks
;;; compared, so running 20 benchmarks does not produce a false alarm
;;; about once per comparison.
;;; Differences in the environment (font cell size, Chez version, CPU,
;;; workload checksums) are reported: they make numbers incomparable.
(import (chezscheme) (json))

(define threshold 5.0)
(define alpha 0.05)
(define fail-on-regression #f)
(define correction #t)

(define-values (old-files new-files)
  (let loop ([as (command-line-arguments)] [mode #f] [old '()] [new '()] [positional '()])
    (cond
      [(null? as)
       (cond
         [(and (null? old) (null? new) (= 2 (length positional)))
          (values (list (cadr positional)) (list (car positional)))]
         [(and (pair? old) (pair? new) (null? positional)) (values (reverse old) (reverse new))]
         [else
          (display "usage: compare.ss OLD.json NEW.json | --old FILE... --new FILE... [--threshold PCT] [--alpha P] [--fail]\n")
          (exit 2)])]
      [(and (string=? (car as) "--threshold") (pair? (cdr as)))
       (set! threshold (inexact (string->number (cadr as)))) (loop (cddr as) mode old new positional)]
      [(and (string=? (car as) "--alpha") (pair? (cdr as)))
       (set! alpha (inexact (string->number (cadr as)))) (loop (cddr as) mode old new positional)]
      [(string=? (car as) "--fail") (set! fail-on-regression #t) (loop (cdr as) mode old new positional)]
      [(string=? (car as) "--no-correction") (set! correction #f) (loop (cdr as) mode old new positional)]
      [(string=? (car as) "--old") (loop (cdr as) 'old old new positional)]
      [(string=? (car as) "--new") (loop (cdr as) 'new old new positional)]
      [(eq? mode 'old) (loop (cdr as) mode (cons (car as) old) new positional)]
      [(eq? mode 'new) (loop (cdr as) mode old (cons (car as) new) positional)]
      [else (loop (cdr as) mode old new (cons (car as) positional))])))

(define old-docs (map json-read-file old-files))
(define new-docs (map json-read-file new-files))

;;; Statistics ----------------------------------------------------------------------

(define (median xs)
  (let* ([v (list->vector (list-sort < xs))] [n (vector-length v)])
    (if (odd? n)
        (vector-ref v (quotient n 2))
        (/ (+ (vector-ref v (- (quotient n 2) 1)) (vector-ref v (quotient n 2))) 2.0))))

(define (mad-pct xs)
  (let ([m (median xs)])
    (if (zero? m) 0.0 (* 100.0 (/ (median (map (lambda (x) (abs (- x m))) xs)) m)))))

;; standard normal cumulative distribution (Abramowitz & Stegun 26.2.17)
(define (phi z)
  (if (< z 0)
      (- 1.0 (phi (- z)))
      (let* ([t (/ 1.0 (+ 1.0 (* 0.2316419 z)))]
             [poly (* t (+ 0.319381530
                           (* t (+ -0.356563782
                                   (* t (+ 1.781477937
                                           (* t (+ -1.821255978 (* t 1.330274429)))))))))])
        (- 1.0 (* (/ (exp (* -0.5 z z)) (sqrt (* 2 3.141592653589793))) poly)))))

;; Two-sided Mann-Whitney U test, normal approximation with tie and
;; continuity correction.  Returns the p-value.
(define (mann-whitney xs ys)
  (let* ([n1 (length xs)] [n2 (length ys)] [n (+ n1 n2)]
         [all (list-sort (lambda (a b) (< (car a) (car b)))
                         (append (map (lambda (x) (cons x 'x)) xs) (map (lambda (y) (cons y 'y)) ys)))]
         [v (list->vector all)])
    ;; average ranks for ties, and the tie correction term
    (let loop ([i 0] [rank-sum-x 0.0] [ties 0.0])
      (if (< i n)
          (let* ([j (let find ([j i])
                      (if (and (< (+ j 1) n) (= (car (vector-ref v (+ j 1))) (car (vector-ref v i))))
                          (find (+ j 1)) j))]
                 [t (+ 1 (- j i))]
                 [avg (/ (+ i j 2) 2.0)]
                 [xs-in-group (let count ([k i] [c 0])
                                (if (> k j) c (count (+ k 1) (if (eq? 'x (cdr (vector-ref v k))) (+ c 1) c))))])
            (loop (+ j 1) (+ rank-sum-x (* avg xs-in-group)) (+ ties (- (* t t t) t))))
          (let* ([u (- rank-sum-x (/ (* n1 (+ n1 1)) 2.0))]
                 [mu (/ (* n1 n2) 2.0)]
                 [sigma (sqrt (* (/ (* n1 n2) 12.0) (- (+ n 1) (/ ties (* n (- n 1))))))])
            (if (zero? sigma)
                1.0
                (let ([z (/ (max 0.0 (- (abs (- u mu)) 0.5)) sigma)])
                  (min 1.0 (* 2.0 (- 1.0 (phi z)))))))))))

;;; Merging ------------------------------------------------------------------------

;; name -> (result . merged-samples), in the order of the first file
(define (merge docs)
  (let ([table '()])
    (for-each
     (lambda (doc)
       (for-each
        (lambda (r)
          (let* ([name (jref r "name")] [e (assoc name table)])
            (if e
                (set-cdr! e (cons (car (cdr e)) (append (cdr (cdr e)) (jref r "samples"))))
                (set! table (append table (list (cons name (cons r (jref r "samples")))))))))
        (jref doc "results")))
     docs)
    table))

(define (env doc key) (jref* doc "environment" key))

(define (report-environment)
  (for-each
   (lambda (key)
     (let ([olds (list-sort string<? (map (lambda (d) (format "~a" (env d key))) old-docs))]
           [news (list-sort string<? (map (lambda (d) (format "~a" (env d key))) new-docs))])
       (unless (equal? (car olds) (car news))
         (printf "note: ~a differs: ~a -> ~a\n" key (car olds) (car news)))))
   '("revision" "chez" "cpu" "cell" "font" "quick")))

;;; Report ---------------------------------------------------------------------------

(report-environment)

(define old-table (merge old-docs))
(define new-table (merge new-docs))

(printf "\n~32a ~9a ~9@a ~9@a ~7@a ~6@a  ~a\n" "benchmark" "unit" "old" "new" "change" "p" "")

(define regressions 0)
(define improvements 0)

;; Holm-Bonferroni: adjusted p for a list of raw p-values (same order)
(define (holm ps)
  (let* ([m (length ps)]
         [order (list-sort (lambda (a b) (< (cdr a) (cdr b)))
                           (map cons (iota m) ps))]
         [adjusted (make-vector m 1.0)])
    (let loop ([es order] [j 0] [running 0.0])
      (unless (null? es)
        (let ([a (max running (min 1.0 (* (- m j) (cdar es))))])
          (vector-set! adjusted (caar es) a)
          (loop (cdr es) (+ j 1) a))))
    (vector->list adjusted)))

;; rows: #(name unit old-median new-median change p higher? same-workload?)
(define rows
  (filter values
    (map (lambda (entry)
           (let* ([name (car entry)] [r (cadr entry)] [ns (cddr entry)]
                  [o (assoc name old-table)])
             (and o
                  (let* ([os (cddr o)] [om (median os)] [nm (median ns)])
                    (vector name (jref r "unit") om nm
                            (if (zero? om) 0.0 (* 100.0 (/ (- nm om) om)))
                            (mann-whitney os ns)
                            (equal? (jref r "better") "higher")
                            (equal? (jref (cadr o) "checksum") (jref r "checksum")))))))
         new-table)))

(define adjusted-ps
  (let ([ps (map (lambda (row) (vector-ref row 5)) rows)])
    (if correction (holm ps) ps)))

(for-each
 (lambda (row p)
   (let* ([change (vector-ref row 4)]
          [verdict (cond
                     [(not (vector-ref row 7)) "different workload"]
                     [(or (< (abs change) threshold) (>= p alpha)) ""]
                     [(eq? (vector-ref row 6) (> change 0)) (set! improvements (+ improvements 1)) "faster"]
                     [else (set! regressions (+ regressions 1)) "SLOWER"])])
     (printf "~32a ~9a ~9,2f ~9,2f ~6,1f% ~6,3f  ~a\n"
             (vector-ref row 0) (vector-ref row 1) (vector-ref row 2) (vector-ref row 3)
             change p verdict)))
 rows adjusted-ps)

(for-each
 (lambda (entry)
   (unless (assoc (car entry) old-table)
     (printf "~32a ~9a ~9a ~9,2f  (new)\n" (car entry) (jref (cadr entry) "unit") "" (median (cddr entry)))))
 new-table)

(printf "\n~a faster, ~a slower (|change| >= ~a% and ~ap < ~a; ~a vs ~a result file~a)\n"
        improvements regressions threshold (if correction "Holm-adjusted " "") alpha
        (length old-files) (length new-files)
        (if (= 1 (length new-files)) "" "s"))
(when (and (= 1 (length old-files)) (= 1 (length new-files)))
  (printf "Runs at different times can differ by more than their own noise; bench/ab.sh\ninterleaves the two builds to rule that out.\n"))
(exit (if (and fail-on-regression (> regressions 0)) 1 0))
