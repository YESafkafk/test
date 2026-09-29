;;; Built-in rendering of box drawing (U+2500-U+257F), block elements
;;; (U+2580-U+259F) and powerline separators (U+E0B0-U+E0B3), so they join
;;; seamlessly between cells regardless of the font.
;;;
;;; (boxdraw-glyph cp width height thickness) returns an alpha bytevector of
;;; width*height bytes, or #f if the code point is not handled.
(library (chezterm boxdraw)
  (export boxdraw-glyph boxdraw-char?)
  (import (chezscheme))

  (define (boxdraw-char? cp)
    (or (fx<= #x2500 cp #x259F) (fx<= #xE0B0 cp #xE0B3)))

  ;; Line weights for U+2500..U+257F: up down left right,
  ;; 0 none, 1 light, 2 heavy, 3 double.
  (define box-table
    '#("0011" "0022" "1100" "2200" "0011" "0022" "1100" "2200"
       "0011" "0022" "1100" "2200" "0101" "0102" "0201" "0202"
       "0110" "0120" "0210" "0220" "1001" "1002" "2001" "2002"
       "1010" "1020" "2010" "2020" "1101" "1102" "2101" "1201"
       "2201" "2102" "1202" "2202" "1110" "1120" "2110" "1210"
       "2210" "2120" "1220" "2220" "0111" "0121" "0112" "0122"
       "0211" "0221" "0212" "0222" "1011" "1021" "1012" "1022"
       "2011" "2021" "2012" "2022" "1111" "1121" "1112" "1122"
       "2111" "1211" "2211" "2121" "2112" "1221" "1212" "2122"
       "1222" "2221" "2212" "2222" "0011" "0022" "1100" "2200"
       "0033" "3300" "0103" "0301" "0303" "0130" "0310" "0330"
       "1003" "3001" "3003" "1030" "3010" "3030" "1103" "3301"
       "3303" "1130" "3310" "3330" "0133" "0311" "0333" "1033"
       "3011" "3033" "1133" "3311" "3333" "0101" "0110" "1010"
       "1001" "0000" "0000" "0000" "0010" "1000" "0001" "0100"
       "0020" "2000" "0002" "0200" "0012" "1200" "0021" "2100"))

  ;; dashed variants: code point -> number of dashes
  (define (dashes cp)
    (case cp
      [(#x2504 #x2505 #x2506 #x2507) 3]
      [(#x2508 #x2509 #x250A #x250B) 4]
      [(#x254C #x254D #x254E #x254F) 2]
      [else 0]))

  (define (make-canvas w h) (make-bytevector (fx* w h) 0))

  (define (fill-rect! bv w h x0 y0 x1 y1 a)
    (let ([x0 (fxmax 0 x0)] [y0 (fxmax 0 y0)] [x1 (fxmin w x1)] [y1 (fxmin h y1)])
      (do ([y y0 (fx+ y 1)]) ((fx>= y y1))
        (do ([x x0 (fx+ x 1)]) ((fx>= x x1))
          (bytevector-u8-set! bv (fx+ x (fx* y w)) a)))))

  ;; Anti-aliased shape: coverage computed by 4x4 supersampling of INSIDE?.
  (define (fill-shape! bv w h inside?)
    (do ([y 0 (fx+ y 1)]) ((fx= y h))
      (do ([x 0 (fx+ x 1)]) ((fx= x w))
        (let loop ([sy 0] [n 0])
          (if (fx= sy 4)
              (when (fx> n 0)
                (let* ([i (fx+ x (fx* y w))]
                       [a (fxmin 255 (fx+ (bytevector-u8-ref bv i) (fxquotient (fx* n 255) 16)))])
                  (bytevector-u8-set! bv i a)))
              (loop (fx+ sy 1)
                    (let sx-loop ([sx 0] [n n])
                      (if (fx= sx 4)
                          n
                          (sx-loop (fx+ sx 1)
                                   (if (inside? (+ x (/ (+ sx 0.5) 4.0)) (+ y (/ (+ sy 0.5) 4.0)))
                                       (fx+ n 1) n))))))))))

  (define (draw-lines! bv w h spec cp lw)
    (let* ([u (fx- (char->integer (string-ref spec 0)) 48)]
           [d (fx- (char->integer (string-ref spec 1)) 48)]
           [l (fx- (char->integer (string-ref spec 2)) 48)]
           [r (fx- (char->integer (string-ref spec 3)) 48)]
           [t0 (fxquotient lw 2)]
           [g (fxmax 1 lw)]                      ; offset of double strokes
           [cx (fxquotient w 2)] [cy (fxquotient h 2)]
           [n-dash (dashes cp)])
      (define (width wt) (if (fx= wt 2) (fx* 2 lw) lw))
      ;; horizontal stroke [x0,x1) of thickness th centred on y
      (define (hs x0 x1 y th) (let ([y0 (fx- y (fxquotient th 2))]) (fill-rect! bv w h x0 y0 x1 (fx+ y0 th) 255)))
      (define (vs y0 y1 x th) (let ([x0 (fx- x (fxquotient th 2))]) (fill-rect! bv w h x0 y0 (fx+ x0 th) y1 255)))
      (let* ([vdouble (or (fx= u 3) (fx= d 3))]
             [hdouble (or (fx= l 3) (fx= r 3))]
             ;; half extent of the widest perpendicular single/heavy line
             [vw (fxmax (if (fx= u 3) 0 (width u)) (if (fx= d 3) 0 (width d)))]
             [hw (fxmax (if (fx= l 3) 0 (width l)) (if (fx= r 3) 0 (width r)))]
             ;; edges of the perpendicular single/heavy line (or the centre)
             [vlo (if (fx> vw 0) (fx- cx (fxquotient vw 2)) (fx- cx t0))]
             [vhi (if (fx> vw 0) (fx+ vlo vw) (fx+ (fx- cx t0) lw))]
             [hlo (if (fx> hw 0) (fx- cy (fxquotient hw 2)) (fx- cy t0))]
             [hhi (if (fx> hw 0) (fx+ hlo hw) (fx+ (fx- cy t0) lw))]
             [vboth (and (fx> u 0) (fx> d 0))]
             [hboth (and (fx> l 0) (fx> r 0))])
        (if (fx> n-dash 0)
            (if (fx> (fx+ l r) 0)
                (let ([th (width (fxmax l r))] [seg (fxquotient w n-dash)])
                  (do ([i 0 (fx+ i 1)]) ((fx= i n-dash))
                    (hs (fx+ (fx* i seg) (fxquotient seg 6))
                        (fx- (fx* (fx+ i 1) seg) (fxquotient seg 6)) cy th)))
                (let ([th (width (fxmax u d))] [seg (fxquotient h n-dash)])
                  (do ([i 0 (fx+ i 1)]) ((fx= i n-dash))
                    (vs (fx+ (fx* i seg) (fxquotient seg 6))
                        (fx- (fx* (fx+ i 1) seg) (fxquotient seg 6)) cx th))))
            (begin
              ;; horizontal arms
              (unless (fx= r 0)
                (if (fx= r 3)
                    (for-each
                     (lambda (off)
                       (let* ([same (if (fx< off 0) u d)]
                              [x (if vdouble
                                     (fx- (if (fx> same 0) (fx+ cx g) (fx- cx g)) t0)
                                     vlo)])
                         (hs x w (fx+ cy off) lw)))
                     (list (fx- g) g))
                    (let ([x (if vdouble
                                 (fx- (if (and vboth (not hboth)) (fx+ cx g) (fx- cx g)) t0)
                                 vlo)])
                      (hs x w cy (width r)))))
              (unless (fx= l 0)
                (if (fx= l 3)
                    (for-each
                     (lambda (off)
                       (let* ([same (if (fx< off 0) u d)]
                              [x (if vdouble
                                     (fx+ (fx- (if (fx> same 0) (fx- cx g) (fx+ cx g)) t0) lw)
                                     vhi)])
                         (hs 0 x (fx+ cy off) lw)))
                     (list (fx- g) g))
                    (let ([x (if vdouble
                                 (fx+ (fx- (if (and vboth (not hboth)) (fx- cx g) (fx+ cx g)) t0) lw)
                                 (fxmax vhi (fx+ (fx- cx (fxquotient (width l) 2)) (width l))))])
                      (hs 0 x cy (width l)))))
              ;; vertical arms
              (unless (fx= d 0)
                (if (fx= d 3)
                    (for-each
                     (lambda (off)
                       (let* ([same (if (fx< off 0) l r)]
                              [y (if hdouble
                                     (fx- (if (fx> same 0) (fx+ cy g) (fx- cy g)) t0)
                                     hlo)])
                         (vs y h (fx+ cx off) lw)))
                     (list (fx- g) g))
                    (let ([y (if hdouble
                                 (fx- (if (and hboth (not vboth)) (fx+ cy g) (fx- cy g)) t0)
                                 hlo)])
                      (vs y h cx (width d)))))
              (unless (fx= u 0)
                (if (fx= u 3)
                    (for-each
                     (lambda (off)
                       (let* ([same (if (fx< off 0) l r)]
                              [y (if hdouble
                                     (fx+ (fx- (if (fx> same 0) (fx- cy g) (fx+ cy g)) t0) lw)
                                     hhi)])
                         (vs 0 y (fx+ cx off) lw)))
                     (list (fx- g) g))
                    (let ([y (if hdouble
                                 (fx+ (fx- (if (and hboth (not vboth)) (fx- cy g) (fx+ cy g)) t0) lw)
                                 (fxmax hhi (fx+ (fx- cy (fxquotient (width u) 2)) (width u))))])
                      (vs 0 y cx (width u))))))))))

  (define (draw-arc! bv w h cp lw)
    ;; rounded corners: quarter circle joining the cell center lines
    (let* ([cx (+ (fxquotient w 2) (if (fxodd? lw) 0.5 0.0))]
           [cy (+ (fxquotient h 2) (if (fxodd? lw) 0.5 0.0))]
           [r (min (- cx 0.0) (- cy 0.0) (/ w 2.0))]
           [half (/ lw 2.0)]
           ;; direction of the arm ends
           [dx (if (memv cp '(#x256D #x2570)) 1 -1)]     ; right arm?
           [dy (if (memv cp '(#x256D #x256E)) 1 -1)]     ; down arm?
           [ox (+ cx (* dx r))] [oy (+ cy (* dy r))])   ; arc center
      (fill-shape! bv w h
        (lambda (x y)
          (or
           ;; arc
           (and (if (fx> dx 0) (<= x ox) (>= x ox))
                (if (fx> dy 0) (<= y oy) (>= y oy))
                (let ([d (sqrt (+ (* (- x ox) (- x ox)) (* (- y oy) (- y oy))))])
                  (<= (abs (- d r)) half)))
           ;; straight continuation to the cell edges
           (and (if (fx> dx 0) (>= x ox) (<= x ox)) (<= (abs (- y cy)) half))
           (and (if (fx> dy 0) (>= y oy) (<= y oy)) (<= (abs (- x cx)) half)))))))

  (define (draw-diagonal! bv w h cp lw)
    (let ([half (/ (* lw 1.2) 2.0)] [len (sqrt (+ (* w w) (* h h)))])
      (fill-shape! bv w h
        (lambda (x y)
          (let ([d1 (/ (abs (- (* h x) (* w (- h y)))) len)]   ; '/' from bottom-left
                [d2 (/ (abs (- (* h x) (* w y))) len)])        ; '\' from top-left
            (case cp
              [(#x2571) (<= d1 half)]
              [(#x2572) (<= d2 half)]
              [else (or (<= d1 half) (<= d2 half))]))))))

  (define (draw-block! bv w h cp)
    (define (frac-h n) (fxquotient (fx+ (fx* h n) 4) 8))
    (define (frac-w n) (fxquotient (fx+ (fx* w n) 4) 8))
    (let ([cx (fxquotient w 2)] [cy (fxquotient h 2)])
      (cond
        [(fx= cp #x2580) (fill-rect! bv w h 0 0 w (frac-h 4) 255)]
        [(fx<= #x2581 cp #x2588) (fill-rect! bv w h 0 (fx- h (frac-h (fx- cp #x2580))) w h 255)]
        [(fx<= #x2589 cp #x258F) (fill-rect! bv w h 0 0 (frac-w (fx- #x2590 cp)) h 255)]
        [(fx= cp #x2590) (fill-rect! bv w h cx 0 w h 255)]
        [(fx= cp #x2591) (fill-rect! bv w h 0 0 w h 64)]
        [(fx= cp #x2592) (fill-rect! bv w h 0 0 w h 128)]
        [(fx= cp #x2593) (fill-rect! bv w h 0 0 w h 192)]
        [(fx= cp #x2594) (fill-rect! bv w h 0 0 w (frac-h 1) 255)]
        [(fx= cp #x2595) (fill-rect! bv w h (fx- w (frac-w 1)) 0 w h 255)]
        [else
         ;; quadrants: bits UL UR LL LR
         (let ([bits (case cp
                       [(#x2596) #b0010] [(#x2597) #b0001] [(#x2598) #b1000]
                       [(#x2599) #b1011] [(#x259A) #b1001] [(#x259B) #b1110]
                       [(#x259C) #b1101] [(#x259D) #b0100] [(#x259E) #b0110]
                       [(#x259F) #b0111] [else 0])])
           (when (fxlogbit? 3 bits) (fill-rect! bv w h 0 0 cx cy 255))
           (when (fxlogbit? 2 bits) (fill-rect! bv w h cx 0 w cy 255))
           (when (fxlogbit? 1 bits) (fill-rect! bv w h 0 cy cx h 255))
           (when (fxlogbit? 0 bits) (fill-rect! bv w h cx cy w h 255)))])))

  (define (draw-powerline! bv w h cp lw)
    (let ([half (/ lw 2.0)] [hh (/ h 2.0)])
      (fill-shape! bv w h
        (lambda (x y)
          (let* ([xr (if (memv cp '(#xE0B0 #xE0B1)) x (- w x))]   ; mirror for left-pointing
                 [edge (* w (- 1.0 (/ (abs (- y hh)) hh)))])      ; triangle boundary
            (if (memv cp '(#xE0B0 #xE0B2))
                (<= xr edge)
                (<= (abs (- xr edge)) (* half 1.5))))))))

  (define (boxdraw-glyph cp w h lw)
    (let ([bv (make-canvas w h)])
      (cond
        [(fx<= #x256D cp #x2570) (draw-arc! bv w h cp lw) bv]
        [(fx<= #x2571 cp #x2573) (draw-diagonal! bv w h cp lw) bv]
        [(fx<= #x2500 cp #x257F)
         (draw-lines! bv w h (vector-ref box-table (fx- cp #x2500)) cp lw) bv]
        [(fx<= #x2580 cp #x259F) (draw-block! bv w h cp) bv]
        [(fx<= #xE0B0 cp #xE0B3) (draw-powerline! bv w h cp lw) bv]
        [else #f]))))
