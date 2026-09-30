;;; Compile chezterm and all libraries it imports (see Makefile).
;;;
;;; Everything is compiled with optimize-level 2, which keeps the run-time
;;; type and bounds checks.
(compile-imported-libraries #t)
(generate-inspector-information #f)
(define (build-lib name)
  (compile-library (format "src/chezterm/~a.ss" name) (format "build/lib/chezterm/~a.so" name)))
(parameterize ([optimize-level 2])
  (for-each build-lib '("ffi" "cutil" "charwidth" "boxdraw" "font" "grid" "terminal" "render" "hints"))
  (compile-program "src/main.ss" "build/main.so"))
