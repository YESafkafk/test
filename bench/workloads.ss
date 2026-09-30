;;; Deterministic benchmark workloads.
;;;
;;; Every workload is generated from a fixed seed with a portable linear
;;; congruential generator, so it is byte-identical on every machine and
;;; run.  (workload-checksum bv) identifies the bytes in benchmark results.
(library (bench workloads)
  (export workload-names make-workload workload-description workload-checksum
          make-rng rng-int)
  (import (chezscheme))

  ;;; Random numbers -------------------------------------------------------------

  ;; 31-bit LCG (the constants of the classic ANSI C rand)
  (define (make-rng seed) (box (fxand seed #x7FFFFFFF)))

  (define (rng-int rng n)
    (let ([s (bitwise-and (+ (* (unbox rng) 1103515245) 12345) #x7FFFFFFF)])
      (set-box! rng s)
      (fxremainder (fxsrl s 8) n)))

  ;; FNV-1a (32 bit) over the bytes
  (define (workload-checksum bv)
    (let loop ([i 0] [h #x811C9DC5])
      (if (fx= i (bytevector-length bv))
          (number->string h 16)
          (loop (fx+ i 1)
                (bitwise-and (* (bitwise-xor h (bytevector-u8-ref bv i)) #x01000193) #xFFFFFFFF)))))

  ;;; Building output -------------------------------------------------------------

  ;; Collect output until SIZE bytes have been produced, then truncate.
  (define (generate size emit!)
    (let-values ([(port extract) (open-bytevector-output-port)])
      (let loop ()
        (when (< (port-position port) size)
          (emit! port)
          (loop)))
      (let* ([bv (extract)] [out (make-bytevector size)])
        (bytevector-copy! bv 0 out 0 size)
        out)))

  (define (put port s) (put-bytevector port (string->utf8 s)))

  (define (ascii-char rng) (integer->char (+ 33 (rng-int rng 94))))

  (define (words rng n)
    ;; N characters of printable ASCII broken into words
    (let ([out (open-output-string)])
      (do ([i 0 (+ i 1)]) ((= i n) (get-output-string out))
        (write-char (if (= 0 (rng-int rng 7)) #\space (ascii-char rng)) out))))

  (define unicode-pool
    ;; accented Latin, Greek, Cyrillic, CJK (wide), emoji (wide), box drawing
    (list->vector
     (map (lambda (s) (list->string (map integer->char s)))
          '((#xE9) (#xFC) (#xF1) (#x3B1) (#x3C9) (#x436) (#x44F) (#x65E5) (#x672C)
            (#x8A9E) (#x6F22) (#x5B57) (#xD55C) (#x1F600) (#x1F680) (#x2764)
            (#x2500) (#x2502) (#x250C) (#x2593) (#x65 #x301) (#x61 #x308)))))

  ;;; Workloads -------------------------------------------------------------------

  (define descriptions
    '((ascii . "lines of printable ASCII, scrolling")
      (unicode . "mixed ASCII, accented, CJK, emoji, combining marks, box drawing")
      (sgr . "text with frequent SGR changes: 16, 256 and 24-bit colors, attributes")
      (cursor . "cursor positioning and short writes, erase in line (full-screen TUI)")
      (scroll-region . "scrolling inside a DECSTBM region, reverse index")
      (alt-screen . "full-screen redraws on the alternate screen, synchronized updates")))

  (define workload-names (map car descriptions))

  (define (workload-description name) (cdr (assq name descriptions)))

  ;; Workload NAME of SIZE bytes for a COLS x ROWS terminal.
  (define (make-workload name size cols rows)
    (let ([rng (make-rng (+ 42 (string-length (symbol->string name))))])
      (case name
        [(ascii)
         (generate size
           (lambda (p) (put p (words rng (+ 1 (rng-int rng (- cols 1))))) (put p "\r\n")))]
        [(unicode)
         (generate size
           (lambda (p)
             (do ([i (+ 5 (rng-int rng 60)) (- i 1)]) ((= i 0))
               (put p (if (= 0 (rng-int rng 3))
                          (vector-ref unicode-pool (rng-int rng (vector-length unicode-pool)))
                          (string (ascii-char rng)))))
             (put p "\r\n")))]
        [(sgr)
         (generate size
           (lambda (p)
             (do ([i (+ 3 (rng-int rng 12)) (- i 1)]) ((= i 0))
               (put p (case (rng-int rng 6)
                        [(0) (format "\x1b;[~am" (+ 30 (rng-int rng 8)))]
                        [(1) (format "\x1b;[38;5;~a;48;5;~am" (rng-int rng 256) (rng-int rng 256))]
                        [(2) (format "\x1b;[38;2;~a;~a;~am" (rng-int rng 256) (rng-int rng 256) (rng-int rng 256))]
                        [(3) (format "\x1b;[~a;~am" (+ 1 (rng-int rng 4)) (+ 90 (rng-int rng 8)))]
                        [(4) "\x1b;[0m"]
                        [else "\x1b;[4:3;58;5;196m"]))
               (put p (words rng (+ 2 (rng-int rng 10)))))
             (put p "\x1b;[0m\r\n")))]
        [(cursor)
         (generate size
           (lambda (p)
             (put p (format "\x1b;[~a;~aH" (+ 1 (rng-int rng rows)) (+ 1 (rng-int rng cols))))
             (when (= 0 (rng-int rng 4)) (put p "\x1b;[K"))
             (put p (words rng (+ 1 (rng-int rng 20))))))]
        [(scroll-region)
         (generate size
           (lambda (p)
             (put p (format "\x1b;[~a;~ar\x1b;[~aH" 3 (- rows 3) (- rows 3)))
             (do ([i 40 (- i 1)]) ((= i 0))
               (put p (words rng (+ 1 (rng-int rng 60))))
               (put p (if (= 0 (rng-int rng 10)) "\x1b;M" "\r\n")))
             (put p "\x1b;[r")))]
        [(alt-screen)
         (generate size
           (lambda (p)
             (put p "\x1b;[?1049h\x1b;[?2026h\x1b;[H")
             (do ([r 0 (+ r 1)]) ((= r rows))
               (put p (format "\x1b;[~a;1H\x1b;[~a;~am" (+ r 1) (+ 30 (rng-int rng 8)) (+ 40 (rng-int rng 8))))
               (put p (words rng (- cols 1))))
             (put p "\x1b;[0m\x1b;[?2026l")))]
        [else (errorf 'make-workload "unknown workload ~s" name)]))))
