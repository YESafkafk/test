# chezterm

A Wayland-native terminal emulator written in [Chez Scheme](https://cisco.github.io/ChezScheme/),
inspired by [Alacritty](https://alacritty.org/). It talks to the compositor
directly through libwayland; there is no X11 support.

All C bindings (libc, libwayland-client, libwayland-cursor, xkbcommon,
FreeType, fontconfig) are generated with [c2ffi](https://github.com/rpav/c2ffi):
c2ffi turns the C headers into JSON, and a Scheme generator turns the JSON into a Chez
`foreign-procedure` / `define-ftype` library.

## Features

- **Terminal emulation**: VT100/xterm-compatible escape sequence parser (DEC ANSI
  state machine, UTF-8). Supported:
  - cursor movement, erase, insert/delete of characters and lines, scroll regions, tab stops, `REP`
  - SGR with 16, 256 and 24-bit colors, bold, dim, italic, reverse, hidden, strikethrough,
    and underline styles (single, double, curly, dotted, dashed; `4:x`)
  - alternate screen (`47`/`1047`/`1049`), `DECSC`/`DECRC`, origin mode, autowrap, insert mode
  - DEC special graphics (line drawing) charset
  - wide (CJK, emoji) and combining characters
  - bracketed paste, focus reporting, synchronized output (`?2026`)
  - mouse reporting: X10, normal, button-event and any-event tracking, SGR and UTF-8
    encodings, alternate scroll
  - cursor shapes and blinking (`DECSCUSR`)
  - OSC 0/2 title, OSC 4/10/11/12 color set/query/reset, OSC 7 working directory,
    OSC 52 clipboard (write only)
  - device status/attributes (`DSR`, `CPR`, `DA1`, `DA2`, `XTVERSION`), `DECRQM`,
    `DECRQSS`, window size reports, title stack
- **Scrollback** (configurable size), which stays in place while new output
  arrives. Lines reflow when the window is resized.
- **Selection** with the mouse: character, word (double click), line (triple click)
  and block (Ctrl+drag) selection, extending with right click, and autoscroll while dragging.
- **Clipboard** (`wl_data_device`) and **primary selection**
  (`zwp_primary_selection_v1`): copy on select, middle-click paste, Ctrl+Shift+C/V.
- **Search** through the scrollback (Ctrl+Shift+F / Ctrl+Shift+B), with all
  matches highlighted.
- **Ctrl+click on URLs** opens them with `xdg-open`.
- **Fonts** through fontconfig and FreeType: bold/italic faces, or synthesized
  ones when the family has none, per-character fallback fonts, color emoji
  (CBDT bitmaps scaled to the cell), runtime font size changes.
- Pixel-exact built-in **box drawing, block elements and powerline glyphs**.
- **HiDPI**: integer output scaling (`wl_output.scale` and `preferred_buffer_scale`).
- **Background opacity** (premultiplied ARGB buffers).
- Server-side decorations through `xdg-decoration` when the compositor offers them.
- `wp_cursor_shape_v1` pointer cursors, with an XCursor theme fallback.
- Keyboard handling through xkbcommon, including compose/dead keys, key repeat,
  application cursor/keypad modes and xterm-style modifier encoding.
- Configurable key bindings, colors, padding, cursor and more.
- Spawning a new instance in the current working directory (Ctrl+Shift+N).
- Incremental software rendering into shared-memory buffers: only changed
  rows are redrawn, scrolling moves pixels instead of redrawing, and only
  changed regions are reported to the compositor. Rendering is paced by frame
  callbacks.

## Requirements

- Chez Scheme 9.5 or newer (`scheme`)
- libwayland-client, libwayland-cursor, libxkbcommon, FreeType, fontconfig
  (runtime libraries)
- A Wayland compositor
- To regenerate the bindings: c2ffi (LLVM/Clang based) and the development
  headers of the libraries above

On Debian/Ubuntu:

```sh
apt install chezscheme libwayland-client0 libwayland-cursor0 libxkbcommon0 \
            libfreetype6 libfontconfig1 fonts-dejavu-core
# to regenerate bindings as well:
apt install libwayland-dev libxkbcommon-dev libfreetype-dev libfontconfig-dev
```

## Building and running

```sh
make            # compiles everything into build/, creates build/chezterm
build/chezterm
make install    # PREFIX=/usr/local by default
make test       # headless test suite (terminal, selection, keys, renderer)
```

```
Usage: chezterm [options] [-e command [args...]]

  -e, --command CMD ARGS...  run CMD instead of the shell
  -T, --title TITLE          window title
      --class APP_ID         Wayland app-id
  -d, --working-directory D  start in directory D
      --config-file FILE     configuration file to use
      --hold                 keep the window open after the command exits
  -o, --option KEY=VALUE     override a configuration option
```

## Configuration

`$XDG_CONFIG_HOME/chezterm/chezterm.scm` (usually `~/.config/chezterm/chezterm.scm`)
holds S-expressions of the form `(option value ...)`.
[`chezterm.scm.example`](chezterm.scm.example) lists every option with its
default, and all actions that can be bound to keys.

```scheme
(font-family "JetBrains Mono")
(font-size 12)
(padding 6 6)
(opacity 0.95)
(colors (background "#1d1f21") (foreground "#c5c8c6"))
(bind "ctrl+shift+t" spawn-new-instance)
```

### Default key bindings

| Keys | Action |
| --- | --- |
| Ctrl+Shift+C, Ctrl+Insert | copy the selection |
| Ctrl+Shift+V | paste the clipboard |
| Shift+Insert, middle click | paste the primary selection |
| Ctrl+= / Ctrl++ / Ctrl+- / Ctrl+0 | change / reset the font size |
| Shift+PageUp / Shift+PageDown | scroll by a page |
| Shift+Home / Shift+End | scroll to the top / bottom |
| Ctrl+Shift+Up / Ctrl+Shift+Down | scroll by a line |
| Ctrl+Shift+F / Ctrl+Shift+B | search forward / backward (Enter: next, Shift+Enter: previous, Esc: exit) |
| Ctrl+Shift+K | clear the scrollback |
| Ctrl+Shift+N | open a new window in the current directory |
| F11 | toggle fullscreen |

Mouse: drag to select, double/triple click for words/lines, Ctrl+drag for a block,
right click to extend. Hold Shift to select while an application uses the mouse.
Ctrl+click opens URLs.

## How it is built

```
ffi/bindings.h ──c2ffi──▶ build/decls.json ─┐
        └──c2ffi -M──▶ macros.h ─filter─▶ consts.h ──c2ffi──▶ consts.json ─┤
ffi/spec.ss (what to bind) ────────────────────────────────────────────────┴─▶ tools/c2ffi-gen.ss ─▶ src/chezterm/ffi.ss

protocols/*.xml ──tools/wl-scanner.ss──▶ src/chezterm/protocols.ss
```

- `ffi/bindings.h`: the C headers to bind.
- `ffi/spec.ss`: which functions, structs, enums and macros to bind, plus
  per-parameter type overrides (e.g. `u8*` so bytevectors can be passed without copying).
- `tools/c2ffi-gen.ss`: reads c2ffi's JSON (with its own JSON reader,
  `tools/json.ss`), resolves typedefs, lays out structs and unions as Chez
  ftypes, and emits `foreign-procedure` definitions and constants. c2ffi's
  `-M` mode turns preprocessor macros into constants that a second c2ffi pass
  evaluates. String macros such as `FC_FAMILY` are read back from their
  `#define`.
- `tools/wl-scanner.ss`: a Scheme replacement for `wayland-scanner`. The C
  protocol stubs are `static inline` and cannot be called through an FFI, so
  the generator emits interface descriptors and request procedures.
  `src/chezterm/wayland.ss` turns the descriptors into real `struct wl_interface`s,
  marshals requests with `wl_proxy_marshal_array_flags`, and dispatches all
  events through one `wl_proxy_add_dispatcher` callback, which decodes the
  `wl_argument` array.

The generated `src/chezterm/ffi.ss` and `src/chezterm/protocols.ss` are
committed, so building needs neither c2ffi nor wayland-scanner.
`make bindings` and `make protocols` regenerate them.

Source layout (`src/chezterm/`):

| Module | Purpose |
| --- | --- |
| `ffi.ss`, `protocols.ss` | generated bindings |
| `wayland.ss` | Wayland client runtime (interfaces, marshalling, dispatch) |
| `window.ss` | globals, xdg-shell window, shm buffers, seat input, clipboard, cursors |
| `terminal.ss` | escape sequence parser and terminal state |
| `grid.ss` | cell storage, scrollback ring, reflow |
| `charwidth.ss` | character widths |
| `font.ss`, `boxdraw.ss` | fontconfig/FreeType glyphs, built-in box drawing |
| `render.ss` | incremental software renderer |
| `keyboard.ss` | xkbcommon keymaps, compose, key encoding |
| `selection.ss` | selection text, word/line bounds, search matches, URLs |
| `pty.ss` | pseudo-terminal and process spawning |
| `config.ss` | configuration |
| `app.ss` | event loop and glue |

The escape sequence parser, grid and renderer are compiled with Chez's
`optimize-level 3`. On a pty they process output as fast as the pty delivers it
(`seq 1 2000000` takes about 1 s, the same as `script` writing to `/dev/null`).

## Limitations

- Rendering is done on the CPU into `wl_shm` buffers, not with OpenGL like Alacritty.
- No client-side decorations: without `xdg-decoration` (e.g. on GNOME) the
  window has no title bar.
- Fractional scaling is rounded to the next integer scale.
- No Alacritty vi mode, hints UI, IME (`text-input-v3`), kitty keyboard
  protocol or live config reload.
- `TERM` defaults to `xterm-256color`; no custom terminfo entry is shipped.
