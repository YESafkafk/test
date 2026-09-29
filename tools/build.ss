;;; Compile chezterm and all libraries it imports (see Makefile).
;;;
;;; The hot paths (escape sequence parsing, grid operations and rendering)
;;; are compiled with optimize-level 3, which drops run-time type checks;
;;; these libraries are covered by the test suite (make test), which runs
;;; them with checks enabled.  Everything else uses the safe level 2.
(compile-imported-libraries #t)
(generate-inspector-information #f)
(define (build-lib name)
  (compile-library (format "src/chezterm/~a.ss" name) (format "build/lib/chezterm/~a.so" name)))
(parameterize ([optimize-level 2])
  (for-each build-lib '("ffi" "cutil" "charwidth" "boxdraw" "font")))
(parameterize ([optimize-level 3])
  (for-each build-lib '("grid" "terminal" "render")))
(parameterize ([optimize-level 2])
  (compile-program "src/main.ss" "build/main.so"))
