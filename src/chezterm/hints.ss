;;; Keyboard hints: labels for the targets on screen (see hint-targets in
;;; selection.ss) and the keys typed to pick one of them.  Everything here
;;; is pure; app.ss keeps the state, draws it and runs the actions.
(library (chezterm hints)
  (export default-hint-alphabet valid-hint-alphabet? hint-labels
          hint-state? hint-state-action hint-state-targets hint-state-labels hint-state-typed
          hint-start hint-update hint-key hint-visible hint-label-cells)
  (import (chezscheme) (chezterm selection))

  (define default-hint-alphabet "jfkdls;ahgurieowpq")

  ;; An alphabet needs at least two characters, all different (otherwise
  ;; the labels would not be prefix-free), and printable.
  (define (valid-hint-alphabet? a)
    (and (string? a)
         (>= (string-length a) 2)
         (let loop ([cs (string->list a)])
           (or (null? cs)
               (and (char<? #\space (car cs))
                    (not (char=? (car cs) #\delete))
                    (not (memv (car cs) (cdr cs)))
                    (loop (cdr cs)))))))

  ;; N labels made of ALPHABET's characters, as Alacritty generates them.
  ;; The first half of the alphabet (rounded down, of all but one) is only
  ;; used for the last character of a label and the rest only for the
  ;; others, so no label is a prefix of another.  The first labels are one
  ;; character long; once those run out, labels grow a character at a time.
  ;; With the default alphabet: j f k d l s ; a h gj gf ... gh uj ... qh ggj ...
  (define (hint-labels alphabet n)
    (let* ([chars (list->vector (string->list alphabet))]
           [len (vector-length chars)]
           [split (quotient (- len 1) 2)])
      (let loop ([k 0] [indices '(0)] [acc '()])
        ;; INDICES: the alphabet indices of the next label, last character first
        (if (= k n)
            (reverse acc)
            (loop (+ k 1)
                  (if (< (car indices) split)
                      (cons (+ (car indices) 1) (cdr indices))
                      (cons 0 (let next ([rest (cdr indices)])
                                (cond
                                  [(null? rest) (list (+ split 1))]
                                  [(= (+ (car rest) 1) len) (cons (+ split 1) (next (cdr rest)))]
                                  [else (cons (+ (car rest) 1) (cdr rest))]))))
                  (cons (list->string (map (lambda (i) (vector-ref chars i)) (reverse indices))) acc))))))

  ;; ACTION is what picking a target does (hint-open, hint-copy or
  ;; hint-select), TARGETS a vector in reading order, LABELS the vector of
  ;; their labels, TYPED the keys typed so far.
  (define-record-type hint-state (fields action alphabet targets labels typed))

  ;; The shortest labels go to the last targets, those nearest the bottom
  ;; of the screen, as in Alacritty.
  (define (make-state action alphabet targets typed)
    (and (pair? targets)
         (make-hint-state action alphabet (list->vector targets)
                          (list->vector (reverse (hint-labels alphabet (length targets))))
                          typed)))

  ;; Hint mode for ACTION over TARGETS (a list, as from hint-targets), or
  ;; #f when there are none.
  (define (hint-start action alphabet targets)
    (make-state action alphabet targets ""))

  ;; The same hint mode over new TARGETS (the screen changed), keeping the
  ;; keys typed so far; #f when there are none left.
  (define (hint-update state targets)
    (make-state (hint-state-action state) (hint-state-alphabet state) targets (hint-state-typed state)))

  (define (prefix? p s)
    (and (<= (string-length p) (string-length s))
         (string=? p (substring s 0 (string-length p)))))

  ;; Handle KEY: a character typed, 'backspace, 'escape, or anything else
  ;; (ignored).  Returns two values: the new state, #f when hint mode ends,
  ;; and the target picked, or #f.  A character that no label continues
  ;; with is ignored.
  (define (hint-key state key)
    (let ([typed (hint-state-typed state)])
      (cond
        [(eq? key 'escape) (values #f #f)]
        [(eq? key 'backspace)
         (values (if (= 0 (string-length typed))
                     state
                     (make-hint-state (hint-state-action state) (hint-state-alphabet state)
                                      (hint-state-targets state) (hint-state-labels state)
                                      (substring typed 0 (- (string-length typed) 1))))
                 #f)]
        [(char? key)
         (let* ([keys (string-append typed (string key))]
                [labels (hint-state-labels state)]
                [n (vector-length labels)]
                [exact (let loop ([i 0])
                         (cond [(= i n) #f]
                               [(string=? keys (vector-ref labels i)) i]
                               [else (loop (+ i 1))]))])
           (cond
             [exact (values #f (vector-ref (hint-state-targets state) exact))]
             [(exists (lambda (l) (prefix? keys l)) (vector->list labels))
              (values (make-hint-state (hint-state-action state) (hint-state-alphabet state)
                                       (hint-state-targets state) labels keys)
                      #f)]
             [else (values state #f)]))]
        [else (values state #f)])))

  ;; The targets whose label still matches, as a list of (target . label).
  (define (hint-visible state)
    (let ([typed (hint-state-typed state)] [labels (hint-state-labels state)])
      (let loop ([i (- (vector-length labels) 1)] [acc '()])
        (if (< i 0)
            acc
            (loop (- i 1)
                  (if (prefix? typed (vector-ref labels i))
                      (cons (cons (vector-ref (hint-state-targets state) i) (vector-ref labels i)) acc)
                      acc))))))

  ;; Where the labels go in a terminal with COLS columns: a hashtable from
  ;; absolute rows to lists of (c0 c1 text typed), the renderer's label
  ;; highlights.  A label covers the cells from its target's first visible
  ;; cell on, continuing on the next row at the right edge; TEXT is the part
  ;; of the label in columns [c0, c1), TYPED how many of its characters have
  ;; been typed.  Entries are in reading order, so where a long label runs
  ;; into the next target's label, the next one is drawn over it.
  (define (hint-label-cells state cols)
    (let ([table (make-eqv-hashtable)] [typed (string-length (hint-state-typed state))])
      (for-each
       (lambda (v)
         (let ([label (cdr v)] [pos (target-label (car v))])
           (let loop ([abs (car pos)] [col (cdr pos)] [off 0])
             (when (< off (string-length label))
               (let ([n (min (- cols col) (- (string-length label) off))])
                 (hashtable-update! table abs
                                    (lambda (l)
                                      (append l (list (list col (+ col n) (substring label off (+ off n))
                                                            (max 0 (min n (- typed off)))))))
                                    '())
                 (loop (+ abs 1) 0 (+ off n)))))))
       (hint-visible state))
      table)))
