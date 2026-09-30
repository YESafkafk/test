;;; Choosing TERM for the programs chezterm runs.
;;;
;;; With `term` configured, that value is used as is.  Otherwise chezterm
;;; uses its own terminfo entry, "chezterm", when the programs can find it:
;;; either it is installed where ncurses looks by default, or it is in the
;;; directory chezterm was installed with (CHEZTERM_TERMINFO, set by the
;;; launcher), which is then added to TERMINFO_DIRS.  If neither, TERM is
;;; xterm-256color, which chezterm is compatible with.
(library (chezterm termenv)
  (export term-environment terminfo-entry-in?)
  (import (chezscheme))

  (define entry "chezterm")
  (define fallback "xterm-256color")

  ;; Does terminfo directory DIR contain NAME?  ncurses uses either a
  ;; first-letter subdirectory or (on case-insensitive systems) its hex code.
  (define (terminfo-entry-in? dir name exists?)
    (let ([c (string-ref name 0)])
      (or (exists? (format "~a/~a/~a" dir c name))
          (exists? (format "~a/~x/~a" dir (char->integer c) name)))))

  (define (split-path s)
    (let loop ([i 0] [start 0] [acc '()])
      (cond
        [(= i (string-length s)) (reverse (cons (substring s start i) acc))]
        [(char=? (string-ref s i) #\:) (loop (+ i 1) (+ i 1) (cons (substring s start i) acc))]
        [else (loop (+ i 1) start acc)])))

  ;; Directories ncurses searches when TERMINFO is unset.  An empty
  ;; TERMINFO_DIRS component stands for the compiled-in default.
  (define (system-dirs getenv)
    (let* ([home (getenv "HOME")]
           [defaults '("/etc/terminfo" "/lib/terminfo" "/usr/share/terminfo"
                       "/usr/lib/terminfo" "/usr/local/share/terminfo"
                       "/run/current-system/sw/share/terminfo")]
           [dirs-env (getenv "TERMINFO_DIRS")])
      (append (let ([t (getenv "TERMINFO")]) (if t (list t) '()))
              (if home
                  (list (string-append home "/.terminfo")
                        (string-append home "/.nix-profile/share/terminfo"))
                  '())
              (if dirs-env
                  (apply append (map (lambda (d) (if (string=? d "") defaults (list d)))
                                     (split-path dirs-env)))
                  defaults))))

  ;; Environment variables (an alist) describing the terminal type.
  ;; CONFIGURED is the `term` option (#f for automatic), BUNDLED the
  ;; directory holding chezterm's own compiled entry (or #f).
  (define (term-environment configured bundled getenv exists?)
    (cond
      [configured (list (cons "TERM" configured))]
      [(exists (lambda (d) (terminfo-entry-in? d entry exists?)) (system-dirs getenv))
       (list (cons "TERM" entry))]
      [(and bundled (terminfo-entry-in? bundled entry exists?))
       ;; keep whatever the user had, and the default search path (the
       ;; trailing empty component)
       (let ([dirs (getenv "TERMINFO_DIRS")])
         (list (cons "TERM" entry)
               (cons "TERMINFO_DIRS"
                     (if (and dirs (not (string=? dirs "")))
                         (string-append bundled ":" dirs)
                         (string-append bundled ":")))))]
      [else (list (cons "TERM" fallback))])))
