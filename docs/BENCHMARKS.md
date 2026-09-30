# Benchmarks

`bench/` measures chezterm's performance in a way that can be repeated, and
compares two versions without mistaking noise for a change.

```sh
make bench                         # full run, results in build/bench.json
make bench-quick                   # small smoke run
make bench-ab BASE=main            # interleaved comparison with another revision

nix run .#bench -- --out results.json      # pinned toolchain, libraries and font
nix run .#bench-compare -- old.json new.json
```

A full run takes about 1.5 minutes. `--only render,parse/ascii` selects
benchmarks by substring, `--iterations N` sets the number of samples, and
`--list` shows all benchmarks.

## What is measured

| Group | Unit | What one sample is |
| --- | --- | --- |
| `parse/<workload>` | MB/s | feeding an 8 MiB workload to a fresh 200×50 terminal (with 10 000 lines of scrollback), in 64 KiB chunks like pty reads |
| `render/<scenario>-<cols>x<rows>` | ms/frame | the mean of 30 frames of a dense, colored screen |
| `pipeline/<workload>` | MB/s | `cat` of a 16 MiB workload through a real pty into a 250×75 terminal, parsed as it arrives and rendered like the event loop does: at most every 1/60 s, and while the pty has a backlog only after 4× the last frame's drawing time (at most 50 ms) |

The **workloads** (`bench/workloads.ss`):

| Workload | Content |
| --- | --- |
| `ascii` | lines of printable ASCII, scrolling |
| `unicode` | ASCII mixed with accented letters, CJK, emoji, combining marks and box drawing |
| `sgr` | text with frequent SGR changes: 16, 256 and 24-bit colors, attributes, underline styles |
| `cursor` | cursor positioning, short writes and erase in line, as in full-screen programs |
| `scroll-region` | scrolling inside a `DECSTBM` region, with reverse index |
| `alt-screen` | full-screen redraws on the alternate screen inside synchronized updates |

The **render scenarios**, each at 80×24, 250×75 (2254×1354 pixels with the
reference font) and 426×120 (3838×2164 pixels, about 4K):

| Scenario | Frame |
| --- | --- |
| `full` | redraw every pixel (window exposed, palette changed) |
| `rows` | every row changed (a full-screen program redrew) |
| `scroll` | output scrolled by one line |
| `cell` | one character changed (typing) |

The renderer and pipeline benchmarks do not use Wayland. They measure
parsing and drawing into the shared-memory image, which is everything
chezterm does besides handing the buffer to the compositor.

## What makes it reproducible

- **Deterministic input.** The workloads and render frames come from a
  seeded linear congruential generator, so the bytes are identical on every
  machine, Chez version and run. Each result records a checksum of its
  workload (FNV-1a). The same checksums come out of Chez 9.5.8 and 10.4.1:

  | Workload | Checksum (8 MiB, 200 columns) |
  | --- | --- |
  | `ascii` | `D2BCE1E1` |
  | `unicode` | `2F73DF8D` |
  | `sgr` | `5FA1B51E` |
  | `cursor` | `7EA964EC` |
  | `scroll-region` | `16146F55` |
  | `alt-screen` | `978BC51F` |

- **A pinned environment.** `nix run .#bench` runs against the Nix package:
  a fixed Chez Scheme, fixed libraries (FreeType, fontconfig, pixman, …) and
  a fontconfig that contains only DejaVu Sans Mono. Without Nix the benchmark
  asks for "DejaVu Sans Mono" at 11 pt and 96 dpi. The cell size it got is
  recorded, so a different font is visible in the results.
- **A recorded environment.** Every result file contains the revision,
  Chez version, machine type, CPU model and count, kernel, font, cell size and
  iteration count. The compare tool warns when they differ.
- **Statistics instead of single numbers.** Each benchmark runs one warm-up
  iteration and then 7 measured ones. Memory is collected before each
  iteration, and a fresh terminal is used for each parse sample. The table
  shows median, minimum, maximum and the median absolute deviation (±%). The
  JSON file keeps all samples.

## Comparing two versions

Two runs at different times differ by more than their own noise on most
machines: CPU frequency, thermal state and other load drift. On the
reference machine below, two consecutive full runs of the same build
differed by up to 18% on individual benchmarks.

`bench/ab.sh` therefore interleaves the two builds, running
A B A B … for 5 rounds of 3 iterations each by default. Drift then affects
both sides equally.

```sh
make bench-ab BASE=main BENCH_ARGS="--only render" ROUNDS=5

# or with Nix, for any two revisions:
nix build github:OWNER/REPO/OLD#bench -o old
nix build .#bench -o new
nix run .#bench-ab -- -r 5 -c 2 -- old/bin/chezterm-bench new/bin/chezterm-bench
```

