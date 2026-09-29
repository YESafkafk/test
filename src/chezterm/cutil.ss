;;; Small helpers for working with C memory through the generated bindings.
(library (chezterm cutil)
  (export cstring->string string->cstring errno errno-string
          with-cstring bytes->cstring ptr-null? ptr-or-false)
  (import (chezscheme) (chezterm ffi))

  (define (ptr-null? p) (or (not p) (eqv? p 0)))
  (define (ptr-or-false p) (if (eqv? p 0) #f p))

  ;; Copy a NUL-terminated UTF-8 C string into a Scheme string.
  (define (cstring->string p)
    (if (ptr-null? p)
        #f
        (let* ([n (strlen p)] [bv (make-bytevector n)])
          (do ([i 0 (fx+ i 1)]) ((fx= i n))
            (bytevector-u8-set! bv i (foreign-ref 'unsigned-8 p i)))
          (utf8->string bv))))

  (define (bytes->cstring bv)
    (let* ([n (bytevector-length bv)] [p (malloc (+ n 1))])
      (do ([i 0 (fx+ i 1)]) ((fx= i n))
        (foreign-set! 'unsigned-8 p i (bytevector-u8-ref bv i)))
      (foreign-set! 'unsigned-8 p n 0)
      p))

  ;; Allocate a malloc'd UTF-8 copy of a Scheme string (caller frees).
  (define (string->cstring s) (bytes->cstring (string->utf8 s)))

  (define (with-cstring s proc)
    (let ([p (string->cstring s)])
      (dynamic-wind void (lambda () (proc p)) (lambda () (free p)))))

  (define (errno) (foreign-ref 'int (__errno_location) 0))
  (define (errno-string) (cstring->string (strerror (errno)))))
