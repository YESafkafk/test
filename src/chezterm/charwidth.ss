;;; Display width of Unicode code points (0, 1 or 2 cells).
;;; Uses the C library's wcwidth() under a UTF-8 locale, cached per code point.
(library (chezterm charwidth)
  (export char-width init-charwidth!)
  (import (chezscheme) (chezterm ffi))

  (define cache (make-bytevector #x110000 255))

  (define (init-charwidth!)
    (unless (exists (lambda (loc) (not (eqv? 0 (setlocale LC_CTYPE loc))))
                    '("C.UTF-8" "C.utf8" "en_US.UTF-8" ""))
      (display "chezterm: warning: no UTF-8 locale available\n" (current-error-port))))

  (define (compute cp)
    (cond
      [(fx< cp #x20) 0]
      [(fx< cp #x7f) 1]
      [(fx< cp #xa0) 0]
      ;; zero width joiner / variation selectors are combining
      [(or (fx= cp #x200d) (fx<= #xfe00 cp #xfe0f)) 0]
      [else
       (let ([w (wcwidth cp)])
         (cond
           [(fx< w 0) 1]        ; unassigned / private use: occupy one cell
           [(fx> w 2) 2]
           [else w]))]))

  (define (char-width cp)
    (if (fx< cp #x7f)
        (if (fx>= cp #x20) 1 0)
        (let ([w (bytevector-u8-ref cache cp)])
          (if (fx= w 255)
              (let ([w (compute cp)])
                (bytevector-u8-set! cache cp w)
                w)
              w)))))
