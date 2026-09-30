# Roadmap

Work that is not done yet, roughly in order of cost. Each item notes where it
would go in the code.

## Small

### OSC 8 hyperlinks

The parser currently drops OSC 8. Cells would need a hyperlink id, which could
be stored in the line's `extra` table like combining marks. `url-at` in
`selection.ss` would look there first, so Ctrl+click opens explicit links too.
Hovering could underline the whole link.

### Underline color (SGR 58/59)

This needs a per-cell color. The cheapest place is the line's `extra` table,
because it is rare. `draw-underline!` already takes the color as a parameter.
Once it is drawn, add `Setulc=\E[58:2::%p1%{65536}%/%d:%p1%{256}%/%{255}%&%d:%p1%{255}%&%dm`
to `terminfo/chezterm.terminfo`, and a check for it to `tests/terminfo.ss`.

### Performance findings from the benchmarks

[BENCHMARKS.md](BENCHMARKS.md#what-the-numbers-show) describes these, with
measurements:
- since everything is compiled at `optimize-level 2`, parsing is 7–53%
  slower, depending on the workload. The parser's hot loops are the place to
  win that back without dropping the checks.
- Unicode text parses about 2.5× slower than ASCII
- rendering during streaming output halves pipeline throughput at large sizes.

Check each change with `make bench-ab BASE=main`.

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

### Kitty keyboard protocol

This allows progressive enhancement:
- `CSI > flags u` / `CSI < u` push and pop the flags
- `CSI = flags ; mode u` sets them
- `CSI ? u` queries them.

The terminal keeps a flags stack per screen. `encode-key` in `keyboard.ss`
switches to the `CSI keycode ; mods u` encoding when the flags ask for it:
disambiguate first, then report event types, alternate keys and all keys.
The parser must only answer `CSI ? u` once this exists, because apps enable
the protocol based on that reply.

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
