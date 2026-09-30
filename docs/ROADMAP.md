# Roadmap

Work that is not done yet, roughly in order of cost. Each item notes where it
would go in the code.

## Small

### OSC 8 hyperlinks (done)

Cells keep a link id in the line's `extra` table, and the terminal maps ids
to URIs. Ctrl+click opens explicit links before URLs found in the text, and
hovering with Ctrl underlines the whole link. What is left: keyboard hints
(below) could label explicit links as well.

### Underline color (SGR 58/59)

This needs a per-cell color. The cheapest place is the line's `extra` table,
because it is rare. `draw-underline!` already takes the color as a parameter.
Once it is drawn, add `Setulc=\E[58:2::%p1%{65536}%/%d:%p1%{256}%/%{255}%&%d:%p1%{255}%&%dm`
to `terminfo/chezterm.terminfo`, and a check for it to `tests/terminfo.ss`.

### Performance findings from the benchmarks

[BENCHMARKS.md](BENCHMARKS.md#what-the-numbers-show) describes these, with
measurements. Clearing lines, per-column removal of combining marks, the
full-frame fill and drawing at 60 Hz during output floods have been fixed.
What is left:
- **Unicode text parses about 2.5× slower than ASCII.** The cost is in
  `print!`, per non-ASCII character, not in UTF-8 decoding. A run-based
  print for non-ASCII text, like `print-ascii-run!`, would batch the width,
  wrap and wide-edge checks.
- **Rendering dense text is bound by pixman.** It copies one tile per cell,
  about 3 ms of a 6 ms 250×75 frame. Fewer copies would need larger cached
  units: whole rows reused when they reappear, or glyph runs composited
  through `pixman_composite_glyphs`, which would need new bindings in
  `ffi/spec.ss`. A GPU backend (below) removes this cost.
- **Scrolling moves the screen's line vector by one on every line feed.** A
  ring-indexed screen would avoid that, but touches every `grid-screen-line`
  user.
- **Filling the scrollback allocates its lines**, and GC copies them while
  they age. That costs about 20% of `parse/ascii`, but only until the
  history is full.

Check each change with `make bench-ab BASE=main`. When the change is in
`bench/run.ss` itself, use each side's own runner (see BENCHMARKS.md).

## Medium

### Fractional scaling

When the compositor offers `wp_fractional_scale_v1` and `wp_viewporter`:

- bind them in `window.ss`
- render at `ceil(logical size × scale / 120)` pixels
- set the viewport destination to the logical size
- keep `buffer_scale` at 1.

The font pixel size already comes from `scale`, which would become a rational.
Pointer coordinates would be scaled by the same factor. The protocol XML
files go into `protocols/` and the Makefile's `PROTOCOLS` list.

### Kitty keyboard protocol (done)

Implemented: all five enhancement flags, the per-screen flags stacks in
`terminal.ss` (emptied by `RIS` and `DECSTR`), the encoder in `keyboard.ss`
(tested against the specification's examples), release/repeat events in
`app.ss`, Hyper and Meta when the keymap puts them on a modifier of their
own (found by walking the keymap, as kitty does), and optionally `CSI u`
for keys without a legacy encoding (`kitty-keyboard-legacy-csi-u`). What is
left:
- **Hyper and Meta on a shared modifier.** Most keymaps put Hyper on Mod4
  with Super and Meta on Mod1 with Alt. Such a Hyper key then reports
  Super, as in kitty: the compositor only sends real modifiers, so the two
  cannot be told apart.
- **Keys pressed while the window was unfocused.** Their release, after the
  focus came back, is reported although the application never saw the
  press. foot does the same, kitty drops such releases. Keys held when the
  focus leaves get no release, as in kitty and foot.
- **Other keys without a legacy encoding.** With flags 0, only keys that
  send nothing at all can be sent as `CSI u`. Keys such as Ctrl+Shift+letter
  or modified F13–F20 keep their legacy bytes, which kitty replaces.

### Keyboard hints (Alacritty's "hints")

A mode that labels every URL or regex match on screen with a short key
sequence, and opens or copies the target when it is typed.
`selection.ss` already finds URLs. The labels can be drawn through the same
overlay mechanism as the search prompt.

### IME (`zwp_text_input_v3`)

This means binding text-input-v3, enabling it on focus, reporting the cursor
rectangle, and drawing the preedit string at the cursor, for example as an
underlined overlay.

## Large

### Client-side decorations

Compositors without `xdg-decoration` (GNOME) show no title bar. A minimal
decoration would be a subsurface above the window with a title, a close button
and move/resize handling via `xdg_toplevel.move`/`resize`. Alternatively,
libdecor could be used through the FFI.

### Vi mode

A keyboard-driven cursor over the grid and scrollback, with motions, visual
selection, search integration and yank. It needs its own cursor state in
`app.ss` and a renderer overlay for that cursor.

### GPU backend

The renderer is already structured for this. Row diffing and scroll detection
decide what changed, and every cell reduces to a background color plus an
optional glyph from a cache. A GPU backend would upload the glyphs to an
atlas texture and draw one instanced quad per cell from a per-cell instance
buffer, updating only the changed rows.

**Vulkan or OpenGL ES?**

- **Vulkan**, via `VK_KHR_wayland_surface`. `vulkan.h` is plain C, so the
  c2ffi pipeline can bind it. Mesa's lavapipe (software Vulkan) runs without a
  GPU, so the backend could be tested in the Nix checks and the VM test by
  comparing its pixels with the software renderer's. The cost is 5–10× the
  setup code of GL: instance, device, swapchain, render pass, pipeline,
  descriptors, synchronisation and swapchain recreation on resize, all through
  the FFI. Shaders need a SPIR-V compile step (glslang), which Nix provides.
- **OpenGL ES 3 via EGL** (`wl_egl_window`) is what Alacritty uses. It needs
  far less code and works everywhere. Mesa's llvmpipe can also test it without
  a GPU.

A terminal's GPU workload is tiny: one textured quad per cell. Vulkan's
advantages, low driver overhead and multithreaded command recording, do not
matter here. The remaining cost is CPU-side: parsing and walking the cells.
Either API works. GL ES is less code, and Vulkan has the nicer testing story.
Whichever is chosen, the shared-memory renderer stays as the fallback for
systems without drivers.

With the pixman renderer, a full redraw of a 2254×1354 window takes about
6 ms, and typical frames touch a few rows. A GPU backend therefore mainly pays
off for 4K and larger windows, and for smooth scrolling.
