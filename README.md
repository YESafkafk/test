# chezterm

A Wayland-native terminal emulator written in [Chez Scheme](https://cisco.github.io/ChezScheme/),
inspired by [Alacritty](https://alacritty.org/). It talks to the compositor
directly through libwayland; there is no X11 support.

All C bindings (libc, libwayland-client, libwayland-cursor, xkbcommon,
FreeType, fontconfig, pixman) are generated with [c2ffi](https://github.com/rpav/c2ffi):
c2ffi turns the C headers into JSON, and a Scheme generator turns the JSON into a Chez
`foreign-procedure` / `define-ftype` library.

## Features

- **Terminal emulation**: VT100/xterm-compatible escape sequence parser (DEC ANSI
  state machine, UTF-8). Supported:
  - cursor movement, erase, insert/delete of characters and lines, scroll regions, tab stops, `REP`
  - SGR with 16, 256 and 24-bit colors, bold, dim, italic, reverse, hidden, strikethrough,
    underline styles (single, double, curly, dotted, dashed; `4:x`) and underline
    colors (`58`/`59`)
  - alternate screen (`47`/`1047`/`1049`), `DECSC`/`DECRC`, origin mode, autowrap, insert mode
  - DEC special graphics (line drawing) charset
  - wide (CJK, emoji) and combining characters
  - bracketed paste, focus reporting, synchronized output (`?2026`)
  - mouse reporting: X10, normal, button-event and any-event tracking, SGR and UTF-8
    encodings, alternate scroll
  - cursor shapes and blinking (`DECSCUSR`)
  - OSC 0/2 title, OSC 4/10/11/12 color set/query/reset, OSC 7 working directory,
    OSC 8 hyperlinks, OSC 52 clipboard (write only)
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
- **Ctrl+click on links and URLs** opens them with `xdg-open`: OSC 8
  hyperlinks first, then URLs found in the text. Only `http`, `https`,
  `ftp`, `file` and `mailto` URIs are opened, since an OSC 8 link's URI comes
  from the program. Holding Ctrl over a link underlines all of it, also
  where it continues on another row.
- **Keyboard hints**, as in Alacritty: Ctrl+Shift+O labels every link and
  URL on screen (also scrolled back) with a short key sequence, and typing
  one opens it; Ctrl+Shift+Y copies it instead, and `hint-select` selects
  its text. Typed keys narrow the labels down, Backspace takes one back,
  Escape leaves. Nothing typed in hint mode reaches the program.
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
- The [kitty keyboard protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/)
  with all five progressive enhancements (disambiguated escape codes, press,
  repeat and release events, shifted and base-layout keys, all keys as escape
  codes, associated text), a flags stack per screen, and the `CSI ? u` query.
  Hyper and Meta are reported when the keymap puts them on a modifier of
  their own. Programs such as Neovim, Helix, kakoune and fish use it to tell
  apart keys like Ctrl+I and Tab. The `kitty-keyboard` option turns it off.
- Configurable key bindings, colors, padding, cursor and more, with **live
  reload**: saving the configuration file applies it immediately (inotify).
- Spawning a new instance in the current working directory (Ctrl+Shift+N).
- Optional `bell-command` run on BEL.
- Its own terminfo entries, `chezterm` and `chezterm-direct` (see
  [Terminfo](#terminfo)), so programs know about underline styles,
  synchronized output, cursor shapes, the clipboard and true color.
- Incremental software rendering into shared-memory buffers, composited with
  [pixman](https://pixman.org/):
  - only changed rows are redrawn, and scrolling moves pixels instead of redrawing
  - backgrounds are filled in runs of equal color
  - text is copied from cached cell tiles (a glyph already blended over its
    background); glyphs that overhang their cell are composited afterwards
  - only the rows a buffer is missing are copied into it, and only changed
    regions are reported to the compositor
  - rendering is paced by frame callbacks, and spaced out while output floods
    in, so that parsing gets most of the time.

## Requirements

- Chez Scheme 9.5 or newer (`scheme`; tested with 9.5.8 and 10.4)
- libwayland-client, libwayland-cursor, libxkbcommon, FreeType, fontconfig,
  pixman (runtime libraries)
- A Wayland compositor
- `tic` from ncurses to compile the terminfo entry (optional; without it
  `TERM` is `xterm-256color`)
- To regenerate the bindings: c2ffi (LLVM/Clang based) and the development
  headers of the libraries above

On Debian/Ubuntu:

```sh
apt install chezscheme libwayland-client0 libwayland-cursor0 libxkbcommon0 \
            libfreetype6 libfontconfig1 libpixman-1-0 fonts-dejavu-core
# to regenerate bindings as well:
apt install libwayland-dev libxkbcommon-dev libfreetype-dev libfontconfig-dev \
            libpixman-1-dev
```

## Building and running

```sh
make            # compiles everything into build/, creates build/chezterm
build/chezterm
make install    # PREFIX=/usr/local by default
make test       # headless test suite (terminal, selection, keys, renderer),
                # run against the sources and against the optimized build,
                # then the terminfo entry checked against the emulator
make check-generated  # regenerate bindings and protocols, diff with the committed files
make bench      # benchmarks: parsing, rendering, pty pipeline (docs/BENCHMARKS.md)
```

Make variables: `SCHEME` (the Chez Scheme executable), `C2FFI` and
`C2FFI_FLAGS` (for `make bindings`), `SHARED_OBJECTS` (see [Nix](#nix)),
`RUNTIME_PATH` (directories the launcher appends to `PATH`) and `TIC`.

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

## Nix

The flake builds, tests and runs chezterm on `x86_64-linux` and `aarch64-linux`:

```sh
nix run . -- --version    # build and run chezterm (apps.default)
nix build                 # package in ./result (packages.default)
nix flake check           # every check below
nix develop               # shell for `make`, `make test`, `make bindings`
nix fmt                   # format the Nix files (treefmt + nixfmt)
nix run .#test            # test suite on the working tree
nix run .#bindings        # regenerate ffi.ss and protocols.ss in the working tree
nix build .#bindings      # the generated files, built with c2ffi from nixpkgs
nix run .#bench           # benchmarks with pinned toolchain and font (docs/BENCHMARKS.md)
nix run .#bench-ab -- -- OLD/bin/chezterm-bench NEW/bin/chezterm-bench   # interleaved A/B
```

Checks (`nix build .#checks.x86_64-linux.NAME`):

| Check | What it does |
| --- | --- |
| `chezterm` | builds the package and runs `chezterm --version` |
| `tests` | `make test` (both passes), with DejaVu fonts through `makeFontsConf` |
| `generated` | regenerating the bindings and protocols gives the committed files, and `make relink` gives the same file as generating with store paths |
| `formatting` | `treefmt --ci` |
| `bench` | runs the benchmarks with `--quick` (a smoke test, not timing) and the compare tool on the result |
| `vm` | NixOS VM with headless sway: starts chezterm, types a command with `wtype`, checks that the shell ran it, takes a `grim` screenshot and a `--dump-frame` image (kept in the output) |

The `vm` check needs KVM (the `kvm` system feature). Without it, skip the
check, or let QEMU emulate the CPU, which is much slower:
`nix build .#checks.x86_64-linux.vm --option system-features "kvm nixos-test"`.

How the package works:

- On NixOS, libraries are not found by soname. The package runs
  `make relink SHARED_OBJECTS="libwayland-client.so.0=/nix/store/.../libwayland-client.so.0 ..."`,
  which rewrites the `load-shared-object` calls in `src/chezterm/ffi.ss`
  to absolute store paths. `make bindings SHARED_OBJECTS=...` generates the same file.
  No `LD_LIBRARY_PATH` wrapper is needed.
- The launcher calls Chez Scheme by its store path (`make SCHEME=...`).
- `xdg-utils` is appended to the launcher's `PATH` (`make RUNTIME_PATH=...`)
  for Ctrl+click on URLs, so a system-wide `xdg-open` still takes precedence.
  Leave it out with `chezterm.override { xdg-utils = null; }`.
- The dev shell, `nix run .#test` and plain `make` use the committed bindings,
  which load libraries by soname, so they set `LD_LIBRARY_PATH`.

The committed `src/chezterm/ffi.ss` is generated with the headers of the
pinned nixpkgs. Other distributions can generate slightly different
output, because header versions differ (for example, `FT_Outline`'s `n_points` is
`short` before FreeType 2.13.3). Such differences do not change the struct layout.

There is no formatter for the Scheme sources. No Chez Scheme formatter keeps
the hand-aligned layout of the code, and the generated files are written by
`pretty-print`.

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

`(kitty-keyboard #f)` disables the kitty keyboard protocol: chezterm then
ignores its control sequences and does not answer `CSI ? u`, so programs keep
to the legacy (xterm) key encoding. Keys that trigger a chezterm binding are
never sent, and neither are their releases.

`(kitty-keyboard-legacy-csi-u #t)` sends keys that have no legacy encoding,
and so send nothing by default, the way kitty does even while a program has
not asked for the protocol: media keys, Print, Pause, Scroll Lock and
F21–F35 as `CSI u` (e.g. `CSI 57428 u` for Play), and Menu as `CSI 29 ~`.
Every other key is encoded exactly as before.

### Keyboard hints

`hint-open` (Ctrl+Shift+O), `hint-copy` (Ctrl+Shift+Y) and `hint-select`
(not bound) label every target on screen: each OSC 8 link once, however
many runs or rows it takes, and every URL found in the text, also where it
wraps onto the next row. `hint-open` labels only what Ctrl+click would
open. Labels are made of `hint-alphabet`'s characters, as in Alacritty,
and no label is a prefix of another: the shortest ones go to the targets
nearest the bottom of the screen. The keys typed so far are drawn in
`hint-typed-foreground`/`hint-typed-background`, the rest in
`hint-foreground`/`hint-background`, and labels that no longer match
disappear.

As in Alacritty, the labels follow the screen while hint mode is on: when
output arrives or the view scrolls, the targets are found again and
labelled anew, keeping the keys typed. Hint mode ends on Escape (or
Ctrl+C), when a label is complete, when no target is left, and when the
window is resized. While it is on, key bindings are off and no key reaches
the program, not even as a release; search cannot start, and hint mode
cannot start during a search.

### Terminfo

[`terminfo/chezterm.terminfo`](terminfo/chezterm.terminfo) defines two
entries:
- `chezterm`: 256 colors, plus `Tc` for 24-bit color
- `chezterm-direct`: `setaf`/`setab` take 24-bit values (ncurses `RGB`).

Beyond the usual xterm capabilities they advertise:
- underline styles and colors (`Smulx`, `Setulc`)
- synchronized output (`Sync`)
- cursor shapes (`Ss`/`Se`) and cursor color (`Cs`/`Cr`)
- the clipboard (`Ms`)
- bracketed paste and focus reporting (`BE`/`BD`, `fe`/`fd`)
- the title as a status line (`hs`, `tsl`/`fsl`)
- strikethrough (`smxx`)
- SGR mouse (`XM`).

The entry is self-contained rather than inheriting from `xterm-256color`, so
it lists only what chezterm implements. `tests/terminfo.ss` expands every
capability with ncurses' `tput`, feeds it to the emulator and checks the
effect. It also checks that each key capability is exactly what chezterm
sends for that key.

`make` compiles the entries into `build/terminfo`, and `make install` puts
them into `$(PREFIX)/share/terminfo`. The launcher tells chezterm where they
are. When the `term` option is not set, chezterm picks `TERM` as follows:
1. `chezterm`, if the entry is installed where ncurses looks by default
   (`~/.terminfo`, `/usr/share/terminfo`, `TERMINFO_DIRS`, the Nix profiles).
2. `chezterm` if it is only in the bundled directory. That directory is then
   added to `TERMINFO_DIRS` for the programs chezterm starts.
3. `xterm-256color` otherwise.

Remote hosts usually lack the entry. Copy it over:

```sh
infocmp -x chezterm | ssh host 'tic -x -'
```

Alternatively, set `(term "xterm-256color")` in the configuration.

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
| Ctrl+Shift+O | open a link or URL with keyboard hints (`hint-open`) |
| Ctrl+Shift+Y | copy a link's or URL's URI with keyboard hints (`hint-copy`) |
| (not bound) | select a link's or URL's text with keyboard hints (`hint-select`) |
| Ctrl+Shift+K | clear the scrollback |
| Ctrl+Shift+N | open a new window in the current directory |
| F11 | toggle fullscreen |

Mouse: drag to select, double/triple click for words/lines, Ctrl+drag for a block,
right click to extend. Hold Shift to select while an application uses the mouse.
Ctrl+click opens links and URLs.

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
| `render.ss` | incremental software renderer (pixman) |
| `keyboard.ss` | xkbcommon keymaps, compose, key encoding |
| `selection.ss` | selection text, word/line bounds, search matches, links and URLs (hint targets) |
| `hints.ss` | keyboard hint labels and key handling |
| `pty.ss` | pseudo-terminal and process spawning |
| `config.ss` | configuration |
| `app.ss` | event loop and glue |

Everything is compiled with Chez's `optimize-level 2`, which keeps run-time
type and bounds checks, so a bug raises an error instead of corrupting
memory. In a 1920×1080 window, `seq 1 2000000` takes about 3.4 s in
chezterm, against 0.9 s for `script` writing to `/dev/null`. Redrawing a
full 250×75 screen of colored text (2254×1354 pixels) takes about 5.6 ms. See
[docs/BENCHMARKS.md](docs/BENCHMARKS.md) for measurements.

## Limitations

- Rendering is done on the CPU into `wl_shm` buffers, not with OpenGL like Alacritty.
- No client-side decorations: without `xdg-decoration` (e.g. on GNOME) the
  window has no title bar.
- Fractional scaling is rounded to the next integer scale.
- No Alacritty vi mode or IME (`text-input-v3`). Keyboard hints find links
  and URLs only; there are no user-defined regex hints.
- The kitty keyboard protocol reports Hyper and Meta only when they have a
  modifier of their own; most keymaps share them with Super and Alt.

[docs/ROADMAP.md](docs/ROADMAP.md) describes how these could be addressed,
including a possible GPU backend.
