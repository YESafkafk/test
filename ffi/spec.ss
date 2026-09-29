;;; Binding specification consumed by tools/c2ffi-gen.ss.
;;;
;;; c2ffi parses ffi/bindings.h and emits a JSON description of every
;;; declaration; the generator picks the items listed here and turns them
;;; into the Chez Scheme library (chezterm ffi) in src/chezterm/ffi.ss.

(library-name (chezterm ffi))

(shared-objects
  "libc.so.6"
  "libwayland-client.so.0"
  "libwayland-cursor.so.0"
  "libxkbcommon.so.0"
  "libfreetype.so.6"
  "libfontconfig.so.1")

;; Functions to bind.  An entry is either a symbol, or
;; (name (param-name type) ...) to override the Scheme foreign type of
;; individual parameters, e.g. to pass bytevectors directly with u8*.
;; By default `char *` parameters are passed as utf-8 strings and all other
;; pointers as uptr.  Variadic functions need (&rest type ...) giving the
;; types of the extra arguments they are called with.
(functions
  ;; libc
  malloc calloc free memcpy memmove memset (strlen (__s uptr)) getenv setenv unsetenv
  setlocale wcwidth __errno_location strerror
  (read (__buf u8*)) (write (__buf u8*))
  close pipe2 (fcntl (&rest int)) poll (ioctl (&rest uptr)) dup2
  mmap munmap ftruncate memfd_create
  fork setsid (forkpty (__name uptr)) (execvp (__file uptr)) _exit waitpid kill getpid
  (chdir (__path uptr)) (readlink (__buf uptr))
  timerfd_create timerfd_settime inotify_init1 inotify_add_watch
  sigemptyset sigprocmask signal

  ;; wayland-client core
  wl_display_connect wl_display_disconnect wl_display_get_fd
  wl_display_dispatch wl_display_dispatch_pending wl_display_flush
  wl_display_roundtrip wl_display_prepare_read wl_display_read_events
  wl_display_cancel_read wl_display_get_error
  wl_proxy_marshal_array_flags wl_proxy_add_dispatcher wl_proxy_get_id
  wl_proxy_get_version wl_proxy_destroy wl_proxy_get_class

  ;; wayland-cursor
  wl_cursor_theme_load wl_cursor_theme_destroy wl_cursor_theme_get_cursor
  wl_cursor_image_get_buffer

  ;; xkbcommon
  xkb_context_new xkb_context_unref
  (xkb_keymap_new_from_string (string uptr)) xkb_keymap_unref xkb_keymap_key_repeats
  xkb_keymap_mod_get_index
  xkb_state_new xkb_state_unref xkb_state_update_mask
  xkb_state_key_get_one_sym xkb_state_key_get_utf32 xkb_state_mod_index_is_active
  xkb_keysym_to_utf32 xkb_keysym_to_lower xkb_keysym_from_name xkb_keysym_get_name
  xkb_compose_table_new_from_locale xkb_compose_table_unref
  xkb_compose_state_new xkb_compose_state_unref xkb_compose_state_feed
  xkb_compose_state_reset xkb_compose_state_get_status
  xkb_compose_state_get_one_sym (xkb_compose_state_get_utf8 (buffer uptr))

  ;; freetype
  FT_Init_FreeType FT_Done_FreeType FT_New_Face FT_Done_Face
  FT_Set_Pixel_Sizes FT_Select_Size FT_Get_Char_Index FT_Load_Glyph
  FT_Render_Glyph FT_Library_SetLcdFilter FT_Set_Transform
  FT_GlyphSlot_Embolden FT_GlyphSlot_Oblique

  ;; fontconfig
  FcInitLoadConfigAndFonts FcConfigDestroy FcConfigSubstitute
  FcDefaultSubstitute FcFontMatch FcNameParse FcPatternCreate
  FcPatternDestroy FcPatternDuplicate FcPatternAddString FcPatternAddInteger
  FcPatternAddDouble FcPatternAddBool FcPatternAddCharSet FcPatternDel
  FcPatternGetString FcPatternGetInteger FcPatternGetDouble FcPatternGetBool
  FcCharSetCreate FcCharSetAddChar FcCharSetDestroy FcCharSetHasChar
  FcPatternGetCharSet)

;; Structs (and everything reachable from them) to describe as ftypes.
(structs
  FT_FaceRec_ FT_GlyphSlotRec_ FT_SizeRec_ FT_Bitmap_ FT_Matrix_ FT_Vector_
  wl_interface wl_message wl_array wl_cursor wl_cursor_image
  pollfd winsize itimerspec timespec)

(unions wl_argument)

;; Enumerations: every enumerator whose name starts with one of these.
(enum-prefixes
  "FT_PIXEL_MODE_" "FT_RENDER_MODE_" "FT_LCD_FILTER_" "FT_ENCODING_NONE"
  "XKB_STATE_" "XKB_KEYMAP_FORMAT_" "XKB_CONTEXT_NO_FLAGS" "XKB_KEYMAP_COMPILE_NO_FLAGS"
  "XKB_COMPOSE_" "XKB_KEYSYM_" "FcResult" "FcMatch")

;; Preprocessor constants, evaluated by a second c2ffi pass.
(macros
  ;; libc
  EAGAIN EINTR EIO O_CLOEXEC O_NONBLOCK F_GETFL F_SETFL F_SETFD FD_CLOEXEC
  POLLIN POLLOUT POLLERR POLLHUP POLLNVAL
  PROT_READ PROT_WRITE MAP_SHARED MFD_CLOEXEC MFD_ALLOW_SEALING
  TIOCSWINSZ TIOCGPGRP WNOHANG SIGCHLD SIGHUP SIGPIPE SIGINT SIGTERM
  SIG_SETMASK LC_ALL LC_CTYPE
  CLOCK_MONOTONIC TFD_NONBLOCK TFD_CLOEXEC ENOENT EPIPE
  IN_NONBLOCK IN_CLOEXEC IN_CLOSE_WRITE IN_MOVED_TO IN_CREATE IN_DELETE_SELF
  ;; wayland
  WL_MARSHAL_FLAG_DESTROY
  ;; freetype
  FT_LOAD_DEFAULT FT_LOAD_RENDER FT_LOAD_COLOR FT_LOAD_NO_HINTING
  FT_LOAD_FORCE_AUTOHINT FT_LOAD_TARGET_NORMAL FT_LOAD_TARGET_LIGHT
  FT_LOAD_TARGET_MONO FT_LOAD_TARGET_LCD FT_LOAD_NO_BITMAP FT_FACE_FLAG_SCALABLE
  FT_FACE_FLAG_COLOR FT_FACE_FLAG_FIXED_SIZES
  ;; fontconfig
  FC_FAMILY FC_STYLE FC_FILE FC_INDEX FC_SIZE FC_PIXEL_SIZE FC_WEIGHT FC_SLANT
  FC_SPACING FC_CHARSET FC_DPI FC_ANTIALIAS FC_HINTING FC_HINT_STYLE FC_RGBA
  FC_COLOR FC_SCALABLE FC_WEIGHT_REGULAR FC_WEIGHT_BOLD FC_SLANT_ROMAN
  FC_SLANT_ITALIC FC_MONO FC_RGBA_RGB FC_RGBA_BGR FC_RGBA_NONE FC_RGBA_UNKNOWN
  FcTrue FcFalse)
