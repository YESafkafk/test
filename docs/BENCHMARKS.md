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
| `pipeline/<workload>` | MB/s | `cat` of a 16 MiB workload through a real pty into a 250×75 terminal, parsed as it arrives and rendered at most every 1/60 s, like the event loop does |

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
builds, so `BASE` must have the library interfaces the runner uses.

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

These numbers come from `nix run .#bench` at `19bfc05` (plus these changes)
with Chez Scheme 10.4.1, on a 4-vCPU cloud VM (Intel Xeon @ 2.80GHz), with
a 9×18 cell. They are only comparable to runs on the same machine. Use
them to see where time goes, not as targets.

| Benchmark | Median | Unit | ±% |
| --- | ---: | --- | ---: |
| `parse/ascii` | 46.69 | MB/s | 7.9 |
| `parse/unicode` | 12.58 | MB/s | 6.5 |
| `parse/sgr` | 39.19 | MB/s | 7.2 |
| `parse/cursor` | 78.07 | MB/s | 2.3 |
| `parse/scroll-region` | 50.95 | MB/s | 0.2 |
| `parse/alt-screen` | 194.83 | MB/s | 1.3 |
| `render/full-80x24` | 0.81 | ms/frame | 1.8 |
| `render/rows-80x24` | 0.86 | ms/frame | 2.5 |
| `render/scroll-80x24` | 0.08 | ms/frame | 2.1 |
| `render/cell-80x24` | 0.03 | ms/frame | 1.6 |
| `render/full-250x75` | 10.79 | ms/frame | 2.5 |
| `render/rows-250x75` | 10.30 | ms/frame | 1.2 |
| `render/scroll-250x75` | 0.80 | ms/frame | 0.5 |
| `render/cell-250x75` | 0.20 | ms/frame | 2.4 |
| `render/full-426x120` | 32.14 | ms/frame | 2.4 |
| `render/rows-426x120` | 29.57 | ms/frame | 3.1 |
| `render/scroll-426x120` | 3.94 | ms/frame | 3.0 |
| `render/cell-426x120` | 0.48 | ms/frame | 8.9 |
| `pipeline/ascii` | 27.18 | MB/s | 8.8 |
| `pipeline/sgr` | 14.10 | MB/s | 6.0 |
| `pipeline/unicode` | 7.72 | MB/s | 2.2 |

### What the numbers show

- **Multicolored text defeats the ASCII tile cache.** The renderer keeps one
  tile per ASCII character and style, for a single color pair. With an
  8-color palette and background changes, most lookups miss and fall back to
  the hashtables. An interleaved A/B with that cache disabled was not slower;
  the larger sizes trended 6–10% faster, though below significance. A cache
  with several entries per character, or keyed by color, would help. So would
  dropping it.
- **Unicode text parses 3–4× slower than ASCII** (12.6 against 46.7 MB/s).
  Each non-ASCII character goes through the general per-code-point path, and
  combining marks through a per-line hashtable.
- **In the pipeline, rendering competes with parsing.** At 250×75, a frame in
  which everything changed takes about 10 ms of every 16.7 ms, so `ascii`
  reaches 27 MB/s through the pty against 47 MB/s parse-only. Skipping frames
  while output is streaming would raise throughput, at the cost of fewer
  intermediate frames.
