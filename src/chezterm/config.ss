;;; Configuration: defaults and loading of $XDG_CONFIG_HOME/chezterm/chezterm.scm.
;;;
;;; The configuration file is a sequence of S-expressions of the form
;;; (option value ...), for example:
;;;
;;;   (font-family "JetBrains Mono")
;;;   (font-size 12)
;;;   (colors (background "#1d1f21") (foreground "#c5c8c6"))
;;;   (bind "ctrl+shift+t" spawn-new-instance)
;;;
;;; See chezterm.scm.example for all options.
(library (chezterm config)
  (export load-config config-ref config-path parse-hex-color default-config
          set-config-overrides! config-normalize)
  (import (chezscheme))

  (define (parse-hex-color s)
    (and (string? s)
         (fx= (string-length s) 7)
         (char=? (string-ref s 0) #\#)
         (string->number (substring s 1 7) 16)))

  (define default-config
    `((font-family . "monospace")
      (font-size . 11.0)
      (font-bold-family . #f)
      (font-italic-family . #f)
      (dpi . 96.0)
      (columns . 80)
      (lines . 24)
      (scrollback . 10000)
      (shell . #f)                      ; #f: $SHELL
      (working-directory . #f)
      (padding . (2 2))
      (opacity . 1.0)
      (title . "chezterm")
      (app-id . "chezterm")
      (dynamic-title . #t)
      (decorations . #t)
      (term . #f)                       ; #f: "chezterm" if its terminfo is found
      (env . ())
      (kitty-keyboard . #t)             ; answer the kitty keyboard protocol
      (kitty-keyboard-legacy-csi-u . #f) ; CSI u for keys without a legacy encoding
      (cursor-style . block)            ; block | underline | beam
      (cursor-blink . #f)
      (cursor-blink-interval . 750)
      (cursor-unfocused-hollow . #t)
      (bold-is-bright . #f)
      (scroll-multiplier . 3)
      (alternate-scroll . #t)
      (copy-on-select . #t)             ; selections go to the primary selection
      (word-separators . ",│`|:\"' ()[]{}<>\t")
      (bell-command . #f)               ; e.g. ("paplay" "/usr/share/sounds/bell.oga")
      (colors
       . ((foreground . "#d8d8d8")
          (background . "#181818")
          (cursor . "#d8d8d8")
          (selection-foreground . #f)
          (selection-background . "#4f4f4f")
          (normal . ("#181818" "#ac4242" "#90a959" "#f4bf75"
                     "#6a9fb5" "#aa759f" "#75b5aa" "#d8d8d8"))
          (bright . ("#6b6b6b" "#c55555" "#aac474" "#feca88"
                     "#82b8c8" "#c28cb8" "#93d3c3" "#f8f8f8"))))
      (bindings
       . (("ctrl+shift+c" . copy)
          ("ctrl+shift+v" . paste)
          ("shift+insert" . paste-primary)
          ("ctrl+insert" . copy)
          ("ctrl+equal" . increase-font-size)
          ("ctrl+plus" . increase-font-size)
          ("ctrl+shift+plus" . increase-font-size)
          ("ctrl+kp_add" . increase-font-size)
          ("ctrl+minus" . decrease-font-size)
          ("ctrl+kp_subtract" . decrease-font-size)
          ("ctrl+0" . reset-font-size)
          ("shift+page_up" . scroll-page-up)
          ("shift+page_down" . scroll-page-down)
          ("shift+home" . scroll-to-top)
          ("shift+end" . scroll-to-bottom)
          ("ctrl+shift+up" . scroll-line-up)
          ("ctrl+shift+down" . scroll-line-down)
          ("ctrl+shift+k" . clear-history)
          ("ctrl+shift+n" . spawn-new-instance)
          ("ctrl+shift+f" . search-forward)
          ("ctrl+shift+b" . search-backward)
          ("f11" . toggle-fullscreen)))))

  (define (config-path)
    (let ([base (or (getenv "XDG_CONFIG_HOME")
                    (let ([h (getenv "HOME")]) (and h (string-append h "/.config"))))])
      (and base (string-append base "/chezterm/chezterm.scm"))))

  (define current '())
  (define overrides '())

  (define (set-config-overrides! alist) (set! overrides alist))

  (define (config-ref key)
    (let ([e (or (assq key overrides) (assq key current) (assq key default-config))])
      (if e (cdr e) (errorf 'config-ref "unknown option ~s" key))))

  ;; merge an alist of overrides into an alist of defaults
  (define (merge-alist base overrides)
    (fold-left (lambda (acc o)
                 (cons o (remp (lambda (e) (eq? (car e) (car o))) acc)))
               base overrides))

  (define (config-normalize form) (normalize form))

  (define (normalize form)
    ;; (option v) -> (option . v); (option v1 v2 ...) -> (option . (v1 v2 ...))
    (let ([key (car form)] [args (cdr form)])
      (case key
        [(colors)
         (cons 'colors
               (merge-alist (cdr (assq 'colors default-config))
                      (map (lambda (c) (if (and (pair? (cdr c)) (null? (cddr c))
                                                (not (memq (car c) '(normal bright))))
                                           (cons (car c) (cadr c))
                                           (cons (car c) (cdr c))))
                           args)))]
        [(shell bell-command) (cons key (if (equal? args '(#f)) #f args))]
        [(padding env) (cons key args)]
        [else (cons key (if (and (pair? args) (null? (cdr args))) (car args) args))])))

  (define (load-config path)
    (set! current '())
    (when (and path (file-exists? path))
      (guard (e [#t (let ([p (current-error-port)])
                      (fprintf p "chezterm: error in ~a: " path)
                      (display-condition e p)
                      (newline p))])
        (let ([forms (call-with-input-file path
                       (lambda (p)
                         (let loop ([acc '()])
                           (let ([x (read p)])
                             (if (eof-object? x) (reverse acc) (loop (cons x acc)))))))])
          (let loop ([forms forms] [binds '()] [opts '()])
            (cond
              [(null? forms)
               (set! current
                     (let ([opts (reverse opts)])
                       (if (null? binds)
                           opts
                           (cons (cons 'bindings
                                       (append (reverse binds) (cdr (assq 'bindings default-config))))
                                 opts))))]
              [(and (pair? (car forms)) (eq? (caar forms) 'bind))
               ;; (bind "keys" action)  action: symbol, string (text to send) or none
               (let ([f (car forms)])
                 (loop (cdr forms) (cons (cons (cadr f) (caddr f)) binds) opts))]
              [(and (pair? (car forms)) (symbol? (caar forms)))
               (let ([n (normalize (car forms))])
                 (unless (assq (car n) default-config)
                   (fprintf (current-error-port) "chezterm: unknown option ~s\n" (car n)))
                 (loop (cdr forms) binds (cons n opts)))]
              [else (loop (cdr forms) binds opts)]))))))
  )
