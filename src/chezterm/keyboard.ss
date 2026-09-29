;;; Keyboard: xkbcommon keymap/state, compose sequences (dead keys) and the
;;; translation of key presses to the byte sequences terminals expect.
(library (chezterm keyboard)
  (export make-keyboard keyboard? keyboard-set-keymap! keyboard-update-modifiers!
          keyboard-translate keyboard-repeats? keyboard-mods
          MOD-SHIFT MOD-ALT MOD-CTRL MOD-SUPER
          encode-key keysym-by-name keysym-lower parse-key-binding
          make-key-event key-event-sym key-event-text key-event-mods key-event?)
  (import (chezscheme) (chezterm ffi) (chezterm cutil))

  (define MOD-SHIFT 1)
  (define MOD-ALT 2)
  (define MOD-CTRL 4)
  (define MOD-SUPER 8)

  (define (keysym-by-name name) (xkb_keysym_from_name name XKB_KEYSYM_CASE_INSENSITIVE))
  (define (keysym-lower sym) (xkb_keysym_to_lower sym))

  (define-record-type keyboard
    (fields context
            (mutable keymap) (mutable state)
            (mutable compose-state)
            (mutable mod-indices)        ; vector of xkb mod indices
            (mutable mods))
    (protocol
     (lambda (new)
       (lambda ()
         (let* ([ctx (xkb_context_new XKB_CONTEXT_NO_FLAGS)]
                [locale (or (getenv "LC_ALL") (getenv "LC_CTYPE") (getenv "LANG") "C")]
                [table (xkb_compose_table_new_from_locale ctx locale 0)]
                [cstate (if (ptr-null? table) 0 (xkb_compose_state_new table 0))])
           (new ctx 0 0 cstate (vector) 0))))))

  ;; A translated key press.
  (define-record-type key-event (fields sym text mods))

  ;; Load the keymap the compositor sent (fd + size of a text keymap).
  (define (keyboard-set-keymap! kb fd size)
    (let ([p (mmap 0 size PROT_READ 2 fd 0)])     ; MAP_PRIVATE = 2
      (close fd)
      (unless (= p (- (expt 2 64) 1))
        (let ([km (xkb_keymap_new_from_string (keyboard-context kb) p XKB_KEYMAP_FORMAT_TEXT_V1
                                              XKB_KEYMAP_COMPILE_NO_FLAGS)])
          (munmap p size)
          (unless (ptr-null? km)
            (unless (ptr-null? (keyboard-state kb)) (xkb_state_unref (keyboard-state kb)))
            (unless (ptr-null? (keyboard-keymap kb)) (xkb_keymap_unref (keyboard-keymap kb)))
            (keyboard-keymap-set! kb km)
            (keyboard-state-set! kb (xkb_state_new km))
            (keyboard-mod-indices-set!
             kb (vector (xkb_keymap_mod_get_index km "Shift")
                        (xkb_keymap_mod_get_index km "Mod1")
                        (xkb_keymap_mod_get_index km "Control")
                        (xkb_keymap_mod_get_index km "Mod4"))))))))

  (define (keyboard-update-modifiers! kb depressed latched locked group)
    (let ([st (keyboard-state kb)])
      (unless (ptr-null? st)
        (xkb_state_update_mask st depressed latched locked 0 0 group)
        (let ([idx (keyboard-mod-indices kb)])
          (keyboard-mods-set!
           kb
           (let loop ([i 0] [m 0])
             (if (= i 4)
                 m
                 (loop (+ i 1)
                       (if (> (xkb_state_mod_index_is_active st (vector-ref idx i) XKB_STATE_MODS_EFFECTIVE) 0)
                           (logor m (vector-ref '#(1 2 4 8) i))
                           m)))))))))

  (define (keyboard-repeats? kb key)
    (and (not (ptr-null? (keyboard-keymap kb)))
         (= 1 (xkb_keymap_key_repeats (keyboard-keymap kb) (+ key 8)))))

  (define compose-buf (malloc 64))

  ;; Translate a pressed evdev KEY into a key-event, or #f while a compose
  ;; sequence is in progress.
  (define (keyboard-translate kb key)
    (let ([st (keyboard-state kb)])
      (and (not (ptr-null? st))
           (let* ([code (+ key 8)]
                  [sym (xkb_state_key_get_one_sym st code)]
                  [cs (keyboard-compose-state kb)]
                  [status (if (ptr-null? cs)
                              XKB_COMPOSE_NOTHING
                              (begin
                                (xkb_compose_state_feed cs sym)
                                (xkb_compose_state_get_status cs)))])
             (cond
               [(= status XKB_COMPOSE_COMPOSING) #f]
               [(= status XKB_COMPOSE_CANCELLED) (xkb_compose_state_reset cs) #f]
               [(= status XKB_COMPOSE_COMPOSED)
                (let ([n (xkb_compose_state_get_utf8 cs compose-buf 64)]
                      [csym (xkb_compose_state_get_one_sym cs)])
                  (xkb_compose_state_reset cs)
                  (make-key-event csym (if (> n 0) (cstring->string compose-buf) "")
                                  (keyboard-mods kb)))]
               [else
                (let ([cp (xkb_state_key_get_utf32 st code)])
                  (make-key-event sym
                                  (if (and (> cp 0) (not (<= #xD800 cp #xDFFF)) (< cp #x110000))
                                      (string (integer->char cp))
                                      "")
                                  (keyboard-mods kb)))])))))

  ;;; Encoding -------------------------------------------------------------------

  (define-syntax define-keysyms
    (syntax-rules ()
      [(_ (var name) ...) (begin (define var (keysym-by-name name)) ...)]))

  (define-keysyms
    (XK-Up "Up") (XK-Down "Down") (XK-Left "Left") (XK-Right "Right")
    (XK-Home "Home") (XK-End "End") (XK-Insert "Insert") (XK-Delete "Delete")
    (XK-Prior "Prior") (XK-Next "Next")
    (XK-BackSpace "BackSpace") (XK-Tab "Tab") (XK-ISO-Left-Tab "ISO_Left_Tab")
    (XK-Return "Return") (XK-Escape "Escape")
    (XK-KP-Enter "KP_Enter") (XK-KP-Up "KP_Up") (XK-KP-Down "KP_Down")
    (XK-KP-Left "KP_Left") (XK-KP-Right "KP_Right") (XK-KP-Home "KP_Home")
    (XK-KP-End "KP_End") (XK-KP-Prior "KP_Prior") (XK-KP-Next "KP_Next")
    (XK-KP-Insert "KP_Insert") (XK-KP-Delete "KP_Delete") (XK-KP-Begin "KP_Begin")
    (XK-KP-0 "KP_0") (XK-KP-9 "KP_9") (XK-KP-Decimal "KP_Decimal")
    (XK-KP-Add "KP_Add") (XK-KP-Subtract "KP_Subtract") (XK-KP-Multiply "KP_Multiply")
    (XK-KP-Divide "KP_Divide") (XK-KP-Separator "KP_Separator") (XK-KP-Equal "KP_Equal")
    (XK-F1 "F1") (XK-F35 "F35"))

  (define (csi-mod mods)
    ;; xterm modifier parameter: 1 + shift + 2*alt + 4*ctrl + 8*super
    (+ 1 mods))

  ;; CSI sequences for cursor-like keys: final char and SS3 form
  (define (cursor-key final mods app-cursor)
    (cond
      [(not (= mods 0)) (format "\x1b;[1;~a~a" (csi-mod mods) final)]
      [app-cursor (format "\x1b;O~a" final)]
      [else (format "\x1b;[~a" final)]))

  (define (tilde-key n mods)
    (if (= mods 0)
        (format "\x1b;[~a~~" n)
        (format "\x1b;[~a;~a~~" n (csi-mod mods))))

  (define function-key-codes
    ;; F5.. F20
    '#(15 17 18 19 20 21 23 24 25 26 28 29 31 32 33 34))

  (define (control-char sym)
    ;; control code for Ctrl+<key>, from the (lowercased) keysym
    (cond
      [(<= 97 sym 122) (- sym 96)]                    ; a-z
      [(memv sym '(64 32 50)) 0]                      ; @ space 2
      [(memv sym '(91 51)) 27]                        ; [ 3
      [(memv sym '(92 52)) 28]                        ; \ 4
      [(memv sym '(93 53)) 29]                        ; ] 5
      [(memv sym '(94 54 126)) 30]                    ; ^ 6 ~
      [(memv sym '(95 55 47)) 31]                     ; _ 7 /
      [(memv sym '(56 63)) 127]                       ; 8 ?
      [else #f]))

  ;; Bytes (as a string) to send for key event EV given terminal modes, or
  ;; #f when the key produces nothing.
  (define (encode-key ev app-cursor app-keypad newline-mode)
    (let* ([sym (key-event-sym ev)]
           [text (key-event-text ev)]
           [mods (key-event-mods ev)]
           ;; shift is implied in text; only report it for special keys
           [alt (logtest mods MOD-ALT)]
           [ctrl (logtest mods MOD-CTRL)]
           [esc (lambda (s) (if alt (string-append "\x1b;" s) s))])
      (cond
        [(or (= sym XK-Up) (= sym XK-KP-Up)) (cursor-key "A" mods app-cursor)]
        [(or (= sym XK-Down) (= sym XK-KP-Down)) (cursor-key "B" mods app-cursor)]
        [(or (= sym XK-Right) (= sym XK-KP-Right)) (cursor-key "C" mods app-cursor)]
        [(or (= sym XK-Left) (= sym XK-KP-Left)) (cursor-key "D" mods app-cursor)]
        [(or (= sym XK-Home) (= sym XK-KP-Home)) (cursor-key "H" mods app-cursor)]
        [(or (= sym XK-End) (= sym XK-KP-End)) (cursor-key "F" mods app-cursor)]
        [(= sym XK-KP-Begin) (cursor-key "E" mods app-cursor)]
        [(or (= sym XK-Insert) (= sym XK-KP-Insert)) (tilde-key 2 mods)]
        [(or (= sym XK-Delete) (= sym XK-KP-Delete)) (tilde-key 3 mods)]
        [(or (= sym XK-Prior) (= sym XK-KP-Prior)) (tilde-key 5 mods)]
        [(or (= sym XK-Next) (= sym XK-KP-Next)) (tilde-key 6 mods)]
        [(<= XK-F1 sym (+ XK-F1 3))
         (let ([c (string-ref "PQRS" (- sym XK-F1))])
           (if (= mods 0) (format "\x1b;O~a" c) (format "\x1b;[1;~a~a" (csi-mod mods) c)))]
        [(<= (+ XK-F1 4) sym (+ XK-F1 19))
         (tilde-key (vector-ref function-key-codes (- sym XK-F1 4)) mods)]
        [(= sym XK-BackSpace)
         (esc (if ctrl "\b" "\x7f;"))]
        [(= sym XK-ISO-Left-Tab) "\x1b;[Z"]
        [(= sym XK-Tab)
         (if (logtest mods MOD-SHIFT) "\x1b;[Z" (esc "\t"))]
        [(= sym XK-Return) (esc (if newline-mode "\r\n" "\r"))]
        [(= sym XK-KP-Enter)
         (if (and app-keypad (= mods 0)) "\x1b;OM" (esc (if newline-mode "\r\n" "\r")))]
        [(= sym XK-Escape) (esc "\x1b;")]
        [(and app-keypad (= mods 0) (keypad-app-char sym))
         => (lambda (c) (format "\x1b;O~a" c))]
        [(and ctrl (control-char (keysym-lower sym)))
         => (lambda (c) (esc (string (integer->char c))))]
        [(and ctrl (> (string-length text) 0) (< (char->integer (string-ref text 0)) 32))
         (esc text)]
        [(> (string-length text) 0) (esc text)]
        [else #f])))

  (define (keypad-app-char sym)
    (cond
      [(<= XK-KP-0 sym XK-KP-9) (integer->char (+ 112 (- sym XK-KP-0)))]
      [(= sym XK-KP-Decimal) #\n]
      [(= sym XK-KP-Add) #\k]
      [(= sym XK-KP-Subtract) #\m]
      [(= sym XK-KP-Multiply) #\j]
      [(= sym XK-KP-Divide) #\o]
      [(= sym XK-KP-Separator) #\l]
      [(= sym XK-KP-Equal) #\X]
      [else #f]))

  ;; "ctrl+shift+c" -> (mods . lowercase-keysym)
  (define (parse-key-binding s)
    (let loop ([parts (let split ([i 0] [start 0] [acc '()])
                        (cond
                          [(= i (string-length s)) (reverse (cons (substring s start i) acc))]
                          [(and (char=? (string-ref s i) #\+) (> i start))
                           (split (+ i 1) (+ i 1) (cons (substring s start i) acc))]
                          [else (split (+ i 1) start acc)]))]
               [mods 0])
      (cond
        [(null? parts) #f]
        [(null? (cdr parts))
         (let ([sym (keysym-by-name (car parts))])
           (and (not (= sym 0)) (cons mods (keysym-lower sym))))]
        [else
         (let ([m (string-downcase (car parts))])
           (loop (cdr parts)
                 (logor mods
                        (cond [(string=? m "shift") MOD-SHIFT]
                              [(member m '("alt" "meta")) MOD-ALT]
                              [(member m '("ctrl" "control")) MOD-CTRL]
                              [(member m '("super" "logo")) MOD-SUPER]
                              [else 0]))))]))))