`-c CPU` pins both runs to one CPU with `taskset`. `make bench-ab` builds
`BASE` in `build/base` and runs this checkout's `bench/run.ss` against both
builds, so `BASE` must have the library interfaces the runner uses. A change
to the runner itself, such as the pipeline loop's frame pacing, only shows
when each side runs its own `bench/run.ss`: pass `bench/ab.sh` the two
commands, e.g. `"scheme -q --libdirs build/base/build/lib:build/base --script
build/base/bench/run.ss"` for the base, or compare two `nix build .#bench`
outputs.

`bench/compare.ss` merges the samples of each side. It calls a benchmark
faster or slower only when both of these hold:
- the medians differ by at least 5% (`--threshold`)
- a two-sided Mann-Whitney U test says the two sample sets differ, with
  p < 0.05 (`--alpha`) after the Holm-Bonferroni correction for comparing
  about 20 benchmarks at once. Without the correction, one false alarm per
  comparison would be expected.

`--fail` makes the exit status 1 when anything got slower, for use in
scripts.

### Checking the method

On the reference machine:

- **Same build against itself**, interleaved, 4 rounds: no benchmark was
  flagged. Changes were at most ±10%, with adjusted p ≥ 0.4.
- **The same two builds as separate runs**, not interleaved: one benchmark
  was flagged (`render/scroll-80x24`, +6.0%, p = 0.045). Individual
  benchmarks moved by up to 18.6%. That is the drift described above.
- **A deliberately slowed renderer**, which computes the cell colors 8 times
  per row: all six affected benchmarks were flagged (+14% to +27%,
  p < 0.001). `parse/ascii`, which that change doesn't touch, was not flagged
  (-1.1%).

## Reference results

These numbers come from `nix run .#bench` at `9258a4f`, with every library
compiled at `optimize-level 2`, using Chez Scheme 10.4.1 on a 4-vCPU cloud
VM (Intel Xeon @ 2.80GHz) with a 9×18 cell. They are only comparable to runs
on the same machine. Use them to see where time goes, not as targets.
"Before" is the previous reference run, at `7440867`.

| Benchmark | Before | Median | Unit | ±% |
| --- | ---: | ---: | --- | ---: |
| `parse/ascii` | 30.15 | 38.95 | MB/s | 6.6 |
| `parse/unicode` | 11.73 | 15.32 | MB/s | 3.7 |
| `parse/sgr` | 29.82 | 28.14 | MB/s | 11.5 |
| `parse/cursor` | 39.49 | 42.63 | MB/s | 1.3 |
| `parse/scroll-region` | 23.77 | 41.88 | MB/s | 7.3 |
| `parse/alt-screen` | 99.81 | 102.20 | MB/s | 0.9 |
| `render/full-80x24` | 0.51 | 0.46 | ms/frame | 2.8 |
| `render/rows-80x24` | 0.49 | 0.47 | ms/frame | 1.9 |
| `render/scroll-80x24` | 0.09 | 0.08 | ms/frame | 4.9 |
| `render/cell-80x24` | 0.05 | 0.03 | ms/frame | 3.7 |
| `render/full-250x75` | 6.51 | 5.64 | ms/frame | 8.2 |
| `render/rows-250x75` | 5.86 | 6.00 | ms/frame | 9.3 |
| `render/scroll-250x75` | 0.76 | 0.70 | ms/frame | 1.8 |
| `render/cell-250x75` | 0.23 | 0.21 | ms/frame | 2.1 |
| `render/full-426x120` | 21.77 | 16.10 | ms/frame | 4.5 |
| `render/rows-426x120` | 16.79 | 16.84 | ms/frame | 3.2 |
| `render/scroll-426x120` | 3.87 | 2.89 | ms/frame | 9.1 |
| `render/cell-426x120` | 0.52 | 0.51 | ms/frame | 1.8 |
| `pipeline/ascii` | 15.01 | 21.96 | MB/s | 2.9 |
| `pipeline/sgr` | 13.16 | 18.12 | MB/s | 6.4 |
| `pipeline/unicode` | 7.11 | 8.32 | MB/s | 1.9 |

Two separate runs drift (see above), so the "Before" column alone proves
nothing. `parse/sgr`, for example, reads lower here but is 20% faster in the
interleaved comparison. That comparison of `9258a4f` against `0d8be25` (the
previous `main`) ran each side with its own `bench/run.ss`, in 5 rounds of
3 iterations:

