;;; Software renderer: draws the terminal grid into an ARGB8888 image.
;;;
;;; Rendering is incremental.  For every visible row the renderer remembers
;;; what it last drew (cells, selection, cursor, highlights) and only redraws
;;; rows that changed.  When the content scrolled, the existing pixels are
;;; moved with memmove first, so scrolling output is cheap.
(library (chezterm render)
  (export make-renderer renderer? renderer-resize! renderer-render!
          renderer-pixels renderer-width renderer-height renderer-stride
          renderer-invalidate! renderer-set-font! renderer-font
          renderer-cols renderer-rows renderer-set-padding! renderer-free!)
  (import (chezscheme) (chezterm ffi) (chezterm grid) (chezterm terminal) (chezterm font))

  (define-record-type renderer
    (fields (mutable font)
            (mutable width) (mutable height) (mutable stride)
            (mutable pixels)                 ; malloc'd shadow image
            (mutable pad-x) (mutable pad-y)
            (mutable row-keys)               ; vector of per-row state
            (mutable last-palette)
            (mutable last-reverse)
            opacity                          ; 0-255
            bold-is-bright
            selection-fg selection-bg
            hollow-unfocused)
    (protocol
     (lambda (new)
       (lambda (font pad-x pad-y opacity bold-is-bright sel-fg sel-bg hollow)
         (new font 0 0 0 0 pad-x pad-y (make-vector 0 #f) #f #f
              (max 0 (min 255 (exact (round (* 255 opacity)))))
              bold-is-bright sel-fg sel-bg hollow)))))

  (define (renderer-cols r)
    (max 1 (fxquotient (fx- (renderer-width r) (fx* 2 (renderer-pad-x r)))
                       (font-cell-width (renderer-font r)))))
  (define (renderer-rows r)
    (max 1 (fxquotient (fx- (renderer-height r) (fx* 2 (renderer-pad-y r)))
                       (font-cell-height (renderer-font r)))))

  (define (renderer-invalidate! r)
    (vector-fill! (renderer-row-keys r) #f)
    (renderer-last-palette-set! r #f))

  (define (renderer-set-font! r font)
    (renderer-font-set! r font)
    (renderer-invalidate! r))

  (define (renderer-set-padding! r x y)
    (renderer-pad-x-set! r x)
    (renderer-pad-y-set! r y)
    (renderer-invalidate! r))

  (define (renderer-free! r)
    (unless (eqv? 0 (renderer-pixels r)) (free (renderer-pixels r)))
    (renderer-pixels-set! r 0))

  (define (renderer-resize! r width height)
    (unless (and (fx= width (renderer-width r)) (fx= height (renderer-height r)))
      (unless (eqv? 0 (renderer-pixels r)) (free (renderer-pixels r)))
      (renderer-width-set! r width)
      (renderer-height-set! r height)
      (renderer-stride-set! r (fx* 4 width))
      (renderer-pixels-set! r (malloc (max 4 (fx* 4 (fx* width height)))))
      (renderer-invalidate! r)))

  ;;; Pixel helpers ------------------------------------------------------------

  (define-syntax div255
    (syntax-rules ()
      [(_ x) (let ([y (fx+ x 128)]) (fxsrl (fx+ y (fxsrl y 8)) 8))]))

  ;; premultiplied ARGB for rgb with alpha a
  (define (argb rgb a)
    (if (fx= a 255)
        (fxior #xFF000000 rgb)
        (fxior (fxsll a 24)
               (fxsll (div255 (fx* a (fxsrl rgb 16))) 16)
               (fxsll (div255 (fx* a (fxand #xFF (fxsrl rgb 8)))) 8)
               (div255 (fx* a (fxand #xFF rgb))))))

  (define (fill-rect! r x0 y0 x1 y1 pixel)
    (let ([base (renderer-pixels r)] [stride (renderer-stride r)]
          [x0 (fxmax 0 x0)] [y0 (fxmax 0 y0)]
          [x1 (fxmin x1 (renderer-width r))] [y1 (fxmin y1 (renderer-height r))])
      (do ([y y0 (fx+ y 1)]) ((fx>= y y1))
        (let ([row (+ base (fx* y stride))])
          (do ([x x0 (fx+ x 1)]) ((fx>= x x1))
            (foreign-set! 'unsigned-32 row (fx* x 4) pixel))))))

  ;; blend opaque color RGB with coverage A onto the pixel at address p
  (define-syntax blend!
    (syntax-rules ()
      [(_ p off rgb a)
       (cond
         [(fx= a 0) (void)]
         [(fx= a 255) (foreign-set! 'unsigned-32 p off (fxior #xFF000000 rgb))]
         [else
          (let* ([d (foreign-ref 'unsigned-32 p off)]
                 [ia (fx- 255 a)])
            (foreign-set! 'unsigned-32 p off
              (fxior (fxsll (div255 (fx+ (fx* 255 a) (fx* ia (fxsrl d 24)))) 24)
                     (fxsll (div255 (fx+ (fx* a (fxsrl rgb 16)) (fx* ia (fxand #xFF (fxsrl d 16))))) 16)
                     (fxsll (div255 (fx+ (fx* a (fxand #xFF (fxsrl rgb 8))) (fx* ia (fxand #xFF (fxsrl d 8))))) 8)
                     (div255 (fx+ (fx* a (fxand #xFF rgb)) (fx* ia (fxand #xFF d)))))))])]))

  ;; Draw glyph G with pen at (px, baseline-y) in color RGB, clipped to
  ;; rows [clip0, clip1).
  (define (draw-glyph! r g px by rgb clip0 clip1)
    (let* ([gw (glyph-width g)] [gh (glyph-height g)]
           [x0 (fx+ px (glyph-left g))] [y0 (fx- by (glyph-top g))]
           [data (glyph-data g)]
           [base (renderer-pixels r)] [stride (renderer-stride r)]
           [width (renderer-width r)]
           [ys (fxmax y0 clip0 0)] [ye (fxmin (fx+ y0 gh) clip1 (renderer-height r))]
           [xs (fxmax x0 0)] [xe (fxmin (fx+ x0 gw) width)])
      (if (glyph-color? g)
          (do ([y ys (fx+ y 1)]) ((fx>= y ye))
            (let ([row (+ base (fx* y stride))] [src (fx* 4 (fx* (fx- y y0) gw))])
              (do ([x xs (fx+ x 1)]) ((fx>= x xe))
                (let* ([i (fx+ src (fx* 4 (fx- x x0)))]
                       [sa (bytevector-u8-ref data (fx+ i 3))])
                  (unless (fx= sa 0)
                    (let* ([off (fx* x 4)]
                           [d (foreign-ref 'unsigned-32 row off)]
                           [ia (fx- 255 sa)])
                      (foreign-set! 'unsigned-32 row off
                        (fxior (fxsll (fx+ sa (div255 (fx* ia (fxsrl d 24)))) 24)
                               (fxsll (fx+ (bytevector-u8-ref data (fx+ i 2)) (div255 (fx* ia (fxand #xFF (fxsrl d 16))))) 16)
                               (fxsll (fx+ (bytevector-u8-ref data (fx+ i 1)) (div255 (fx* ia (fxand #xFF (fxsrl d 8))))) 8)
                               (fx+ (bytevector-u8-ref data i) (div255 (fx* ia (fxand #xFF d))))))))))))
          (do ([y ys (fx+ y 1)]) ((fx>= y ye))
            (let ([row (+ base (fx* y stride))] [src (fx* (fx- y y0) gw)])
              (do ([x xs (fx+ x 1)]) ((fx>= x xe))
                (let ([a (bytevector-u8-ref data (fx+ src (fx- x x0)))])
                  (blend! row (fx* x 4) rgb a))))))))

  ;;; Colors -----------------------------------------------------------------

  (define (dim rgb)
    (fxior (fxsll (fxquotient (fx* 2 (fxsrl rgb 16)) 3) 16)
           (fxsll (fxquotient (fx* 2 (fxand #xFF (fxsrl rgb 8))) 3) 8)
           (fxquotient (fx* 2 (fxand #xFF rgb)) 3)))

  ;;; Row state ----------------------------------------------------------------

  ;; What a row looks like: compared against the previous frame.
  (define-record-type rowkey
    (fields cells extras wrapped sel cursor highlights))

  (define (fxvector-equal? a b)
    (and (fx= (fxvector-length a) (fxvector-length b))
         (let loop ([i (fx- (fxvector-length a) 1)])
           (or (fx< i 0)
               (and (fx= (fxvector-ref a i) (fxvector-ref b i)) (loop (fx- i 1)))))))

  (define (extras->list l)
    (let ([ex (line-extra l)])
      (if (or (not ex) (fx= 0 (hashtable-size ex)))
          '()
          (let-values ([(ks vs) (hashtable-entries ex)])
            (list-sort (lambda (a b) (fx< (car a) (car b)))
                       (map cons (vector->list ks) (vector->list vs)))))))

  (define (content-equal? k cells extras)
    (and k (fxvector-equal? (rowkey-cells k) cells) (equal? (rowkey-extras k) extras)))

  ;; selected column range [c0, c1) of absolute row ABS, or #f
  (define (selection-range sel abs cols)
    (and sel
         (let* ([sa (vector-ref sel 1)] [sc (vector-ref sel 2)]
                [ea (vector-ref sel 3)] [ec (vector-ref sel 4)]
                [forward (or (fx< sa ea) (and (fx= sa ea) (fx<= sc ec)))]
                [r0 (if forward sa ea)] [c0 (if forward sc ec)]
                [r1 (if forward ea sa)] [c1 (if forward ec sc)])
           (and (fx<= r0 abs r1)
                (if (eq? (vector-ref sel 0) 'block)
                    (cons (fxmin sc ec) (fx+ 1 (fxmax sc ec)))
                    (cons (if (fx= abs r0) c0 0)
                          (if (fx= abs r1) (fxmin cols (fx+ c1 1)) cols)))))))

  ;;; Main entry ----------------------------------------------------------------

  ;; Render TERM.  HIGHLIGHTS is a procedure mapping an absolute row to a
  ;; list of (c0 c1 current?) search match ranges.  OVERLAY, when not #f, is
  ;; a line drawn instead of the bottom row (the search prompt).  Returns a list of damaged
  ;; (y0 . y1) pixel row ranges, empty when nothing changed.
  (define (renderer-render! r term focused? blink-on? highlights overlay)
    (let* ([font (renderer-font r)]
           [cw (font-cell-width font)] [ch (font-cell-height font)]
           [rows (fxmin (terminal-rows term) (renderer-rows r))]
           [cols (fxmin (terminal-cols term) (renderer-cols r))]
           [palette (terminal-palette term)]
           [bg-default (vector-ref palette COLOR-BG)]
           [full? (not (and (renderer-last-palette r) (equal? (renderer-last-palette r) palette)
                            (eq? (renderer-last-reverse r) (terminal-reverse-video? term))
                            (fx= (vector-length (renderer-row-keys r)) rows)))]
           [damage '()])
      (when full?
        (renderer-last-palette-set! r (vector-copy palette))
        (renderer-last-reverse-set! r (terminal-reverse-video? term))
        (renderer-row-keys-set! r (make-vector rows #f))
        (fill-rect! r 0 0 (renderer-width r) (renderer-height r)
                    (argb (if (terminal-reverse-video? term) (vector-ref palette COLOR-FG) bg-default)
                          (renderer-opacity r)))
        (set! damage (list (cons 0 (renderer-height r)))))
      (let* ([keys (renderer-row-keys r)]
             [g (terminal-grid term)]
             [offset (terminal-display-offset term)]
             [sel (terminal-selection term)]
             [cursor-row (and (terminal-cursor-visible? term) (fx= offset 0)
                              (terminal-cursor-row term))]
             [lines (let ([v (make-vector rows)])
                      (do ([i 0 (fx+ i 1)]) ((fx= i rows))
                        (vector-set! v i (grid-line g (fx- i offset))))
                      (when overlay (vector-set! v (fx- rows 1) overlay))
                      v)])
        ;; detect scrolling: new row 0 equals an old row k
        (unless full?
          (let ([c0 (line-cells (vector-ref lines 0))] [e0 (extras->list (vector-ref lines 0))])
            (unless (content-equal? (vector-ref keys 0) c0 e0)
              (let find ([k 1])
                (when (fx< k (fx- rows 1))
                  (if (and (content-equal? (vector-ref keys k) c0 e0)
                           (content-equal? (vector-ref keys (fx+ k 1))
                                           (line-cells (vector-ref lines 1))
                                           (extras->list (vector-ref lines 1))))
                      (begin
                        (scroll-pixels! r keys k rows)
                        ;; everything that moved must be reported as damaged
                        (set! damage (cons (cons (renderer-pad-y r)
                                                 (fx+ (renderer-pad-y r) (fx* (fx- rows k) ch)))
                                           damage)))
                      (find (fx+ k 1))))))))
        (do ([row 0 (fx+ row 1)]) ((fx= row rows))
          (let* ([l (vector-ref lines row)]
                 [cells (line-cells l)]
                 [extras (extras->list l)]
                 [overlay-row (and overlay (fx= row (fx- rows 1)))]
                 [abs (if overlay-row -1 (terminal-abs-row term (fx- row offset)))]
                 [srange (and (not overlay-row) (selection-range sel abs cols))]
                 [cur (and (eqv? cursor-row row) (not overlay-row)
                           (list (terminal-cursor-col term) (terminal-cursor-style term)
                                 focused? (or blink-on? (not (terminal-cursor-blink? term)))))]
                 [hl (if overlay-row '() (highlights abs))]
                 [old (vector-ref keys row)])
            (unless (and old
                         (fxvector-equal? (rowkey-cells old) cells)
                         (equal? (rowkey-extras old) extras)
                         (equal? (rowkey-sel old) srange)
                         (equal? (rowkey-cursor old) cur)
                         (equal? (rowkey-highlights old) hl))
              (draw-row! r term l row cols srange cur hl palette)
              (vector-set! keys row (make-rowkey (fxvector-copy cells) extras #f srange cur hl))
              (let ([y0 (fx+ (renderer-pad-y r) (fx* row ch))])
                (set! damage (cons (cons y0 (fx+ y0 ch)) damage)))))))
      damage))

  ;; Move the pixels of rows [k, rows) up to row 0 and shift the row keys.
  (define (scroll-pixels! r keys k rows)
    (let* ([ch (font-cell-height (renderer-font r))]
           [stride (renderer-stride r)]
           [y0 (renderer-pad-y r)]
           [base (+ (renderer-pixels r) (fx* y0 stride))])
      (memmove base (+ base (fx* k (fx* ch stride))) (fx* (fx- rows k) (fx* ch stride)))
      (do ([i 0 (fx+ i 1)]) ((fx= i rows))
        (vector-set! keys i (if (fx< (fx+ i k) rows) (vector-ref keys (fx+ i k)) #f)))
      ;; rows that moved keep their content but cursor / selection state is
      ;; re-checked by the normal comparison
      ))

  (define (draw-row! r term l row cols srange cur hl palette)
    (let* ([font (renderer-font r)]
           [cw (font-cell-width font)] [ch (font-cell-height font)]
           [px (renderer-pad-x r)]
           [y0 (fx+ (renderer-pad-y r) (fx* row ch))]
           [y1 (fx+ y0 ch)]
           [by (fx+ y0 (font-baseline font))]
           [v (line-cells l)]
           [ex (line-extra l)]
           [ncols (fxmin cols (line-cols l))]
           [opacity (renderer-opacity r)]
           [bg-default (vector-ref palette COLOR-BG)]
           [reverse-video (terminal-reverse-video? term)]
           [cursor-col (and cur (car cur))]
           [cursor-style (and cur (cadr cur))]
           [cursor-focused (and cur (caddr cur))]
           [cursor-shown (and cur (cadddr cur))]
           [cursor-rgb (vector-ref palette COLOR-CURSOR)]
           [sel-bg (renderer-selection-bg r)]
           [sel-fg (renderer-selection-fg r)])
      ;; compute per-cell colors: returns (values fg bg bg-is-default)
      (define (cell-colors i)
        (let* ([attrs (cell-attrs v i)]
               [fgc (cell-fg v i)] [bgc (cell-bg v i)]
               [fgc (if (and (renderer-bold-is-bright r) (fxlogtest attrs ATTR-BOLD) (fx< fgc 8))
                        (fx+ fgc 8) fgc)]
               [fg (color->rgb palette fgc)]
               [fg (if (fxlogtest attrs ATTR-DIM) (dim fg) fg)]
               [bg (color->rgb palette bgc)]
               [default-bg (fx= bgc COLOR-BG)]
               [rev (not (eq? (fxlogtest attrs ATTR-REVERSE) reverse-video))])
          (let-values ([(fg bg default-bg) (if rev (values bg fg #f) (values fg bg default-bg))])
            (let* ([selected (and srange (fx<= (car srange) i) (fx< i (cdr srange)))]
                   [hl (and (pair? hl)
                            (find (lambda (h) (and (fx<= (car h) i) (fx< i (cadr h)))) hl))])
              (cond
                [hl (values 0 (if (caddr hl) #xF0A030 #x8A6A20) #f)]
                [selected (values (or sel-fg fg) sel-bg #f)]
                [else (values (if (fxlogtest attrs ATTR-HIDDEN) bg fg) bg default-bg)])))))
      ;; padding at both sides of the row
      (let ([pad-pixel (argb (if reverse-video (vector-ref palette COLOR-FG) bg-default) opacity)])
        (fill-rect! r 0 y0 px y1 pad-pixel)
        (fill-rect! r (fx+ px (fx* ncols cw)) y0 (renderer-width r) y1 pad-pixel))
      ;; backgrounds
      (do ([i 0 (fx+ i 1)]) ((fx= i ncols))
        (let-values ([(fg bg default-bg) (cell-colors i)])
          (let ([x (fx+ px (fx* i cw))])
            (fill-rect! r x y0 (fx+ x cw) y1 (argb bg (if default-bg opacity 255))))))
      ;; block cursor background
      (let ([block-cursor (and cur cursor-shown cursor-focused (eq? cursor-style 'block))])
        (when block-cursor
          (let* ([wide (and (fx< (fx+ cursor-col 1) ncols) (fxlogtest (cell-attrs v cursor-col) ATTR-WIDE))]
                 [x (fx+ px (fx* cursor-col cw))])
            (fill-rect! r x y0 (fx+ x (fx* cw (if wide 2 1))) y1 (argb cursor-rgb 255))))
        ;; glyphs and decorations
        (do ([i 0 (fx+ i 1)]) ((fx= i ncols))
          (let* ([cp (cell-ch v i)] [attrs (cell-attrs v i)])
            (unless (fxlogtest attrs ATTR-SPACER)
              (let-values ([(fg bg default-bg) (cell-colors i)])
                (let* ([x (fx+ px (fx* i cw))]
                       [fg (if (and block-cursor (fx= i cursor-col)) (vector-ref palette COLOR-BG) fg)]
                       [style (fxior (if (fxlogtest attrs ATTR-BOLD) STYLE-BOLD 0)
                                     (if (fxlogtest attrs ATTR-ITALIC) STYLE-ITALIC 0))])
                  (when (and (fx> cp 32) (not (fxlogtest attrs ATTR-HIDDEN)))
                    (let* ([marks (and ex (hashtable-ref ex i #f))]
                           [g (if marks
                                  (font-get-cluster-glyph font cp marks style)
                                  (font-get-glyph font cp style))])
                      (draw-glyph! r g x by fg y0 y1)))
                  (let ([ul (fxsrl (fxand attrs ATTR-UNDERLINE-MASK) ATTR-UNDERLINE-SHIFT)]
                        [w (if (fxlogtest attrs ATTR-WIDE) (fx* 2 cw) cw)])
                    (unless (fx= ul UL-NONE)
                      (draw-underline! r ul x (fx+ x w) y0 y1 fg))
                    (when (fxlogtest attrs ATTR-STRIKE)
                      (let ([sy (fx+ y0 (font-strikeout-position font))]
                            [t (font-underline-thickness font)])
                        (fill-rect! r x sy (fx+ x w) (fx+ sy t) (argb fg 255))))))))))
        ;; other cursor shapes
        (when (and cur cursor-shown (not block-cursor))
          (let* ([wide (and (fx< (fx+ cursor-col 1) ncols) (fxlogtest (cell-attrs v cursor-col) ATTR-WIDE))]
                 [x (fx+ px (fx* cursor-col cw))]
                 [x1 (fx+ x (fx* cw (if wide 2 1)))]
                 [t (fxmax 1 (fxquotient (font-cell-width font) 6))]
                 [pixel (argb cursor-rgb 255)])
            (cond
              [(not cursor-focused)
               ;; hollow block
               (fill-rect! r x y0 x1 (fx+ y0 1) pixel)
               (fill-rect! r x (fx- y1 1) x1 y1 pixel)
               (fill-rect! r x y0 (fx+ x 1) y1 pixel)
               (fill-rect! r (fx- x1 1) y0 x1 y1 pixel)]
              [(eq? cursor-style 'beam) (fill-rect! r x y0 (fx+ x t) y1 pixel)]
              [else (fill-rect! r x (fx- y1 t) x1 y1 pixel)]))))))

  (define (draw-underline! r style x0 x1 y0 y1 rgb)
    (let* ([font (renderer-font r)]
           [t (font-underline-thickness font)]
           [uy (fx+ y0 (font-underline-position font))]
           [pixel (argb rgb 255)])
      (case style
        [(1) (fill-rect! r x0 uy x1 (fxmin y1 (fx+ uy t)) pixel)]
        [(2) (fill-rect! r x0 uy x1 (fxmin y1 (fx+ uy t)) pixel)
             (let ([uy2 (fxmin (fx- y1 t) (fx+ uy (fx* 2 t)))])
               (fill-rect! r x0 uy2 x1 (fx+ uy2 t) pixel))]
        [(3)                                   ; curly: a sine wave
         (let* ([amp (fxmax 1 (fxquotient (fx- y1 uy) 3))]
                [period (* 1.0 (font-cell-width font))])
           (do ([x x0 (fx+ x 1)]) ((fx>= x x1))
             (let* ([dy (exact (round (* amp (sin (/ (* 2 3.14159265 x) period)))))]
                    [y (fxmax y0 (fxmin (fx- y1 t) (fx+ uy dy)))])
               (fill-rect! r x y (fx+ x 1) (fx+ y t) pixel))))]
        [(4) (do ([x x0 (fx+ x (fx* 2 t))]) ((fx>= x x1))
               (fill-rect! r x uy (fxmin x1 (fx+ x t)) (fx+ uy t) pixel))]
        [(5) (let ([dash (fxmax 2 (fxquotient (font-cell-width font) 2))])
               (do ([x x0 (fx+ x (fx* 2 dash))]) ((fx>= x x1))
                 (fill-rect! r x uy (fxmin x1 (fx+ x dash)) (fx+ uy t) pixel)))]
        [else (void)]))))
