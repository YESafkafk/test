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
    OSC 8 hyperlinks, OSC 52 clipboard (reading it needs `clipboard-read`),
    OSC 133 shell integration marks
  - device status/attributes (`DSR`, `CPR`, `DA1`, `DA2`, `XTVERSION`), `DECRQM`,
    `DECRQSS`, window size reports, title stack
- **Scrollback** (configurable size), which stays in place while new output
  arrives. Lines reflow when the window is resized.
- **Selection** with the mouse: character, word (double click), line (triple click)
  and block (Ctrl+drag) selection, extending with right click, and autoscroll while dragging.
- **Clipboard** (`wl_data_device`) and **primary selection**
  (`zwp_primary_selection_v1`): copy on select, middle-click paste, Ctrl+Shift+C/V.
- **Jumping between prompts** (Ctrl+Shift+Z / Ctrl+Shift+X) that the shell
  marks with OSC 133, as in kitty and foot, and **selecting or copying a
  command's output** (`select-last-command-output`,
  `copy-last-command-output` and the same for the first command output on
  screen, not bound), as kitty's `copy_last_command_output`; see
  [Shell integration](#shell-integration).
- **Search** through the scrollback (Ctrl+Shift+F / Ctrl+Shift+B), with all
  matches highlighted.
- **Ctrl+click on links and URLs** opens them with the `open-command`
  (`xdg-open` by default): OSC 8 hyperlinks first, then URLs found in the
  text. Only `http`, `https`, `ftp`, `file` and `mailto` URIs are opened,
  since an OSC 8 link's URI comes from the program. As in kitty, a
  `file://` URI is only opened when its host is empty, `localhost` or this
  machine's name, and is passed on without the host (`file:///path`).
  Holding Ctrl over a link or a URL underlines all of it, also where it
  continues on another row, and shows a hand.
- **Keyboard hints**, as in Alacritty: Ctrl+Shift+O labels every link and
  URL on screen (also scrolled back) with a short key sequence, and typing
  one opens it; Ctrl+Shift+Y copies it instead, `hint-paste` pastes it
  into the program and `hint-select` selects its text. Typed keys narrow
  the labels down, Backspace takes one back, Escape leaves. Nothing typed
  in hint mode reaches the program.
- **Fonts** through fontconfig and FreeType: bold/italic faces, or synthesized
  ones when the family has none, per-character fallback fonts, color emoji
  (CBDT bitmaps scaled to the cell), runtime font size changes.
- Pixel-exact built-in **box drawing, block elements and powerline glyphs**.
- **HiDPI**: integer output scaling (`wl_output.scale` and `preferred_buffer_scale`).
- **Background opacity** (premultiplied ARGB buffers).
- Server-side decorations through `xdg-decoration` when the compositor offers them.
- `wp_cursor_shape_v1` pointer cursors, with an XCursor theme fallback.
  `(mouse-hide-when-typing #t)` hides the pointer while typing, as
  Alacritty's `mouse.hide_when_typing`: when a key is sent to the program,
  on a paste and in the search prompt, until the pointer moves, a button is
  pressed or the wheel turns.
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
- Spawning a new instance in the current working directory (Ctrl+Shift+N):
  the one a program reported with OSC 7 when its host is empty, `localhost`
  or this machine's name (compared exactly, as for `file://` links), as in
  foot, or else the shell's.
- A visual bell on BEL, as in Alacritty: `(bell-duration 150)` flashes the
  window in the `bell` color (white by default), fading out over that many
  milliseconds. Independently, an optional `bell-command` is run, and
  `(bell-urgent #t)` marks the window as urgent while it is not focused,
  as foot's `bell.urgent` does (see [Bell](#bell)).
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
never sent, and neither are their releases. As in kitty, a release is only
sent when the key's press was: keys pressed while the window was unfocused,
or held when the focus left, get no release.

`(kitty-keyboard-legacy-csi-u #t)` sends keys that have no legacy encoding,
and so send nothing by default, the way kitty does even while a program has
not asked for the protocol: media keys, Print, Pause, Scroll Lock and
F21–F35 as `CSI u` (e.g. `CSI 57428 u` for Play), and Menu as `CSI 29 ~`.
Every other key is encoded exactly as before.

### Clipboard access (OSC 52)

Programs can always set the clipboard with OSC 52. Reading it (`OSC 52 ;
c ; ? ST`) is off by default, because anything running in the terminal,
also on a remote host, could then read what was copied elsewhere.
`(clipboard-read allow)` answers queries with the clipboard's text, base64
encoded, read like a paste; `p` and `s` ask for the primary selection, as
in foot and Alacritty. The reply ends with the query's terminator (BEL or
ST), as in foot and Alacritty. With `deny` (the default), or when there is
no text, the reply is empty (`OSC 52 ; c ; ST`), as kitty answers a read it
does not allow, so that programs do not wait for a reply that never comes.

### Bell

On BEL, each of these happens if it is configured, independently of the
others:
- `bell-duration`: the visual bell, as in Alacritty.
- `bell-command`: a program is run, at most every 100 ms.
- `bell-urgent`: while the window is not focused, it is marked as urgent,
  as foot's `bell.urgent` does. chezterm asks for an `xdg-activation-v1`
  token for its window and activates the window with it; the compositor
  decides what that means. sway, for one, marks the window as urgent
  (with its default `focus_on_window_activation urgent`) until it is
  focused. As in foot, a program can turn this off with `CSI ? 1042 l` and
  back on with `CSI ? 1042 h`; it is on by default and after a reset, and
  never enables urgency by itself. Without `xdg-activation-v1` in the
  compositor, nothing happens: chezterm does not paint the margins red
  instead, as foot does.

### Keyboard hints