| Benchmark | `0d8be25` | `9258a4f` | Change | p |
| --- | ---: | ---: | ---: | ---: |
| `parse/ascii` | 30.38 | 38.59 | +27.0% | 0.001 |
| `parse/unicode` | 10.48 | 14.61 | +39.5% | < 0.001 |
| `parse/sgr` | 27.95 | 33.63 | +20.3% | 0.006 |
| `parse/cursor` | 44.37 | 44.48 | +0.2% | 1.000 |
| `parse/scroll-region` | 23.39 | 42.40 | +81.3% | < 0.001 |
| `parse/alt-screen` | 101.64 | 95.26 | -6.3% | 1.000 |
| `render/full-80x24` | 0.48 | 0.46 | -5.0% | 0.009 |
| `render/full-250x75` | 7.29 | 6.18 | -15.3% | 0.111 |
| `render/full-426x120` | 22.12 | 17.75 | -19.8% | < 0.001 |
| `render/rows-*`, `scroll-*`, `cell-*` | | | -8% to +11% | not flagged: under 5%, or p = 0.68–1.0 |
| `pipeline/ascii` | 20.78 | 20.40 | -1.8% | 1.000 |
| `pipeline/sgr` | 13.35 | 18.87 | +41.3% | < 0.001 |
| `pipeline/unicode` | 6.39 | 8.10 | +26.8% | < 0.001 |

The compare tool flagged 7 benchmarks as faster and none as slower.
`pipeline/ascii` at `0d8be25` is already above its old reference value
(15.0), because of machine drift.

### What the numbers show

- **Clearing lines was the largest parsing cost.** Source profiles
  (`compile-profile`) showed that every line scrolled into view was cleared
  cell by cell, with three checked stores per cell. For `scroll-region` that
  was 20 million cell writes against 4 million printed cells per 4 MiB. Cell
  colors are now stored XORed with their defaults, so a blank cell is all
  zeros. A whole-line clear is then one `fxvector-fill!`, about 4.5× faster,
  and new lines are plain `make-fxvector`s.
  - `scroll-region`: +59%
  - `ascii`: +22%
  - `sgr`: +10%
  - `unicode`: +11%.
- **Combining marks were deleted one column at a time.** Clearing a line
  that held a combining mark deleted each of its 200 columns from the line's
  table. Marks are now removed by table entry, and an emptied table is
  dropped: `unicode` +10%.
- **Unicode text still parses about 2.5× slower than ASCII.** Each non-ASCII
  character goes through `print!` with its checks (width, wrapping, wide
  character edges, combining marks). Decoding UTF-8 is not the cost, see
  below.
- **What remains in parsing is spread thin.** After these changes the
  profiles have no single hot spot. The largest remaining item is shifting
  the screen's line vector on every line feed (about 50 pointer moves).
- **Allocation matters only while the scrollback fills.** A fresh terminal
  allocates one line per new history entry: 46 MB for the first 10 000 lines
  in `parse/ascii`, where GC takes 42 of 203 ms. Once the history is full,
  lines are recycled, and `cursor`, `scroll-region` and `alt-screen` allocate
  nothing beyond their input.
- **Rendering is dominated by pixman.** Copying a 9×18 tile costs about
  100 ns when hot and 195 ns across a 250-column image, against 10–25 ns
  for the FFI call itself. For a 250×75 frame of dense text:
  - tile copies: about 3 ms
  - pass 3, finding the tiles: 1.2 ms
  - colors, background runs and underlines: 1.2 ms
  - comparing rows: 0.1 ms.

  A full redraw no longer fills the whole image first, because every row is
  drawn across the whole width anyway: `full-426x120` -20%.
- **The pipeline is now limited by parsing and the pty itself.** While a read
  batch does not drain the pty, frames wait 4× the last frame's drawing
  time, at most 50 ms, so drawing takes at most about a fifth of the time.
  For `pipeline/ascii` on this machine:
  - raw pty reads: 71 MB/s
  - reading and parsing: 25 MB/s
  - reading, parsing and drawing: 22 MB/s.

  In the real terminal under headless sway (1920×1080, 213×59 cells),
  `seq 1 2000000` took 3.3–3.5 s, against 4.1–4.2 s before and 0.9 s for
  `script` writing to `/dev/null`.

### What did not help

Each of these was measured with an interleaved A/B run and dropped. None
reached significance:

- **Decoding whole UTF-8 sequences at once** in `terminal-feed!`, instead of
  one byte at a time through the terminal's fields: `parse/unicode` -3.0%
  (p = 1.0). The byte-at-a-time comparison tests written for it are kept.
- **A fast path for complete CSI sequences** in `terminal-feed!`, skipping
  the state machine per parameter byte: `parse/sgr` +7.4% (p = 0.12),
  `parse/cursor` -3.1%. Its tests are kept as well.
- **Clearing partial ranges with a flat loop over the fxvector** instead of
  per cell: 40% slower in a microbenchmark, and `parse/cursor` -11% in an A/B
  run. Partial clears keep the per-cell loop.
- **A cell layout in bytevectors** (four 32-bit fields per cell), which would
  have allowed `memcpy`-speed clears and row comparisons: in
  microbenchmarks, 32-bit stores were about 3× slower than `fxvector-set!`
  on the print path, so it was not pursued.
- In the renderer, **reusing the previous cell's colors** when the color
  fields and attributes are unchanged, and **probing the tile table inline**
  in `draw-row!`: no change in `render/rows-250x75` or `full-250x75` beyond
  noise. The time is in pixman, not in the Scheme around it.
