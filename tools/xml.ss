;;; Tiny non-validating XML reader, sufficient for Wayland protocol files.
;;; Elements are returned as (tag ((attr . value) ...) child ...); text nodes
;;; are returned as strings.  Comments, processing instructions and DOCTYPE
;;; declarations are skipped.
(library (xml)
  (export xml-read xml-read-file xml-tag xml-attr xml-children xml-elements)
  (import (chezscheme))

  (define (decode-entities s)
    (let ([out (open-output-string)] [n (string-length s)])
      (let loop ([i 0])
        (cond
          [(= i n) (get-output-string out)]
          [(char=? (string-ref s i) #\&)
           (let find ([j i])
             (cond
               [(= j n) (put-string out (substring s i n)) (get-output-string out)]
               [(char=? (string-ref s j) #\;)
                (let ([ent (substring s (+ i 1) j)])
                  (cond
                    [(string=? ent "lt") (write-char #\< out)]
                    [(string=? ent "gt") (write-char #\> out)]
                    [(string=? ent "amp") (write-char #\& out)]
                    [(string=? ent "quot") (write-char #\" out)]
                    [(string=? ent "apos") (write-char #\' out)]
                    [(and (> (string-length ent) 1) (char=? (string-ref ent 0) #\#))
                     (write-char
                      (integer->char
                       (if (char=? (string-ref ent 1) #\x)
                           (string->number (substring ent 2 (string-length ent)) 16)
                           (string->number (substring ent 1 (string-length ent)))))
                      out)]
                    [else (put-string out (string-append "&" ent ";"))])
                  (loop (+ j 1)))]
               [else (find (+ j 1))]))]
          [else (write-char (string-ref s i) out) (loop (+ i 1))]))))

  (define (name-char? c)
    (and (char? c)
         (or (char-alphabetic? c) (char-numeric? c) (memv c '(#\- #\_ #\: #\.)))))

  (define (skip-ws p)
    (let ([c (peek-char p)])
      (when (and (char? c) (char-whitespace? c)) (read-char p) (skip-ws p))))

  (define (read-name p)
    (let ([out (open-output-string)])
      (let loop ()
        (when (name-char? (peek-char p))
          (write-char (read-char p) out)
          (loop)))
      (get-output-string out)))

  ;; skip until the given terminator string has been consumed
  (define (skip-until p term)
    (let ([n (string-length term)])
      (let loop ([matched 0])
        (unless (= matched n)
          (let ([c (read-char p)])
            (cond
              [(eof-object? c) (error 'xml-read "unexpected end of input")]
              [(char=? c (string-ref term matched)) (loop (+ matched 1))]
              [(char=? c (string-ref term 0)) (loop 1)]
              [else (loop 0)]))))))

  (define (read-attrs p)
    (let loop ([acc '()])
      (skip-ws p)
      (let ([c (peek-char p)])
        (if (name-char? c)
            (let ([name (read-name p)])
              (skip-ws p)
              (unless (eqv? (read-char p) #\=) (error 'xml-read "expected = in attribute"))
              (skip-ws p)
              (let ([q (read-char p)] [out (open-output-string)])
                (let vloop ()
                  (let ([c (read-char p)])
                    (unless (eqv? c q)
                      (write-char c out)
                      (vloop))))
                (loop (cons (cons (string->symbol name) (decode-entities (get-output-string out)))
                            acc))))
            (reverse acc)))))

  ;; Read one node after "<" has been consumed.  Returns an element, or #f for
  ;; skipped constructs, or (end . name) for a closing tag.
  (define (read-markup p)
    (let ([c (peek-char p)])
      (cond
        [(eqv? c #\?) (skip-until p "?>") #f]
        [(eqv? c #\!)
         (read-char p)
         (if (eqv? (peek-char p) #\-)
             (begin (skip-until p "-->") #f)
             (begin (skip-until p ">") #f))]
        [(eqv? c #\/)
         (read-char p)
         (let ([name (read-name p)])
           (skip-until p ">")
           (cons 'end name))]
        [else
         (let* ([name (string->symbol (read-name p))]
                [attrs (read-attrs p)])
           (skip-ws p)
           (let ([c (read-char p)])
             (cond
               [(eqv? c #\/) (read-char p) (list name attrs)]
               [(eqv? c #\>) (cons* name attrs (read-content p))]
               [else (errorf 'xml-read "bad tag ~a" name)])))])))

  (define (read-content p)
    (let loop ([acc '()])
      (let ([c (peek-char p)])
        (cond
          [(eof-object? c) (reverse acc)]
          [(char=? c #\<)
           (read-char p)
           (let ([node (read-markup p)])
             (cond
               [(not node) (loop acc)]
               [(and (pair? node) (eq? (car node) 'end)) (reverse acc)]
               [else (loop (cons node acc))]))]
          [else
           (let ([out (open-output-string)])
             (let tloop ()
               (let ([c (peek-char p)])
                 (unless (or (eof-object? c) (char=? c #\<))
                   (write-char (read-char p) out)
                   (tloop))))
             (loop (cons (decode-entities (get-output-string out)) acc)))]))))

  (define (xml-read p)
    (let ([nodes (read-content p)])
      (find pair? nodes)))

  (define (xml-read-file path) (call-with-input-file path xml-read))

  (define (xml-tag e) (car e))
  (define (xml-attr e name . default)
    (let ([a (assq name (cadr e))])
      (cond [a (cdr a)] [(pair? default) (car default)] [else #f])))
  (define (xml-children e) (cddr e))
  (define (xml-elements e tag)
    (filter (lambda (c) (and (pair? c) (eq? (car c) tag))) (xml-children e))))