`hint-open` (Ctrl+Shift+O), `hint-copy` (Ctrl+Shift+Y), `hint-paste` and
`hint-select` (not bound) label every target on screen: each OSC 8 link
once, however many runs or rows it takes, and every URL found in the
text, also where it wraps onto the next row. Typing a label runs the
action on its target's URI: for a URL found in the text, that is its
text, and for an OSC 8 link, the link's URI.
- `hint-open` labels only what Ctrl+click would open, and runs the
  `open-command` with the URI appended as the last argument, as
  Alacritty's hint `command` does. Ctrl+click uses the same command:

  ```scheme
  (open-command "firefox" "--new-window")   ; default: (open-command "xdg-open")
  ```
- `hint-copy` copies the URI to the clipboard.
- `hint-paste` writes the URI to the program as if it had been pasted, as
  Alacritty's `Paste` action does, so bracketed paste applies.
- `hint-select` selects the target's text.

Labels are made of `hint-alphabet`'s characters, as in Alacritty,
and no label is a prefix of another: the shortest ones go to the targets
nearest the bottom of the screen. The keys typed so far are drawn in
`hint-typed-foreground`/`hint-typed-background`, the rest in
`hint-foreground`/`hint-background`, and labels that no longer match
disappear. Labels are always shown whole: a label longer than its target
(a two-key label on a one-cell link, say) that runs into the next label
pushes that label to the right, as kitty's hints kitten does. Since no
label is a prefix of another, labels that touch still read unambiguously.

As in Alacritty, the labels follow the screen while hint mode is on: when
output arrives or the view scrolls, the targets are found again and
labelled anew, keeping the keys typed. Hint mode ends on Escape (or
Ctrl+C), when a label is complete, when no target is left, and when the
window is resized. While it is on, key bindings are off and no key reaches
the program, not even as a release; search cannot start, and hint mode
cannot start during a search.

### Shell integration

A shell can mark where its prompts start with OSC 133, as kitty and foot
understand it: `OSC 133 ; A ST` before the prompt, `C` where the command's
output starts and `D` when the command has ended (`B`, the end of the
prompt, is ignored, as in kitty and foot). Marks stay with their lines in
the scrollback, also when lines are reflowed. `scroll-to-previous-prompt`
(Ctrl+Shift+Z) and `scroll-to-next-prompt` (Ctrl+Shift+X), kitty's and
foot's default keys, put the previous or next prompt at the top of the
window; the prompt already at the top is skipped, and so are secondary
prompts (`A` with `k=s`, as in kitty). In bash, for example:

```sh
PS1='\[\e]133;A\e\\\]'$PS1
PS0='\e]133;C\e\\'
```

A command's output starts where its `C` was sent and ends where the next
`A`, `C` or `D` was: marks keep their columns, as foot's do, so output
that does not end in a newline ends where the next prompt starts on the
same line. `D` is not needed, as in kitty, but when a shell sends it,
nothing printed between it and the next prompt is output. Commands
without output are skipped, and trailing blank lines are left out.
- `select-last-command-output` selects the last command's output (the
  command whose `C` is the last one at or above the cursor), and
  `copy-last-command-output` copies it to the clipboard, as kitty's
  `copy_last_command_output`. A command that is still running has its
  output so far. When the command's `C` was dropped from the history,
  what is left of its output at the top of the history is taken, as in
  kitty.
- `select-first-command-output-on-screen` and
  `copy-first-command-output-on-screen` do the same for the first command
  whose output starts in the view, as kitty's
  `show_first_command_output_on_screen`: after Ctrl+Shift+Z, the command
  below the prompt at the top.

A selection made this way goes to the primary selection with
`copy-on-select`, as one made with the mouse. None of them is bound by
default, as in kitty and foot (kitty's Ctrl+Shift+G shows the last
command's output in a pager, which chezterm does not have). For example:

```scheme
(bind "ctrl+shift+g" copy-last-command-output)
```

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
| Ctrl+Shift+Z / Ctrl+Shift+X | scroll to the previous / next prompt (OSC 133) |
| Ctrl+Shift+F / Ctrl+Shift+B | search forward / backward (Enter: next, Shift+Enter: previous, Esc: exit) |
| Ctrl+Shift+O | open a link or URL with keyboard hints (`hint-open`) |
| Ctrl+Shift+Y | copy a link's or URL's URI with keyboard hints (`hint-copy`) |
| (not bound) | paste a link's or URL's URI into the program with keyboard hints (`hint-paste`) |
| (not bound) | select a link's or URL's text with keyboard hints (`hint-select`) |
| (not bound) | select / copy the last command's output (`select-last-command-output`, `copy-last-command-output`) |
| (not bound) | select / copy the first command output on screen (`select-first-command-output-on-screen`, `copy-first-command-output-on-screen`) |
| Ctrl+Shift+K | clear the scrollback |
| Ctrl+Shift+N | open a new window in the current directory |
| F11 | toggle fullscreen |

Mouse: drag to select, double/triple click for words/lines, Ctrl+drag for a block,
right click to extend. Hold Shift to select while an application uses the mouse.
Ctrl+click opens links and URLs with the `open-command`.

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
| `window.ss` | globals, xdg-shell window, shm buffers, seat input, clipboard, cursors, urgency |
| `terminal.ss` | escape sequence parser and terminal state |
| `grid.ss` | cell storage, scrollback ring, reflow |
| `charwidth.ss` | character widths |
| `font.ss`, `boxdraw.ss` | fontconfig/FreeType glyphs, built-in box drawing |
| `render.ss` | incremental software renderer (pixman) |
| `keyboard.ss` | xkbcommon keymaps, compose, key encoding |
| `selection.ss` | selection text, word/line bounds, search matches, links and URLs (hint targets), prompts and command output |
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
