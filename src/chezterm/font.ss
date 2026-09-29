;;; Fonts: fontconfig lookup, FreeType rasterization and a glyph cache.
(library (chezterm font)
  (export make-font font? font-cell-width font-cell-height font-baseline
          font-underline-position font-underline-thickness font-strikeout-position
          font-line-thickness font-get-glyph font-get-cluster-glyph font-pixel-size
          font-destroy!
          glyph? glyph-width glyph-height glyph-left glyph-top glyph-color? glyph-data
          STYLE-REGULAR STYLE-BOLD STYLE-ITALIC STYLE-BOLD-ITALIC)
  (import (chezscheme) (chezterm ffi) (chezterm cutil) (chezterm boxdraw))

  (define STYLE-REGULAR 0)
  (define STYLE-BOLD 1)
  (define STYLE-ITALIC 2)
  (define STYLE-BOLD-ITALIC 3)

  ;; A rasterized glyph.  DATA is an alpha map (width*height bytes) or, for
  ;; color glyphs, premultiplied BGRA pixels (width*height*4 bytes).
  ;; LEFT/TOP are the offsets of the bitmap from the pen position on the
  ;; baseline (TOP measured upwards).
  (define-record-type glyph (fields width height left top color? data))

  (define empty-glyph (make-glyph 0 0 0 0 #f (make-bytevector 0)))

  ;;; FreeType / fontconfig globals --------------------------------------------

  (define ft-library
    (let ([p (malloc 8)])
      (unless (= 0 (FT_Init_FreeType p)) (error 'font "FT_Init_FreeType failed"))
      (let ([lib (foreign-ref 'uptr p 0)])
        (free p)
        lib)))

  (define fc-config #f)
  (define (fc)
    (unless fc-config
      (set! fc-config (FcInitLoadConfigAndFonts))
      (when (ptr-null? fc-config) (error 'font "fontconfig initialisation failed")))
    fc-config)

  (define (pattern-get-string pat key)
    (let ([out (malloc 8)])
      (let ([r (FcPatternGetString pat key 0 out)])
        (let ([s (and (= r FcResultMatch) (cstring->string (foreign-ref 'uptr out 0)))])
          (free out)
          s))))

  (define (pattern-get-int pat key)
    (let ([out (malloc 8)])
      (let ([r (FcPatternGetInteger pat key 0 out)])
        (let ([v (and (= r FcResultMatch) (foreign-ref 'int out 0))])
          (free out)
          v))))

  ;; Find a font file.  Returns (file index weight slant) or #f.
  (define (fc-match family weight slant pixel-size codepoint)
    (let ([pat (FcPatternCreate)])
      (with-cstring family (lambda (f) (FcPatternAddString pat FC_FAMILY f)))
      (FcPatternAddInteger pat FC_WEIGHT weight)
      (FcPatternAddInteger pat FC_SLANT slant)
      (FcPatternAddDouble pat FC_PIXEL_SIZE (inexact pixel-size))
      (when codepoint
        (let ([cs (FcCharSetCreate)])
          (FcCharSetAddChar cs codepoint)
          (FcPatternAddCharSet pat FC_CHARSET cs)
          (FcCharSetDestroy cs)))
      (FcConfigSubstitute (fc) pat FcMatchPattern)
      (FcDefaultSubstitute pat)
      (let* ([res (malloc 8)]
             [m (FcFontMatch (fc) pat res)])
        (free res)
        (FcPatternDestroy pat)
        (and (not (ptr-null? m))
             (let ([file (pattern-get-string m FC_FILE)]
                   [index (or (pattern-get-int m FC_INDEX) 0)]
                   [w (or (pattern-get-int m FC_WEIGHT) FC_WEIGHT_REGULAR)]
                   [s (or (pattern-get-int m FC_SLANT) FC_SLANT_ROMAN)])
               (FcPatternDestroy m)
               (and file (list file index w s)))))))

  ;;; Faces ----------------------------------------------------------------------

  ;; A loaded FreeType face with synthesis flags.
  (define-record-type face (fields ptr embolden? oblique? fixed-scale color?))

  (define (face-rec f) (make-ftype-pointer FT_FaceRec_ (face-ptr f)))

  (define face-flag-color 16384)        ; FT_FACE_FLAG_COLOR
  (define face-flag-fixed 2)            ; FT_FACE_FLAG_FIXED_SIZES
  (define face-flag-scalable 1)

  ;; Open FILE and size it to PIXEL-SIZE.  Bitmap-only fonts (color emoji)
  ;; get the nearest strike and a scale factor for resampling.
  (define (open-face file index pixel-size embolden? oblique?)
    (let ([out (malloc 8)])
      (let ([err (FT_New_Face ft-library file index out)])
        (let ([ptr (foreign-ref 'uptr out 0)])
          (free out)
          (and (= err 0)
               (let* ([rec (make-ftype-pointer FT_FaceRec_ ptr)]
                      [flags (ftype-ref FT_FaceRec_ (face_flags) rec)]
                      [scalable (logtest flags face-flag-scalable)]
                      [color (logtest flags face-flag-color)])
                 (if (or scalable (= 0 (ftype-ref FT_FaceRec_ (num_fixed_sizes) rec)))
                     (begin
                       (FT_Set_Pixel_Sizes ptr 0 (max 1 (exact (round pixel-size))))
                       (make-face ptr embolden? oblique? 1.0 color))
                     ;; pick the strike closest to the wanted size
                     (let* ([n (ftype-ref FT_FaceRec_ (num_fixed_sizes) rec)]
                            [sizes (ftype-ref FT_FaceRec_ (available_sizes) rec)]
                            [best (let loop ([i 0] [best 0] [bd #f])
                                    (if (= i n)
                                        best
                                        (let* ([hgt (ftype-ref FT_Bitmap_Size_ (height) sizes i)]
                                               [d (abs (- hgt pixel-size))])
                                          (if (or (not bd) (< d bd))
                                              (loop (+ i 1) i d)
                                              (loop (+ i 1) best bd)))))]
                            [hgt (ftype-ref FT_Bitmap_Size_ (height) sizes best)])
                       (FT_Select_Size ptr best)
                       (make-face ptr embolden? oblique? (/ pixel-size (max 1 hgt)) color)))))))))

  (define (face-char-index f cp) (FT_Get_Char_Index (face-ptr f) cp))

  ;;; Font set -------------------------------------------------------------------

  (define-record-type (font %make-font font?)
    (fields family pixel-size
            faces                     ; vector of 4 faces by style
            (mutable fallbacks)       ; list of extra faces tried in order
            fallback-cache            ; cp -> face or #f
            glyph-cache               ; key -> glyph
            cluster-cache             ; string -> glyph
            face-files                ; (file . index) -> face, avoids duplicates
            cell-width cell-height baseline
            underline-position underline-thickness strikeout-position
            line-thickness))

  (define (f26->px v) (/ v 64.0))

  ;; Create a font set for FAMILY at SIZE points on a DPI display with an
  ;; integer output SCALE.  Bold and italic faces come from fontconfig; if
  ;; the family has none, they are synthesized.
  (define (make-font family size dpi scale bold-family italic-family)
    (let* ([px (* size (/ dpi 72.0) scale)]
           [files (make-hashtable equal-hash equal?)]
           [load (lambda (fam weight slant)
                   (let ([m (fc-match fam weight slant px #f)])
                     (unless m (errorf 'font "no font found for ~s" fam))
                     (let* ([file (car m)] [index (cadr m)]
                            [emb (and (>= weight FC_WEIGHT_BOLD) (< (caddr m) FC_WEIGHT_BOLD))]
                            [obl (and (> slant FC_SLANT_ROMAN) (= (cadddr m) FC_SLANT_ROMAN))]
                            [key (list file index emb obl)])
                       (or (hashtable-ref files key #f)
                           (let ([f (open-face file index px emb obl)])
                             (unless f (errorf 'font "cannot load ~a" file))
                             (hashtable-set! files key f)
                             f)))))]
           [regular (load family FC_WEIGHT_REGULAR FC_SLANT_ROMAN)]
           [bold (load (or bold-family family) FC_WEIGHT_BOLD FC_SLANT_ROMAN)]
           [italic (load (or italic-family family) FC_WEIGHT_REGULAR FC_SLANT_ITALIC)]
           [bold-italic (load (or italic-family family) FC_WEIGHT_BOLD FC_SLANT_ITALIC)]
           [rec (face-rec regular)]
           [size-rec (ftype-ref FT_FaceRec_ (size) rec)]
           [ascender (f26->px (ftype-ref FT_SizeRec_ (metrics ascender) size-rec))]
           [descender (f26->px (ftype-ref FT_SizeRec_ (metrics descender) size-rec))]
           [height (f26->px (ftype-ref FT_SizeRec_ (metrics height) size-rec))]
           [y-scale (ftype-ref FT_SizeRec_ (metrics y_scale) size-rec)]
           [units->px (lambda (u) (/ (* u y-scale) 65536.0 64.0))]
           ;; cell width: advance of "M" (monospace fonts: all the same)
           [cell-w (let ([gi (face-char-index regular 77)])
                     (FT_Load_Glyph (face-ptr regular) gi FT_LOAD_DEFAULT)
                     (let ([slot (ftype-ref FT_FaceRec_ (glyph) rec)])
                       (max 1 (exact (ceiling (f26->px (ftype-ref FT_GlyphSlotRec_ (advance x) slot)))))))]
           [cell-h (max 1 (exact (ceiling (max height (- ascender descender)))))]
           [baseline (exact (round (+ ascender (/ (- cell-h (- ascender descender)) 2.0))))]
           [ul-thick (max 1 (exact (round (units->px (ftype-ref FT_FaceRec_ (underline_thickness) rec)))))]
           [ul-pos (let ([p (exact (round (- (units->px (ftype-ref FT_FaceRec_ (underline_position) rec)))))])
                     ;; keep the underline inside the cell
                     (min (max 1 p) (- cell-h baseline ul-thick)))])
      (%make-font family px (vector regular bold italic bold-italic)
                 '() (make-eqv-hashtable) (make-eqv-hashtable) (make-hashtable string-hash string=?)
                 files
                 cell-w cell-h baseline
                 (+ baseline ul-pos) ul-thick
                 (- baseline (exact (round (/ (- ascender 0) 3.0))))
                 (max 1 (exact (round (/ cell-h 18.0)))))))

  (define (font-destroy! f)
    (let-values ([(ks vs) (hashtable-entries (font-face-files f))])
      (vector-for-each (lambda (face) (when face (FT_Done_Face (face-ptr face)))) vs)))

  ;; Find a face containing CP, preferring STYLE's face.
  (define (face-for f cp style)
    (let ([primary (vector-ref (font-faces f) style)])
      (if (not (= 0 (face-char-index primary cp)))
          primary
          (let ([regular (vector-ref (font-faces f) 0)])
            (if (not (= 0 (face-char-index regular cp)))
                regular
                (fallback-face f cp))))))

  ;; Code points usually shown as (color) emoji.
  (define (emoji? cp)
    (or (fx<= #x1F300 cp #x1FAFF) (fx<= #x1F000 cp #x1F2FF) (fx<= #x2600 cp #x27BF)
        (fx<= #x1FC00 cp #x1FFFF)))

  (define (fallback-face f cp)
    (let ([cache (font-fallback-cache f)])
      (if (hashtable-contains? cache cp)
          (hashtable-ref cache cp #f)
          (let ([face (or (and (emoji? cp) (match-face f "emoji" cp))
                          (find (lambda (fc) (not (= 0 (face-char-index fc cp)))) (font-fallbacks f))
                          (match-face f (font-family f) cp))])
            (hashtable-set! cache cp face)
            face))))

  ;; Ask fontconfig for a FAMILY font covering CP; #f if the result lacks it.
  (define (match-face f family cp)
    (let ([m (fc-match family FC_WEIGHT_REGULAR FC_SLANT_ROMAN (font-pixel-size f) cp)])
      (and m
           (let* ([key (list (car m) (cadr m) #f #f)]
                  [face (or (hashtable-ref (font-face-files f) key #f)
                            (let ([nf (open-face (car m) (cadr m) (font-pixel-size f) #f #f)])
                              (when nf
                                (hashtable-set! (font-face-files f) key nf)
                                (font-fallbacks-set! f (append (font-fallbacks f) (list nf))))
                              nf))])
             (and face (not (= 0 (face-char-index face cp))) face)))))

  ;;; Rasterization --------------------------------------------------------------

  (define (copy-bitmap slot)
    ;; returns (values width height data color?)
    (let* ([rows (ftype-ref FT_GlyphSlotRec_ (bitmap rows) slot)]
           [width (ftype-ref FT_GlyphSlotRec_ (bitmap width) slot)]
           [pitch (ftype-ref FT_GlyphSlotRec_ (bitmap pitch) slot)]
           [buf (ftype-ref FT_GlyphSlotRec_ (bitmap buffer) slot)]
           [mode (ftype-ref FT_GlyphSlotRec_ (bitmap pixel_mode) slot)])
      (cond
        [(or (= width 0) (= rows 0) (ptr-null? buf))
         (values 0 0 (make-bytevector 0) #f)]
        [(= mode FT_PIXEL_MODE_GRAY)
         (let ([bv (make-bytevector (* width rows))])
           (do ([y 0 (fx+ y 1)]) ((fx= y rows))
             (let ([src (+ buf (* y pitch))] [dst (fx* y width)])
               (do ([x 0 (fx+ x 1)]) ((fx= x width))
                 (bytevector-u8-set! bv (fx+ dst x) (foreign-ref 'unsigned-8 src x)))))
           (values width rows bv #f))]
        [(= mode FT_PIXEL_MODE_MONO)
         (let ([bv (make-bytevector (* width rows))])
           (do ([y 0 (fx+ y 1)]) ((fx= y rows))
             (let ([src (+ buf (* y pitch))] [dst (fx* y width)])
               (do ([x 0 (fx+ x 1)]) ((fx= x width))
                 (let ([byte (foreign-ref 'unsigned-8 src (fxsrl x 3))])
                   (when (fxlogbit? (fx- 7 (fxand x 7)) byte)
                     (bytevector-u8-set! bv (fx+ dst x) 255))))))
           (values width rows bv #f))]
        [(= mode FT_PIXEL_MODE_BGRA)
         (let ([bv (make-bytevector (* 4 width rows))])
           (do ([y 0 (fx+ y 1)]) ((fx= y rows))
             (let ([src (+ buf (* y pitch))] [dst (fx* 4 (fx* y width))])
               (do ([x 0 (fx+ x 1)]) ((fx= x (fx* 4 width)))
                 (bytevector-u8-set! bv (fx+ dst x) (foreign-ref 'unsigned-8 src x)))))
           (values width rows bv #t))]
        [else (values 0 0 (make-bytevector 0) #f)])))

  ;; Box-filter a BGRA image by factor s (< 1).
  (define (scale-bgra data w h s)
    (let* ([nw (max 1 (exact (round (* w s))))]
           [nh (max 1 (exact (round (* h s))))]
           [out (make-bytevector (* 4 nw nh) 0)])
      (do ([y 0 (fx+ y 1)]) ((fx= y nh))
        (do ([x 0 (fx+ x 1)]) ((fx= x nw))
          (let ([x0 (exact (floor (/ x s)))] [x1 (min w (max 1 (exact (floor (/ (+ x 1) s)))))]
                [y0 (exact (floor (/ y s)))] [y1 (min h (max 1 (exact (floor (/ (+ y 1) s)))))])
            (let loop ([sy y0] [b 0] [g 0] [r 0] [a 0] [n 0])
              (if (fx>= sy (max y1 (+ y0 1)))
                  (let ([n (max n 1)] [o (fx* 4 (fx+ x (fx* y nw)))])
                    (bytevector-u8-set! out o (fxquotient b n))
                    (bytevector-u8-set! out (fx+ o 1) (fxquotient g n))
                    (bytevector-u8-set! out (fx+ o 2) (fxquotient r n))
                    (bytevector-u8-set! out (fx+ o 3) (fxquotient a n)))
                  (let xl ([sx x0] [b b] [g g] [r r] [a a] [n n])
                    (if (fx>= sx (max x1 (+ x0 1)))
                        (loop (fx+ sy 1) b g r a n)
                        (let ([i (fx* 4 (fx+ (min sx (- w 1)) (fx* (min sy (- h 1)) w)))])
                          (xl (fx+ sx 1)
                              (fx+ b (bytevector-u8-ref data i))
                              (fx+ g (bytevector-u8-ref data (fx+ i 1)))
                              (fx+ r (bytevector-u8-ref data (fx+ i 2)))
                              (fx+ a (bytevector-u8-ref data (fx+ i 3)))
                              (fx+ n 1))))))))))
      (values nw nh out)))

  (define (render-glyph f face gi)
    (let* ([ptr (face-ptr face)]
           [flags (logor FT_LOAD_DEFAULT FT_LOAD_TARGET_LIGHT (if (face-color? face) FT_LOAD_COLOR 0))])
      (if (not (= 0 (FT_Load_Glyph ptr gi flags)))
          empty-glyph
          (let ([slot (ftype-ref FT_FaceRec_ (glyph) (face-rec face))])
            (when (face-embolden? face) (FT_GlyphSlot_Embolden (ftype-pointer-address slot)))
            (when (face-oblique? face) (FT_GlyphSlot_Oblique (ftype-pointer-address slot)))
            (FT_Render_Glyph (ftype-pointer-address slot) FT_RENDER_MODE_NORMAL)
            (let ([left (ftype-ref FT_GlyphSlotRec_ (bitmap_left) slot)]
                  [top (ftype-ref FT_GlyphSlotRec_ (bitmap_top) slot)])
              (let-values ([(w h data color?) (copy-bitmap slot)])
                (let ([s (face-fixed-scale face)])
                  (if (and color? (< s 0.999))
                      (let-values ([(nw nh nd) (scale-bgra data w h s)])
                        (make-glyph nw nh (exact (round (* left s)))
                                    ;; center color bitmaps vertically in the cell
                                    (exact (round (- (font-baseline f)
                                                     (/ (- (font-cell-height f) nh) 2.0))))
                                    #t nd))
                      (make-glyph w h left top color? data)))))))))

  (define (builtin-glyph f cp)
    (let* ([w (font-cell-width f)] [h (font-cell-height f)]
           [bv (boxdraw-glyph cp w h (font-line-thickness f))])
      (and bv (make-glyph w h 0 (font-baseline f) #f bv))))

  ;; Glyph for code point CP in STYLE (0-3).
  (define (font-get-glyph f cp style)
    (let* ([key (fx+ (fx* cp 4) style)]
           [cache (font-glyph-cache f)])
      (or (hashtable-ref cache key #f)
          (let ([g (or (and (boxdraw-char? cp) (builtin-glyph f cp))
                       (let ([face (face-for f cp style)])
                         (if face
                             (render-glyph f face (face-char-index face cp))
                             ;; missing glyph: .notdef of the primary face
                             (render-glyph f (vector-ref (font-faces f) style) 0))))])
            (hashtable-set! cache key g)
            g))))

  ;; Glyph for a base character plus combining marks, drawn by overlaying
  ;; the marks' glyphs.
  (define (font-get-cluster-glyph f cp marks style)
    (let* ([key (string-append (string (integer->char cp)) marks (string (integer->char (+ 48 style))))]
           [cache (font-cluster-cache f)])
      (or (hashtable-ref cache key #f)
          (let* ([glyphs (cons (font-get-glyph f cp style)
                               (map (lambda (c) (font-get-glyph f (char->integer c) style))
                                    (string->list marks)))]
                 [glyphs (filter (lambda (g) (and (> (glyph-width g) 0) (not (glyph-color? g)))) glyphs)])
            (let ([g (if (null? glyphs)
                         (font-get-glyph f cp style)
                         (let* ([x0 (apply min (map glyph-left glyphs))]
                                [x1 (apply max (map (lambda (g) (+ (glyph-left g) (glyph-width g))) glyphs))]
                                [y0 (apply max (map glyph-top glyphs))]
                                [y1 (apply min (map (lambda (g) (- (glyph-top g) (glyph-height g))) glyphs))]
                                [w (- x1 x0)] [h (- y0 y1)]
                                [bv (make-bytevector (* w h) 0)])
                           (for-each
                            (lambda (g)
                              (let ([dx (- (glyph-left g) x0)] [dy (- y0 (glyph-top g))] [gw (glyph-width g)])
                                (do ([y 0 (fx+ y 1)]) ((fx= y (glyph-height g)))
                                  (do ([x 0 (fx+ x 1)]) ((fx= x gw))
                                    (let* ([i (fx+ (fx+ dx x) (fx* (fx+ dy y) w))]
                                           [a (bytevector-u8-ref (glyph-data g) (fx+ x (fx* y gw)))])
                                      (bytevector-u8-set! bv i (fxmax a (bytevector-u8-ref bv i))))))))
                            glyphs)
                           (make-glyph w h x0 y0 #f bv)))])
              (hashtable-set! cache key g)
              g))))))
