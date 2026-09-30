;;; chezterm benchmarks.
;;;
;;;   scheme --libdirs build/lib:. --script bench/run.ss [options]
;;;   (or: make bench, nix run .#bench)
;;;
;;; Options:
;;;   --quick           small workloads and few iterations (smoke test)
;;;   --iterations N    measured iterations per benchmark (default 7)
;;;   --only A,B        run benchmarks whose name contains A or B
;;;   --out FILE        write the results as JSON
;;;   --list            list the benchmarks and exit
;;;
;;; Three groups:
;;;   parse/*     escape-sequence parsing and grid updates (MB/s)
;;;   render/*    drawing frames of a dense colored screen (ms per frame)
;;;   pipeline/*  a real pty: `cat` a workload, parse it, render at 60 Hz (MB/s)
;;;
;;; All input is generated deterministically (bench/workloads.ss); the
;;; checksum of each workload is part of the results.  The renderer uses
;;; "DejaVu Sans Mono" at 11 pt / 96 dpi; the resolved cell size is recorded,
;;; so results from different fonts are recognisably different.
(import (chezscheme)
        (chezterm ffi) (chezterm grid) (chezterm terminal) (chezterm charwidth)
        (chezterm font) (chezterm render) (chezterm pty)
        (bench workloads))

;;; Options -----------------------------------------------------------------------

(define quick #f)
(define iterations 7)
(define only '())
(define out-file #f)
(define list-only #f)

(define (split-commas s)
  (let loop ([i 0] [start 0] [acc '()])
    (cond
      [(= i (string-length s)) (reverse (cons (substring s start i) acc))]
      [(char=? (string-ref s i) #\,) (loop (+ i 1) (+ i 1) (cons (substring s start i) acc))]
      [else (loop (+ i 1) start acc)])))

(let loop ([args (command-line-arguments)])
  (unless (null? args)
    (cond
      [(string=? (car args) "--quick") (set! quick #t) (loop (cdr args))]
      [(string=? (car args) "--list") (set! list-only #t) (loop (cdr args))]
      [(and (string=? (car args) "--iterations") (pair? (cdr args)))
       (set! iterations (string->number (cadr args))) (loop (cddr args))]
      [(and (string=? (car args) "--only") (pair? (cdr args)))
       (set! only (split-commas (cadr args))) (loop (cddr args))]
      [(and (string=? (car args) "--out") (pair? (cdr args)))
       (set! out-file (cadr args)) (loop (cddr args))]
      [else (printf "unknown argument ~a\n" (car args)) (exit 2)])))

(when quick (set! iterations (min iterations 2)))

(define parse-size (if quick (* 256 1024) (* 8 1024 1024)))
(define pipeline-size (if quick (* 256 1024) (* 16 1024 1024)))
(define render-frames (if quick 3 30))
(define warmup 1)

;;; Timing and statistics ------------------------------------------------------------

(define (now-ms)
  (let ([t (current-time 'time-monotonic)])
    (+ (* 1000.0 (time-second t)) (/ (time-nanosecond t) 1e6))))

(define (median xs)
  (let* ([v (list->vector (list-sort < xs))] [n (vector-length v)])
    (if (odd? n)
        (vector-ref v (quotient n 2))
        (/ (+ (vector-ref v (- (quotient n 2) 1)) (vector-ref v (quotient n 2))) 2.0))))

;; median absolute deviation, relative to the median, in percent
(define (mad-pct xs)
  (let ([m (median xs)])
    (if (zero? m) 0.0 (* 100.0 (/ (median (map (lambda (x) (abs (- x m))) xs)) m)))))

(define (round-to x digits)
  (let ([f (expt 10 digits)]) (/ (round (* x f)) (inexact f))))

;;; Benchmarks -------------------------------------------------------------------

;; A benchmark: NAME, UNIT, BETTER ('higher / 'lower), INFO (alist added to
;; the result), and RUN, a thunk performing one iteration and returning the
;; measured value.  SETUP runs once before the iterations and returns RUN.
(define-record-type bench (fields name group unit better setup))

(define benchmarks '())
(define (define-bench! b) (set! benchmarks (append benchmarks (list b))))

(define palette
  (make-default-palette '(#x181818 #xac4242 #x90a959 #xf4bf75 #x6a9fb5 #xaa759f #x75b5aa #xd8d8d8)
                        '(#x6b6b6b #xc55555 #xaac474 #xfeca88 #x82b8c8 #xc28cb8 #x93d3c3 #xf8f8f8)
                        #xd8d8d8 #x181818 #xd8d8d8))

(define (new-terminal cols rows)
  (let ([t (make-terminal rows cols 10000 palette 'block #f)])
    (terminal-set-callbacks! t void void void void)
    t))

(define (feed! t bv) (terminal-feed! t bv (bytevector-length bv)))

;; split BV into CHUNK-sized pieces, like pty reads
(define (chunks bv chunk)
  (let loop ([off 0] [acc '()])
    (if (>= off (bytevector-length bv))
        (reverse acc)
        (let* ([n (min chunk (- (bytevector-length bv) off))] [c (make-bytevector n)])
          (bytevector-copy! bv off c 0 n)
          (loop (+ off n) (cons c acc))))))

;;; parse/*

(define parse-cols 200)
(define parse-rows 50)

(for-each
 (lambda (name)
   (define-bench!
    (make-bench (format "parse/~a" name) "parse" "MB/s" 'higher
      (lambda ()
        (let* ([bv (make-workload name parse-size parse-cols parse-rows)]
               [pieces (chunks bv 65536)]
               [mb (/ (bytevector-length bv) 1048576.0)])
          (values
           (lambda ()
             (let ([t (new-terminal parse-cols parse-rows)])
               (collect)
               (let ([t0 (now-ms)])
                 (for-each (lambda (c) (terminal-feed! t c (bytevector-length c))) pieces)
                 (/ mb (/ (- (now-ms) t0) 1000.0)))))
           `(("bytes" . ,(bytevector-length bv))
             ("checksum" . ,(workload-checksum bv))
             ("terminal" . ,(format "~ax~a" parse-cols parse-rows))
             ("description" . ,(workload-description name)))))))))
 workload-names)

;;; render/*

(define font-family "DejaVu Sans Mono")
(define the-font #f)
(define (font)
  (unless the-font (set! the-font (make-font font-family 11.0 96.0 1 #f #f)))
  the-font)

;; a full screen of colored text, different for every frame number
(define (screenful cols rows frame)
  (let ([rng (make-rng (+ 1000 frame))] [out (open-output-string)])
    (put-string out "\x1b;[H")
    (do ([r 0 (+ r 1)]) ((= r rows))
      (put-string out (format "\x1b;[~a;1H" (+ r 1)))
      (do ([c 0 (+ c 1)]) ((= c cols))
        (when (= 0 (rng-int rng 12))
          (put-string out (format "\x1b;[~a;~am" (+ 30 (rng-int rng 8))
                                  (if (= 0 (rng-int rng 4)) (+ 40 (rng-int rng 8)) 49))))
        (write-char (integer->char (+ 33 (rng-int rng 94))) out)))
    (string->utf8 (get-output-string out))))

(define (render-setup cols rows)
  (let* ([f (font)]
         [t (new-terminal cols rows)]
         [r (make-renderer f 2 2 1.0 #f #f #x4f4f4f #t)])
    (renderer-resize! r (+ 4 (* cols (font-cell-width f))) (+ 4 (* rows (font-cell-height f))))
    (feed! t (screenful cols rows 0))
    (renderer-render! r t #t #t (lambda (a) '()) #f)
    (values t r)))

(define (render! t r) (renderer-render! r t #t #t (lambda (a) '()) #f))

;; time FRAMES frames; BEFORE runs untimed before each frame
(define (time-frames t r before)
  (collect)
  (let loop ([i 0] [total 0.0])
    (if (= i render-frames)
        (/ total render-frames)
        (begin
          (before i)
          (let ([t0 (now-ms)])
            (render! t r)
            (loop (+ i 1) (+ total (- (now-ms) t0))))))))

(for-each
 (lambda (size)
   (let* ([cols (car size)] [rows (cdr size)] [tag (format "~ax~a" cols rows)])
     (define (info t r)
       `(("cells" . ,tag)
         ("pixels" . ,(format "~ax~a" (renderer-width r) (renderer-height r)))))
     (define-bench!
      (make-bench (format "render/full-~a" tag) "render" "ms/frame" 'lower
        (lambda ()
          (let-values ([(t r) (render-setup cols rows)])
            (values (lambda () (time-frames t r (lambda (i) (renderer-invalidate! r))))
                    (cons '("description" . "redraw every pixel (window exposed, palette change)")
                          (info t r)))))))
     (define-bench!
      (make-bench (format "render/rows-~a" tag) "render" "ms/frame" 'lower
        (lambda ()
          (let-values ([(t r) (render-setup cols rows)])
            (let ([frames (list->vector (map (lambda (i) (screenful cols rows (+ i 1)))
                                             (iota render-frames)))])
              (values (lambda () (time-frames t r (lambda (i) (feed! t (vector-ref frames i)))))
                      (cons '("description" . "every row changed (full-screen application redraw)")
                            (info t r))))))))
     (define-bench!
      (make-bench (format "render/scroll-~a" tag) "render" "ms/frame" 'lower
        (lambda ()
          (let-values ([(t r) (render-setup cols rows)])
            (feed! t (string->utf8 (format "\x1b;[~a;1H" rows)))
            (values (lambda ()
                      (time-frames t r (lambda (i)
                                         (feed! t (string->utf8 (format "\r\nscrolled line ~a" i))))))
                    (cons '("description" . "output scrolled by one line")
                          (info t r)))))))
     (define-bench!
      (make-bench (format "render/cell-~a" tag) "render" "ms/frame" 'lower
        (lambda ()
          (let-values ([(t r) (render-setup cols rows)])
            (values (lambda ()
                      (time-frames t r (lambda (i)
                                         (feed! t (string->utf8 (format "\x1b;[10;10H~a" (if (odd? i) "x" "y")))))))
                    (cons '("description" . "one character changed (typing)")
                          (info t r)))))))))
 '((80 . 24) (250 . 75) (426 . 120)))

;;; pipeline/*

(define pipe-cols 250)
(define pipe-rows 75)

(define pollfd-buf (malloc (ftype-sizeof pollfd)))

(define (wait-readable fd ms)
  (let ([p (make-ftype-pointer pollfd pollfd-buf)])
    (ftype-set! pollfd (fd) p fd)
    (ftype-set! pollfd (events) p POLLIN)
    (ftype-set! pollfd (revents) p 0)
    (poll pollfd-buf 1 (max 0 (exact (ceiling ms))))))

(define tmp-dir (or (getenv "TMPDIR") "/tmp"))

;; Run `cat FILE` on a pty and feed everything to T, rendering with R at
;; most every 1/60 s.  Returns (values elapsed-ms frames).
(define (run-pipeline t r file)
  (let-values ([(fd pid) (pty-spawn (list "cat" file) pipe-rows pipe-cols 0 0 #f '())])
    (let ([buf (make-bytevector 65536)] [t0 (now-ms)] [frame-ms (/ 1000.0 60)])
      (define (read-available)
        ;; up to 1 MiB, like the event loop; #t at end of file
        (let loop ([k 0])
          (and (< k 16)
               (let ([m (pty-read fd buf)])
                 (cond [(not m) #t]
                       [(= m 0) #f]
                       [else (terminal-feed! t buf m) (loop (+ k 1))])))))
      (let loop ([next-frame (+ t0 frame-ms)] [frames 0])
        (wait-readable fd (- next-frame (now-ms)))
        (let* ([eof (read-available)]
               [due (>= (now-ms) next-frame)])
          (when (or eof due) (render! t r))
          (if eof
              (begin
                (close fd)
                (pty-child-exited? pid)
                (values (- (now-ms) t0) (+ frames 1)))
              (loop (if due (+ (now-ms) frame-ms) next-frame)
                    (if due (+ frames 1) frames))))))))

(for-each
 (lambda (name)
   (define-bench!
    (make-bench (format "pipeline/~a" name) "pipeline" "MB/s" 'higher
      (lambda ()
        (let* ([bv (make-workload name pipeline-size pipe-cols pipe-rows)]
               [file (format "~a/chezterm-bench-~a.bin" tmp-dir name)]
               [mb (/ (bytevector-length bv) 1048576.0)])
          (call-with-port (open-file-output-port file (file-options no-fail))
            (lambda (p) (put-bytevector p bv)))
          (values
           (lambda ()
             (let-values ([(t r) (render-setup pipe-cols pipe-rows)])
               (collect)
               (let-values ([(ms frames) (run-pipeline t r file)])
                 (/ mb (/ ms 1000.0)))))
           `(("bytes" . ,(bytevector-length bv))
             ("checksum" . ,(workload-checksum bv))
             ("terminal" . ,(format "~ax~a" pipe-cols pipe-rows))
             ("description" . ,(string-append "cat through a pty, rendering at 60 Hz: "
                                              (workload-description name))))))))))
 '(ascii sgr unicode))

;;; Environment -----------------------------------------------------------------------

(define (read-file-line path prefix)
  (guard (e [#t #f])
    (call-with-input-file path
      (lambda (p)
        (let loop ()
          (let ([l (get-line p)])
            (cond
              [(eof-object? l) #f]
              [(and (>= (string-length l) (string-length prefix))
                    (string=? (substring l 0 (string-length prefix)) prefix))
               (let ([i (let find ([i 0]) (if (and (< i (string-length l)) (not (char=? (string-ref l i) #\:)))
                                             (find (+ i 1)) i))])
                 (if (< i (string-length l))
                     (let trim ([s (substring l (+ i 1) (string-length l))])
                       (if (and (> (string-length s) 0) (char=? (string-ref s 0) #\space))
                           (trim (substring s 1 (string-length s)))
                           s))
                     l))]
              [else (loop)])))))))

(define (command-output cmd)
  (guard (e [#t #f])
    (let-values ([(to from err pid) (open-process-ports cmd (buffer-mode block) (native-transcoder))])
      (close-port to)
      (let ([s (get-line from)])
        (close-port from) (close-port err)
        (and (string? s) (> (string-length s) 0) s)))))

(define (environment-info)
  (let ([f (font)])
    `(("date" . ,(date-and-time))
      ("revision" . ,(or (getenv "BENCH_REV") (command-output "git rev-parse --short HEAD 2>/dev/null") "unknown"))
      ("chez" . ,(scheme-version))
      ("machine" . ,(symbol->string (machine-type)))
      ("cpu" . ,(or (read-file-line "/proc/cpuinfo" "model name") "unknown"))
      ("cpus" . ,(or (command-output "nproc 2>/dev/null") "unknown"))
      ("kernel" . ,(or (read-file-line "/proc/version" "Linux") "unknown"))
      ("font" . ,font-family)
      ("cell" . ,(format "~ax~a" (font-cell-width f) (font-cell-height f)))
      ("quick" . ,quick)
      ("iterations" . ,iterations))))

;;; JSON output ---------------------------------------------------------------------

(define (write-json x p)
  (cond
    [(eq? x #t) (put-string p "true")]
    [(eq? x #f) (put-string p "false")]
    [(null? x) (put-string p "[]")]
    [(string? x)
     (put-char p #\")
     (string-for-each
      (lambda (c)
        (cond [(char=? c #\") (put-string p "\\\"")]
              [(char=? c #\\) (put-string p "\\\\")]
              [(char<? c #\space) (put-string p (format "\\u~4,'0x" (char->integer c)))]
              [else (put-char p c)]))
      x)
     (put-char p #\")]
    [(symbol? x) (write-json (symbol->string x) p)]
    [(and (number? x) (exact? x)) (put-string p (number->string x))]
    [(number? x) (put-string p (number->string (round-to x 4)))]
    [(and (pair? x) (pair? (car x)) (string? (caar x)))    ; object
     (put-char p #\{)
     (let loop ([es x] [first #t])
       (unless (null? es)
         (unless first (put-string p ", "))
         (write-json (caar es) p)
         (put-string p ": ")
         (write-json (cdar es) p)
         (loop (cdr es) #f)))
     (put-char p #\})]
    [(list? x)
     (put-char p #\[)
     (let loop ([es x] [first #t])
       (unless (null? es)
         (unless first (put-string p ",\n  "))
         (write-json (car es) p)
         (loop (cdr es) #f)))
     (put-char p #\])]
    [else (errorf 'write-json "cannot encode ~s" x)]))

;;; Main --------------------------------------------------------------------------

(define (selected? b)
  (or (null? only)
      (exists (lambda (o)
                (let ([n (bench-name b)])
                  (let loop ([i 0])
                    (and (<= (+ i (string-length o)) (string-length n))
                         (or (string=? (substring n i (+ i (string-length o))) o)
                             (loop (+ i 1)))))))
              only)))

(when list-only
  (for-each (lambda (b) (printf "~a (~a)\n" (bench-name b) (bench-unit b))) benchmarks)
  (exit 0))

(init-charwidth!)

(define (fmt x) (format "~8,2f" x))

(printf "chezterm benchmarks~a: ~a iterations each\n\n" (if quick " (quick)" "") iterations)
(printf "~32a ~10a ~8@a ~8@a ~8@a ~7@a\n" "benchmark" "unit" "median" "min" "max" "±%")

(define results
  (let loop ([bs (filter selected? benchmarks)] [acc '()])
    (if (null? bs)
        (reverse acc)
        (let ([b (car bs)])
          (let-values ([(run info) ((bench-setup b))])
            (do ([i 0 (+ i 1)]) ((= i warmup)) (run))
            (let* ([samples (let s ([i 0] [acc '()])
                              (if (= i iterations) (reverse acc) (s (+ i 1) (cons (run) acc))))]
                   [m (median samples)])
              (printf "~32a ~10a ~a ~a ~a ~7,1f\n" (bench-name b) (bench-unit b)
                      (fmt m) (fmt (apply min samples)) (fmt (apply max samples)) (mad-pct samples))
              (flush-output-port (current-output-port))
              (loop (cdr bs)
                    (cons `(("name" . ,(bench-name b))
                            ("group" . ,(bench-group b))
                            ("unit" . ,(bench-unit b))
                            ("better" . ,(symbol->string (bench-better b)))
                            ("median" . ,m)
                            ("min" . ,(apply min samples))
                            ("max" . ,(apply max samples))
                            ("mad_pct" . ,(mad-pct samples))
                            ("samples" . ,samples)
                            ,@info)
                          acc))))))))

(when out-file
  (call-with-output-file out-file
    (lambda (p)
      (write-json `(("format" . 1)
                    ("environment" . ,(environment-info))
                    ("results" . ,results))
                  p)
      (newline p))
    'replace)
  (printf "\nwrote ~a\n" out-file))
