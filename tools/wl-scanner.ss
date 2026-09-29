;;; wl-scanner.ss -- a wayland-scanner replacement emitting Chez Scheme.
;;;
;;; Usage: scheme --libdirs tools --script tools/wl-scanner.ss [--library NAME] OUT.ss PROTOCOL.xml ...
;;; NAME defaults to "(chezterm protocols)".
;;;
;;; For every interface the generated library (chezterm protocols) defines
;;;  - an interface object (runtime descriptor, turned into a C wl_interface),
;;;  - one procedure per request, named like the C stubs (wl_surface_attach),
;;;  - constants for enum entries (WL_SEAT_CAPABILITY_KEYBOARD).
;;; Events are decoded at runtime by (chezterm wayland) from the descriptors.

(import (chezscheme) (xml))

(define (upcase s) (list->string (map char-upcase (string->list s))))

(define (sym . parts) (string->symbol (apply string-append parts)))

(define (arg-sig a)
  ;; returns (signature-chars . type-entries)
  (let* ([type (xml-attr a 'type)]
         [iface (xml-attr a 'interface)]
         [nullable (if (equal? (xml-attr a 'allow-null) "true") "?" "")])
    (cond
      [(equal? type "new_id")
       (if iface
           (cons (string-append nullable "n") (list iface))
           (cons "sun" (list #f #f #f)))]
      [else
       (cons (string-append nullable
                            (cdr (assoc type '(("int" . "i") ("uint" . "u") ("fixed" . "f")
                                               ("string" . "s") ("object" . "o")
                                               ("array" . "a") ("fd" . "h")))))
             (list (and (equal? type "object") iface)))])))

(define (message-desc m known)
  (let* ([args (xml-elements m 'arg)]
         [sigs (map arg-sig args)]
         [since (xml-attr m 'since)])
    `(list ,(xml-attr m 'name)
           ,(apply string-append (or since "") (map car sigs))
           (list ,@(map (lambda (t)
                          (if (and t (member t known)) (string->symbol t) #f))
                        (apply append (map cdr sigs)))))))

(define (request-proc iface-name opcode m known)
  (let* ([name (xml-attr m 'name)]
         [args (xml-elements m 'arg)]
         [destructor? (equal? (xml-attr m 'type) "destructor")]
         [new-arg (find (lambda (a) (equal? (xml-attr a 'type) "new_id")) args)]
         [new-iface (and new-arg (xml-attr new-arg 'interface))]
         [params (apply append
                        (map (lambda (a)
                               (let ([t (xml-attr a 'type)])
                                 (cond
                                   [(and (equal? t "new_id") (xml-attr a 'interface)) '()]
                                   [(equal? t "new_id") '(interface version)]
                                   [else (list (string->symbol (xml-attr a 'name)))])))
                             args))]
         [call-args (apply append
                           (map (lambda (a)
                                  (let ([t (xml-attr a 'type)])
                                    (cond
                                      [(and (equal? t "new_id") (xml-attr a 'interface)) '(0)]
                                      [(equal? t "new_id")
                                       '((wl-interface-name interface) version 0)]
                                      [else (list (string->symbol (xml-attr a 'name)))])))
                                args))]
         [target (cond
                   [(not new-arg) #f]
                   [new-iface (if (member new-iface known) (string->symbol new-iface) #f)]
                   [else 'interface])]
         [version (if (and new-arg (not new-iface)) 'version #f)])
    `(define (,(sym iface-name "_" name) proxy ,@params)
       (wl-marshal proxy ,(string->symbol iface-name) ,opcode ,target ,version
                   ,(if destructor? 1 0) ,@call-args))))

(define (enum-defs iface-name e)
  (map (lambda (entry)
         (let ([v (xml-attr entry 'value)])
           `(define ,(string->symbol (upcase (string-append iface-name "_" (xml-attr e 'name)
                                                            "_" (xml-attr entry 'name))))
              ,(if (and (> (string-length v) 2) (string=? (substring v 0 2) "0x"))
                   (string->number (substring v 2 (string-length v)) 16)
                   (string->number v)))))
       (xml-elements e 'entry)))

(define library-name '(chezterm protocols))

(define (main out files)
  (let* ([protos (map xml-read-file files)]
         [ifaces (apply append (map (lambda (p) (xml-elements p 'interface)) protos))]
         [known (map (lambda (i) (xml-attr i 'name)) ifaces)]
         [iface-defs
          (map (lambda (i)
                 `(define ,(string->symbol (xml-attr i 'name))
                    (make-wl-interface ,(xml-attr i 'name) ,(string->number (xml-attr i 'version)))))
               ifaces)]
         [message-inits
          (map (lambda (i)
                 `(wl-interface-set-messages!
                   ,(string->symbol (xml-attr i 'name))
                   (vector ,@(map (lambda (m) (message-desc m known)) (xml-elements i 'request)))
                   (vector ,@(map (lambda (m) (message-desc m known)) (xml-elements i 'event)))))
               ifaces)]
         [request-defs
          (apply append
                 (map (lambda (i)
                        (let* ([name (xml-attr i 'name)]
                               [reqs (xml-elements i 'request)]
                               [procs (let loop ([rs reqs] [op 0] [acc '()])
                                        (if (null? rs)
                                            (reverse acc)
                                            (loop (cdr rs) (+ op 1)
                                                  (cons (request-proc name op (car rs) known) acc))))])
                          ;; like the C scanner: provide NAME_destroy when the
                          ;; protocol does not define a destroy request
                          (if (or (equal? name "wl_display")
                                  (exists (lambda (r) (equal? (xml-attr r 'name) "destroy")) reqs))
                              procs
                              (append procs
                                      `((define (,(sym name "_destroy") proxy)
                                          (wl-proxy-destroy proxy)))))))
                      ifaces))]
         [enums (apply append
                       (map (lambda (i)
                              (apply append
                                     (map (lambda (e) (enum-defs (xml-attr i 'name) e))
                                          (xml-elements i 'enum))))
                            ifaces))]
         [exports (map cadr (append iface-defs enums))]
         [exports (append exports (map caadr request-defs))])
    (call-with-output-file out
      (lambda (o)
        (fprintf o ";;; Generated by tools/wl-scanner.ss from:~%")
        (for-each (lambda (f) (fprintf o ";;;   ~a~%" f)) files)
        (fprintf o ";;; Do not edit; run `make protocols` to regenerate.~%~%")
        (pretty-print
         `(library ,library-name
            (export ,@exports)
            (import (chezscheme) (chezterm wayland))
            ,@iface-defs
            (define messages-initialized
              (begin ,@message-inits #t))
            ,@request-defs
            ,@enums)
         o))
      'replace)))

(let ([args (let ([args (command-line-arguments)])
              (if (and (pair? args) (equal? (car args) "--library") (pair? (cdr args)))
                  (begin
                    (set! library-name (read (open-input-string (cadr args))))
                    (cddr args))
                  args))])
  (if (< (length args) 2)
      (begin (display "usage: wl-scanner.ss OUT.ss PROTOCOL.xml ...\n") (exit 1))
      (main (car args) (cdr args))))
