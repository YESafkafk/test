;;; Minimal JSON reader used to consume c2ffi output.
;;; Objects become association lists with string keys, arrays become lists.
(library (json)
  (export json-read json-read-file jref jref*)
  (import (chezscheme))

  (define (skip-ws p)
    (let ([c (peek-char p)])
      (when (and (char? c) (char-whitespace? c))
        (read-char p)
        (skip-ws p))))

  (define (expect p ch)
    (let ([c (read-char p)])
      (unless (eqv? c ch)
        (errorf 'json-read "expected ~s, got ~s" ch c))))

  (define (read-hex4 p)
    (let loop ([i 0] [n 0])
      (if (= i 4)
          n
          (loop (+ i 1) (+ (* n 16) (string->number (string (read-char p)) 16))))))

  (define (read-string-lit p)
    (expect p #\")
    (let ([out (open-output-string)])
      (let loop ()
        (let ([c (read-char p)])
          (cond
            [(eof-object? c) (error 'json-read "unterminated string")]
            [(char=? c #\") (get-output-string out)]
            [(char=? c #\\)
             (let ([e (read-char p)])
               (case e
                 [(#\n) (write-char #\newline out)]
                 [(#\t) (write-char #\tab out)]
                 [(#\r) (write-char #\return out)]
                 [(#\b) (write-char #\backspace out)]
                 [(#\f) (write-char #\page out)]
                 [(#\u)
                  (let ([n (read-hex4 p)])
                    (write-char (if (<= #xD800 n #xDFFF) #\xFFFD (integer->char n)) out))]
                 [else (write-char e out)])
               (loop))]
            [else (write-char c out) (loop)])))))

  (define (read-number p)
    (let ([out (open-output-string)])
      (let loop ()
        (let ([c (peek-char p)])
          (when (and (char? c) (memv c '(#\- #\+ #\. #\e #\E #\0 #\1 #\2 #\3 #\4 #\5 #\6 #\7 #\8 #\9)))
            (write-char (read-char p) out)
            (loop))))
      (let ([n (string->number (get-output-string out))])
        (unless n (error 'json-read "bad number"))
        n)))

  (define (read-word p w val)
    (string-for-each (lambda (ch) (expect p ch)) w)
    val)

  (define (json-read p)
    (skip-ws p)
    (let ([c (peek-char p)])
      (cond
        [(eof-object? c) c]
        [(char=? c #\{)
         (read-char p)
         (skip-ws p)
         (if (eqv? (peek-char p) #\})
             (begin (read-char p) '())
             (let loop ([acc '()])
               (skip-ws p)
               (let ([k (read-string-lit p)])
                 (skip-ws p)
                 (expect p #\:)
                 (let ([v (json-read p)])
                   (skip-ws p)
                   (let ([c (read-char p)])
                     (case c
                       [(#\,) (loop (cons (cons k v) acc))]
                       [(#\}) (reverse (cons (cons k v) acc))]
                       [else (errorf 'json-read "bad object delimiter ~s" c)]))))))]
        [(char=? c #\[)
         (read-char p)
         (skip-ws p)
         (if (eqv? (peek-char p) #\])
             (begin (read-char p) '())
             (let loop ([acc '()])
               (let ([v (json-read p)])
                 (skip-ws p)
                 (let ([c (read-char p)])
                   (case c
                     [(#\,) (loop (cons v acc))]
                     [(#\]) (reverse (cons v acc))]
                     [else (errorf 'json-read "bad array delimiter ~s" c)])))))]
        [(char=? c #\") (read-string-lit p)]
        [(char=? c #\t) (read-word p "true" #t)]
        [(char=? c #\f) (read-word p "false" #f)]
        [(char=? c #\n) (read-word p "null" 'null)]
        [else (read-number p)])))

  (define (json-read-file path)
    (call-with-input-file path json-read))

  (define (jref obj key . default)
    (let ([a (and (list? obj) (assoc key obj))])
      (cond [a (cdr a)]
            [(pair? default) (car default)]
            [else #f])))

  ;; (jref* obj "a" "b") == (jref (jref obj "a") "b")
  (define (jref* obj . keys)
    (fold-left (lambda (o k) (and o (jref o k))) obj keys)))
