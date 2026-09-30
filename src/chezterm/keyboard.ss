;;; Keyboard: xkbcommon keymap/state, compose sequences (dead keys) and the
;;; translation of key events to the byte sequences terminals expect: the
;;; legacy xterm encoding, and the kitty keyboard protocol.
(library (chezterm keyboard)
  (export make-keyboard keyboard? keyboard-set-keymap! keyboard-set-keymap-string!
          keyboard-update-modifiers!
          keyboard-translate keyboard-repeats? keyboard-mods keyboard-locks
          MOD-SHIFT MOD-ALT MOD-CTRL MOD-SUPER MOD-HYPER MOD-META MOD-CAPS-LOCK MOD-NUM-LOCK
          KBD-DISAMBIGUATE KBD-EVENT-TYPES KBD-ALTERNATE-KEYS KBD-ALL-KEYS KBD-TEXT
          KEY-PRESS KEY-REPEAT KEY-RELEASE
          encode-key keysym-by-name keysym-lower parse-key-binding
          make-key-event key-event-sym key-event-text key-event-mods key-event?
          key-event-locks key-event-key key-event-shifted key-event-base key-event-type
          key-event-composed? key-event-with-type key-event-modifier-key?)
  (import (chezscheme) (chezterm ffi) (chezterm cutil))

  ;; Modifier bits, as the kitty keyboard protocol numbers them.  key-event-mods
  ;; holds the first four (what the legacy encoding and key bindings use),
  ;; key-event-locks the lock bits.
  (define MOD-SHIFT 1)
  (define MOD-ALT 2)
  (define MOD-CTRL 4)
  (define MOD-SUPER 8)
  (define MOD-HYPER 16)
  (define MOD-META 32)
  (define MOD-CAPS-LOCK 64)
  (define MOD-NUM-LOCK 128)

  ;; Progressive enhancement flags of the kitty keyboard protocol.
  (define KBD-DISAMBIGUATE 1)
  (define KBD-EVENT-TYPES 2)
  (define KBD-ALTERNATE-KEYS 4)
  (define KBD-ALL-KEYS 8)
  (define KBD-TEXT 16)

  ;; Event types, numbered as in the protocol.
  (define KEY-PRESS 1)
  (define KEY-REPEAT 2)
  (define KEY-RELEASE 3)

  (define (keysym-by-name name) (xkb_keysym_from_name name XKB_KEYSYM_CASE_INSENSITIVE))
  (define (keysym-lower sym) (xkb_keysym_to_lower sym))

  (define-record-type keyboard
    (fields context
            (mutable keymap) (mutable state)
            (mutable compose-state)
            (mutable mod-indices)        ; vector of xkb mod indices
            (mutable mods)               ; MOD-SHIFT/ALT/CTRL/SUPER bits
            (mutable locks)              ; MOD-CAPS-LOCK/NUM-LOCK bits
            (mutable held))              ; ((evdev key . mod bit) ...) of modifier keys
    (protocol
     (lambda (new)
       (lambda ()
         (let* ([ctx (xkb_context_new XKB_CONTEXT_NO_FLAGS)]
                [locale (or (getenv "LC_ALL") (getenv "LC_CTYPE") (getenv "LANG") "C")]
                [table (xkb_compose_table_new_from_locale ctx locale 0)]
                [cstate (if (ptr-null? table) 0 (xkb_compose_state_new table 0))])
           (new ctx 0 0 cstate (vector) 0 0 '()))))))

  ;; A translated key event.
  ;;   sym       keysym, with the active modifiers applied
  ;;   text      text the key produces ("" if none)
  ;;   mods      MOD-SHIFT/ALT/CTRL/SUPER bits
  ;;   locks     MOD-CAPS-LOCK/NUM-LOCK bits
  ;;   key       keysym without modifiers (level 1 of the active layout)
  ;;   shifted   code point of sym when it differs from key's, else 0
  ;;   base      code point of the key in the first layout when it differs
  ;;             from key's, else 0
  ;;   type      KEY-PRESS, KEY-REPEAT or KEY-RELEASE
  ;;   composed  #t for the result of a compose sequence (or dead key): text
  ;;             that belongs to no single key
  (define-record-type (key-event mk-key-event key-event?)
    (fields sym text mods locks key shifted base type composed?))

  ;; (make-key-event sym text mods) makes a press, taking the other fields from
  ;; SYM, as for a keyboard with a single layout.
  (define make-key-event
    (case-lambda
      [(sym text mods)
       (let* ([key (let ([k (keysym-lower sym)]) (if (= k XK-ISO-Left-Tab) XK-Tab k))]
              [cp (xkb_keysym_to_utf32 sym)])
         (mk-key-event sym text mods 0 key (if (= cp (xkb_keysym_to_utf32 key)) 0 cp) 0 KEY-PRESS #f))]
      [(sym text mods locks key shifted base type composed)
       (mk-key-event sym text mods locks key shifted base type composed)]))

  (define (key-event-with-type ev type)
    (mk-key-event (key-event-sym ev) (key-event-text ev) (key-event-mods ev) (key-event-locks ev)
                  (key-event-key ev) (key-event-shifted ev) (key-event-base ev) type
                  (key-event-composed? ev)))

  ;; Load the keymap the compositor sent (fd + size of a text keymap).
  (define (keyboard-set-keymap! kb fd size)
    (let ([p (mmap 0 size PROT_READ 2 fd 0)])     ; MAP_PRIVATE = 2
      (close fd)
      (unless (= p (- (expt 2 64) 1))
        (load-keymap! kb p)
        (munmap p size))))

  ;; Load a keymap given as text (for the tests).
  (define (keyboard-set-keymap-string! kb text)
    (with-cstring text (lambda (p) (load-keymap! kb p))))

  (define (load-keymap! kb p)
    (let ([km (xkb_keymap_new_from_string (keyboard-context kb) p XKB_KEYMAP_FORMAT_TEXT_V1
                                          XKB_KEYMAP_COMPILE_NO_FLAGS)])
      (unless (ptr-null? km)
        (unless (ptr-null? (keyboard-state kb)) (xkb_state_unref (keyboard-state kb)))
        (unless (ptr-null? (keyboard-keymap kb)) (xkb_keymap_unref (keyboard-keymap kb)))
        (keyboard-keymap-set! kb km)
        (keyboard-state-set! kb (xkb_state_new km))
        (keyboard-held-set! kb '())
        (keyboard-mod-indices-set!
         kb (vector (xkb_keymap_mod_get_index km "Shift")
                    (xkb_keymap_mod_get_index km "Mod1")
                    (xkb_keymap_mod_get_index km "Control")
                    (xkb_keymap_mod_get_index km "Mod4")
                    (xkb_keymap_mod_get_index km "Lock")
                    (xkb_keymap_mod_get_index km "Mod2"))))))   ; Num Lock

  (define mod-bits (vector MOD-SHIFT MOD-ALT MOD-CTRL MOD-SUPER MOD-CAPS-LOCK MOD-NUM-LOCK))

  (define (keyboard-update-modifiers! kb depressed latched locked group)
    (let ([st (keyboard-state kb)])
      (unless (ptr-null? st)
        (xkb_state_update_mask st depressed latched locked 0 0 group)
        (let* ([idx (keyboard-mod-indices kb)]
               [m (let loop ([i 0] [m 0])
                    (if (= i (vector-length idx))
                        m
                        (loop (+ i 1)
                              (if (> (xkb_state_mod_index_is_active st (vector-ref idx i) XKB_STATE_MODS_EFFECTIVE) 0)
                                  (logor m (vector-ref mod-bits i))
                                  m))))])
          (keyboard-mods-set! kb (logand m 15))
          (keyboard-locks-set! kb (logand m (logor MOD-CAPS-LOCK MOD-NUM-LOCK)))))))

  (define (keyboard-repeats? kb key)
    (and (not (ptr-null? (keyboard-keymap kb)))
         (= 1 (xkb_keymap_key_repeats (keyboard-keymap kb) (+ key 8)))))

  (define compose-buf (malloc 64))
  (define syms-buf (malloc 8))

  ;; The keysym of KEY (an xkb keycode) at the first shift level of LAYOUT,
  ;; or #f.
  (define (level1-sym km key layout)
    (and (= 1 (xkb_keymap_key_get_syms_by_level km key layout 0 syms-buf))
         (foreign-ref 'unsigned-32 (foreign-ref 'uptr syms-buf 0) 0)))

  (define (utf32 sym) (xkb_keysym_to_utf32 sym))

  ;; The modifier bit a modifier key sets.  The kitty keyboard protocol wants
  ;; it in the key's own events, but xkb's state only changes after them.
  (define (modifier-key-bit sym)
    (cond
      [(memv sym (list XK-Shift-L XK-Shift-R)) MOD-SHIFT]
      [(memv sym (list XK-Control-L XK-Control-R)) MOD-CTRL]
      [(memv sym (list XK-Alt-L XK-Alt-R)) MOD-ALT]
      [(memv sym (list XK-Super-L XK-Super-R)) MOD-SUPER]
      [(= sym XK-Caps-Lock) MOD-CAPS-LOCK]
      [(= sym XK-Num-Lock) MOD-NUM-LOCK]
      [else #f]))

  ;; Modifiers and locks of an event of modifier key KEY (with keysym SYM),
  ;; as they are after the event.  Releasing one Ctrl key while the other is
  ;; held keeps Ctrl.
  (define (modifier-key-state! kb key sym press)
    (let ([bit (modifier-key-bit sym)] [mods (keyboard-mods kb)] [locks (keyboard-locks kb)])
      (keyboard-held-set! kb (let ([h (remp (lambda (e) (= (car e) key)) (keyboard-held kb))])
                               (if (and press bit) (cons (cons key bit) h) h)))
      (cond
        [(not bit) (values mods locks)]
        [(memv bit (list MOD-CAPS-LOCK MOD-NUM-LOCK))
         ;; a lock key toggles its lock when pressed
         (values mods (if press (logxor locks bit) locks))]
        [(or press (exists (lambda (e) (= (cdr e) bit)) (keyboard-held kb)))
         (values (logor mods bit) locks)]
        [else (values (logand mods (lognot bit)) locks)])))

  ;; Translate the press or release (TYPE) of evdev KEY into a key-event, or
  ;; #f while a compose sequence is in progress.
  (define (keyboard-translate kb key type)
    (let ([st (keyboard-state kb)] [km (keyboard-keymap kb)] [press (= type KEY-PRESS)])
      (and (not (ptr-null? st))
           (let* ([code (+ key 8)]
                  [sym (xkb_state_key_get_one_sym st code)]
                  [layout (xkb_state_key_get_layout st code)]
                  ;; the key without modifiers; keypad keys keep what Num Lock
                  ;; made of them
                  [key-sym (if (<= XK-KP-Space sym XK-KP-Equal)
                               sym
                               (or (level1-sym km code layout) sym))]
                  [base-sym (or (level1-sym km code 0) key-sym)]
                  [shifted (if (= sym key-sym) 0 (utf32 sym))]
                  [base (if (= (utf32 base-sym) (utf32 key-sym)) 0 (utf32 base-sym))]
                  [event (lambda (sym text composed mods locks)
                           (make-key-event sym text mods locks key-sym shifted base type composed))])
             (cond
               [(modifier-key-bit key-sym)
                (let-values ([(mods locks) (modifier-key-state! kb key key-sym press)])
                  (event sym "" #f mods locks))]
               [(memv key-sym modifier-keys)
                (event sym "" #f (keyboard-mods kb) (keyboard-locks kb))]
               [(not press) (event sym "" #f (keyboard-mods kb) (keyboard-locks kb))]
               [else
                (let* ([cs (keyboard-compose-state kb)]
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
                       (event csym (if (> n 0) (cstring->string compose-buf) "") #t
                              (keyboard-mods kb) (keyboard-locks kb)))]
                    [else
                     (let ([cp (xkb_state_key_get_utf32 st code)])
                       (event sym
                              (if (and (> cp 0) (not (<= #xD800 cp #xDFFF)) (< cp #x110000))
                                  (string (integer->char cp))
                                  "")
                              #f (keyboard-mods kb) (keyboard-locks kb)))]))])))))

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
    (XK-F1 "F1") (XK-F35 "F35") (XK-Menu "Menu")
    (XK-KP-Space "KP_Space")
    (XK-Shift-L "Shift_L") (XK-Shift-R "Shift_R") (XK-Control-L "Control_L")
    (XK-Control-R "Control_R") (XK-Alt-L "Alt_L") (XK-Alt-R "Alt_R")
    (XK-Super-L "Super_L") (XK-Super-R "Super_R")
    (XK-Caps-Lock "Caps_Lock") (XK-Num-Lock "Num_Lock"))

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

  ;; Bytes (as a string) to send for key event EV given the terminal modes and
  ;; the kitty keyboard protocol FLAGS, or #f when the event sends nothing.
  ;; With flags 0 this is the legacy encoding, which reports no releases.
  (define encode-key
    (case-lambda
      [(ev app-cursor app-keypad newline-mode)
       (encode-key ev app-cursor app-keypad newline-mode 0)]
      [(ev app-cursor app-keypad newline-mode flags)
       (cond
         [(not (= flags 0)) (encode-kitty-key ev flags app-cursor)]
         [(= (key-event-type ev) KEY-RELEASE) #f]
         [else (encode-legacy-key ev app-cursor app-keypad newline-mode)])]))

  (define (encode-legacy-key ev app-cursor app-keypad newline-mode)
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

  ;;; Kitty keyboard protocol ----------------------------------------------------
  ;;; sw.kovidgoyal.net/kitty/keyboard-protocol, following kitty's encoder
  ;;; (kitty/key_encoding.c) where the specification leaves details open.

  ;; Keys without text: keysym name, number and final character.  The
  ;; numbers above 57343 are the private use code points of the specification.
  (define functional-key-list
    (append
     '(("Escape" 27 #\u) ("Return" 13 #\u) ("Tab" 9 #\u) ("ISO_Left_Tab" 9 #\u)
       ("BackSpace" 127 #\u) ("Insert" 2 #\~) ("Delete" 3 #\~)
       ("Left" 1 #\D) ("Right" 1 #\C) ("Up" 1 #\A) ("Down" 1 #\B)
       ("Prior" 5 #\~) ("Next" 6 #\~) ("Home" 1 #\H) ("End" 1 #\F)
       ("Caps_Lock" 57358 #\u) ("Scroll_Lock" 57359 #\u) ("Num_Lock" 57360 #\u)
       ("Print" 57361 #\u) ("Pause" 57362 #\u) ("Menu" 57363 #\u)
       ("F1" 1 #\P) ("F2" 1 #\Q) ("F3" 13 #\~) ("F4" 1 #\S) ("F5" 15 #\~) ("F6" 17 #\~)
       ("F7" 18 #\~) ("F8" 19 #\~) ("F9" 20 #\~) ("F10" 21 #\~) ("F11" 23 #\~) ("F12" 24 #\~))
     (let loop ([i 13] [acc '()])                ; F13-F35: 57376-57398
       (if (> i 35) (reverse acc)
           (loop (+ i 1) (cons (list (format "F~a" i) (+ 57376 (- i 13)) #\u) acc))))
     (let loop ([i 0] [acc '()])                 ; KP_0-KP_9: 57399-57408
       (if (> i 9) (reverse acc)
           (loop (+ i 1) (cons (list (format "KP_~a" i) (+ 57399 i) #\u) acc))))
     '(("KP_Decimal" 57409 #\u) ("KP_Divide" 57410 #\u) ("KP_Multiply" 57411 #\u)
       ("KP_Subtract" 57412 #\u) ("KP_Add" 57413 #\u) ("KP_Enter" 57414 #\u)
       ("KP_Equal" 57415 #\u) ("KP_Separator" 57416 #\u) ("KP_Left" 57417 #\u)
       ("KP_Right" 57418 #\u) ("KP_Up" 57419 #\u) ("KP_Down" 57420 #\u)
       ("KP_Prior" 57421 #\u) ("KP_Next" 57422 #\u) ("KP_Home" 57423 #\u)
       ("KP_End" 57424 #\u) ("KP_Insert" 57425 #\u) ("KP_Delete" 57426 #\u)
       ("KP_Begin" 1 #\E)
       ("XF86AudioPlay" 57428 #\u) ("XF86AudioPause" 57429 #\u) ("XF86AudioStop" 57432 #\u)
       ("XF86AudioForward" 57433 #\u) ("XF86AudioRewind" 57434 #\u)
       ("XF86AudioNext" 57435 #\u) ("XF86AudioPrev" 57436 #\u) ("XF86AudioRecord" 57437 #\u)
       ("XF86AudioLowerVolume" 57438 #\u) ("XF86AudioRaiseVolume" 57439 #\u)
       ("XF86AudioMute" 57440 #\u)
       ("Shift_L" 57441 #\u) ("Control_L" 57442 #\u) ("Alt_L" 57443 #\u)
       ("Super_L" 57444 #\u) ("Hyper_L" 57445 #\u) ("Meta_L" 57446 #\u)
       ("Shift_R" 57447 #\u) ("Control_R" 57448 #\u) ("Alt_R" 57449 #\u)
       ("Super_R" 57450 #\u) ("Hyper_R" 57451 #\u) ("Meta_R" 57452 #\u)
       ("ISO_Level3_Shift" 57453 #\u) ("ISO_Level5_Shift" 57454 #\u))))

  ;; keysym -> (number . final)
  (define functional-keys
    (let ([h (make-eqv-hashtable)])
      (for-each (lambda (e) (hashtable-set! h (keysym-by-name (car e)) (cons (cadr e) (caddr e))))
                functional-key-list)
      h))

  ;; Keypad keys that stand for other keys unless keypad keys are
  ;; disambiguated: keypad keysym -> keysym (given as a name or, for ASCII
  ;; characters, as the code point).
  (define keypad-equivalents
    (let ([h (make-eqv-hashtable)])
      (for-each (lambda (e) (hashtable-set! h (keysym-by-name (car e))
                                            (if (string? (cdr e)) (keysym-by-name (cdr e)) (cdr e))))
                (append
                 '(("KP_Enter" . "Return") ("KP_Home" . "Home") ("KP_End" . "End")
                   ("KP_Insert" . "Insert") ("KP_Delete" . "Delete") ("KP_Prior" . "Prior")
                   ("KP_Next" . "Next") ("KP_Up" . "Up") ("KP_Down" . "Down")
                   ("KP_Left" . "Left") ("KP_Right" . "Right")
                   ("KP_Decimal" . 46) ("KP_Divide" . 47) ("KP_Multiply" . 42)
                   ("KP_Subtract" . 45) ("KP_Add" . 43) ("KP_Equal" . 61))
                 (map (lambda (i) (cons (format "KP_~a" i) (+ 48 i))) (iota 10))))
      h))

  (define modifier-keys
    (map keysym-by-name
         '("Shift_L" "Shift_R" "Control_L" "Control_R" "Alt_L" "Alt_R" "Super_L" "Super_R"
           "Hyper_L" "Hyper_R" "Meta_L" "Meta_R" "Caps_Lock" "Num_Lock"
           "ISO_Level3_Shift" "ISO_Level5_Shift")))

  (define (modifier-key? sym) (and (memv sym modifier-keys) #t))

  (define (key-event-modifier-key? ev) (modifier-key? (key-event-key ev)))

  ;; The keys that keep a legacy encoding with Shift, Alt and Ctrl while keys
  ;; are not disambiguated (the specification's "legacy text keys").
  (define (legacy-text-key? c)
    (or (<= 97 c 122) (<= 48 c 57) (memv c '(96 45 61 91 93 92 59 39 44 46 47 32))))

  ;; The legacy Ctrl mapping of the specification.
  (define (ctrl-mapped c)
    (cond
      [(<= 97 c 122) (- c 96)]
      [(memv c '(32 50 64)) 0]
      [(memv c '(51 91)) 27]
      [(memv c '(52 92)) 28]
      [(memv c '(53 93)) 29]
      [(memv c '(54 94 126)) 30]
      [(memv c '(47 55 95)) 31]
      [(memv c '(56 63)) 127]
      [else c]))

  (define (control-code? c) (or (< c 32) (<= 127 c 159)))

  (define (serialize-kitty key shifted base add-alternates mods type add-type text final)
    (let* ([o (open-output-string)]
           [mods-field (or (not (= mods 0)) add-type)]
           [text-field (> (string-length text) 0)])
      (put-string o "\x1b;[")
      (when (or (not (= key 1)) add-alternates mods-field text-field)
        (put-string o (number->string key)))
      (when add-alternates
        (put-char o #\:)
        (unless (= shifted 0) (put-string o (number->string shifted)))
        (unless (= base 0) (put-char o #\:) (put-string o (number->string base))))
      (when (or mods-field text-field)
        (put-char o #\;)
        (when mods-field
          (put-string o (number->string (+ mods 1)))
          (when add-type (put-char o #\:) (put-string o (number->string type)))))
      (when text-field
        (put-char o #\;)
        (let loop ([i 0])
          (when (< i (string-length text))
            (unless (= i 0) (put-char o #\:))
            (put-string o (number->string (char->integer (string-ref text i))))
            (loop (+ i 1)))))
      (put-char o final)
      (get-output-string o)))

  (define (encode-kitty-key ev flags app-cursor)
    (let* ([disambiguate (logtest flags KBD-DISAMBIGUATE)]
           [event-types (logtest flags KBD-EVENT-TYPES)]
           [alternates (logtest flags KBD-ALTERNATE-KEYS)]
           [all-keys (logtest flags KBD-ALL-KEYS)]
           [embed-text (logtest flags KBD-TEXT)]
           [type (key-event-type ev)]
           [release (= type KEY-RELEASE)]
           [mods (logor (key-event-mods ev) (key-event-locks ev))]
           [key (key-event-key ev)]
           ;; text is only what a key press types by itself or with Shift
           [text (let ([t (key-event-text ev)])
                   (if (and (not release) (> (string-length t) 0)
                            (not (control-code? (char->integer (string-ref t 0))))
                            (or (key-event-composed? ev)
                                (not (logtest (key-event-mods ev)
                                              (logor MOD-ALT MOD-CTRL MOD-SUPER MOD-HYPER MOD-META)))))
                       t ""))])
      (cond
        [(and release (not event-types)) #f]
        [(and (modifier-key? key) (not all-keys)) #f]
        [(key-event-composed? ev)
         ;; text from a compose sequence belongs to no key: key number 0
         (cond
           [(= (string-length text) 0) #f]
           [(and all-keys embed-text)
            (if release #f (serialize-kitty 0 0 0 #f 0 type #f text #\u))]
           [release #f]
           [else text])]
        [(and (not all-keys) (> (string-length text) 0) (not release)) text]
        [else
         ;; (the keysyms of ASCII characters are their code points)
         (let* ([key (if (or disambiguate all-keys)
                         key
                         (or (hashtable-ref keypad-equivalents key #f) key))]
                [fk (hashtable-ref functional-keys key #f)]
                [text (if embed-text text "")])
           (if fk
               (encode-kitty-functional key (car fk) (cdr fk) mods type text flags app-cursor)
               (encode-kitty-text-key ev (xkb_keysym_to_utf32 key) mods type text flags)))])))

  (define (encode-kitty-functional sym number final mods type text flags app-cursor)
    (let* ([disambiguate (logtest flags KBD-DISAMBIGUATE)]
           [event-types (logtest flags KBD-EVENT-TYPES)]
           [all-keys (logtest flags KBD-ALL-KEYS)]
           [legacy (not (or disambiguate event-types all-keys))]
           [release (= type KEY-RELEASE)]
           [alt (logtest mods MOD-ALT)]
           [locks-only (not (logtest mods (lognot (logor MOD-CAPS-LOCK MOD-NUM-LOCK))))]
           ;; Enter, Tab and Backspace keep their legacy bytes unless all keys
           ;; are reported, so that `reset` can still be typed at a shell
           ;; after a program left the protocol enabled; they send no releases.
           [plain (lambda ()
                    (cond
                      [(= sym XK-Return) (if release 'none "\r")]
                      [(= sym XK-BackSpace) (if release 'none "\x7f;")]
                      [(= sym XK-Tab) (if release 'none "\t")]
                      [else #f]))]
           [bytes
            (cond
              [(and app-cursor legacy (= mods 0) (= number 1) (memv final '(#\A #\B #\C #\D #\E #\F #\H)))
               (string #\x1b #\O final)]
              [(= mods 0)
               (cond
                 ;; (kitty also sends this for a release with flag 2)
                 [(and (= sym XK-Escape) (not disambiguate) (not all-keys) (not release)) "\x1b;"]
                 [(and legacy (<= XK-F1 sym (+ XK-F1 3)))
                  (string #\x1b #\O (string-ref "PQRS" (- sym XK-F1)))]
                 [(not all-keys) (plain)]
                 [else #f])]
              [legacy
               (let ([pre (if alt "\x1b;" "")])
                 (cond
                   [(= sym XK-Return) (string-append pre "\r")]
                   [(= sym XK-Escape) (string-append pre "\x1b;")]
                   [(= sym XK-BackSpace) (string-append pre (if (logtest mods MOD-CTRL) "\b" "\x7f;"))]
                   [(= sym XK-Tab)
                    (if (logtest mods MOD-SHIFT)
                        (string-append (if alt "\x1b;\x1b;" "\x1b;") "[Z")
                        (string-append pre "\t"))]
                   [else #f]))]
              [else #f])]
           [bytes (or bytes (and locks-only (not all-keys) (plain)))])
      (cond
        [(eq? bytes 'none) #f]
        [bytes bytes]
        [(and legacy (= sym XK-Menu))                 ; xterm's F16, as kitty
         (serialize-kitty 29 0 0 #f mods type #f text #\~)]
        [else
         (serialize-kitty number 0 0 #f mods type (and event-types (not (= type KEY-PRESS)))
                          text final)])))

  (define (encode-kitty-text-key ev key mods type text flags)
    (let* ([disambiguate (logtest flags KBD-DISAMBIGUATE)]
           [event-types (logtest flags KBD-EVENT-TYPES)]
           [alternates (logtest flags KBD-ALTERNATE-KEYS)]
           [all-keys (logtest flags KBD-ALL-KEYS)]
           [shift (logtest mods MOD-SHIFT)]
           [shifted (if shift (key-event-shifted ev) 0)]
           [base (key-event-base ev)]
           [add-type (and event-types (not (= type KEY-PRESS)))]
           [add-alternates (and alternates (or (> shifted 0) (> base 0)))]
           [simple (not (or add-type add-alternates (> (string-length text) 0)))])
      (cond
        [(= key 0) #f]
        [(and simple (= mods 0))
         (if all-keys
             (serialize-kitty key 0 0 #f 0 type #f "" #\u)
             (string (integer->char key)))]
        [(and simple (not disambiguate) (not all-keys)
              (or (legacy-text-bytes key (key-event-shifted ev) mods)
                  ;; e.g. Ctrl+С on a Cyrillic layout sends Ctrl+C's byte
                  (and (memv mods (list MOD-CTRL MOD-ALT (logor MOD-CTRL MOD-ALT)))
                       (> base 0) (not (legacy-text-key? key))
                       (legacy-text-bytes base 0 mods))))
         => values]
        [else (serialize-kitty key shifted base add-alternates mods type add-type text #\u)])))

  ;; Legacy bytes for a legacy text key with Shift, Alt, Ctrl, Shift+Alt or
  ;; Ctrl+Alt, or #f.
  (define (legacy-text-bytes key shifted mods)
    (and (legacy-text-key? key)
         (let ([up (if (> shifted 0) shifted key)])
           (cond
             [(= mods MOD-SHIFT) (string (integer->char up))]
             [(= mods MOD-ALT) (string #\x1b (integer->char key))]
             [(= mods (logor MOD-SHIFT MOD-ALT)) (string #\x1b (integer->char up))]
             [(= mods MOD-CTRL) (string (integer->char (ctrl-mapped key)))]
             [(= mods (logor MOD-CTRL MOD-ALT)) (string #\x1b (integer->char (ctrl-mapped key)))]
             [(and (= key 32) (= mods (logor MOD-CTRL MOD-SHIFT))) (string #\nul)]
             [else #f]))))

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
