# Benchmark Results: After RLE Phases 1-3

**Date:** 2026-03-18
**State:** All three RLE phases complete (Phase 0: submodule swap, Phase 1: OpRun, Phase 2: VisibleRun, Phase 3: LvRange)
**Command:** `moon bench --release` in event-graph-walker worktree
**Platform:** Linux 6.6.87.2-microsoft-standard-WSL2
**Baseline:** `docs/benchmarks/2026-03-18-rle-phase0-baseline.md`

---

## Key Regressions (Phase 1: OpRun)

| Benchmark | Before | After | Change | Root Cause |
|---|---|---|---|---|
| get_op (1000 ops) | 0.02 µs | 4.09 µs | **205x slower** | O(1) array index → O(log n) find + decompress |
| sequential typing (100k chars) | 284 ms | 6.70 s | **24x slower** | 100k append+merge cycles with string concat |
| diff_and_collect (100k advance) | 821 ms | 14.39 s | **18x slower** | 100k get_op calls through find+decompress |
| sync export_all (100 ops) | 0.21 µs | 18.66 µs | **89x slower** | get_all_ops now decompresses all runs |
| sync export_all (1000 ops) | 1.60 µs | 1.41 ms | **881x slower** | Same: full run decompression |

## Improvements (Phase 2: VisibleRun, Phase 3: LvRange)

| Benchmark | Before | After | Change | Root Cause |
|---|---|---|---|---|
| text - insert append (100) | 4.47 ms | 4.28 ms | -4% | Compressed cache slightly faster |
| text - insert append (1000) | 4.16 s | 3.79 s | -9% | Same |
| text - text() (100) | 112 µs | 98 µs | -13% | Compressed cache |
| text - text() (1000) | 13.5 ms | 12.3 ms | -9% | Same |
| walker linear (100k) | 811 ms | 658 ms | **-19%** | LvRange compression reduces allocation |
| walker large (10k) | 27.4 ms | 22.4 ms | **-18%** | Same |

## Neutral (within noise)

| Benchmark | Before | After | Change |
|---|---|---|---|
| insert (100 ops) | 44 µs | 49 µs | +11% |
| insert (1000 ops) | 710 µs | 801 µs | +13% |
| walk_and_collect (100 ops) | 71 µs | 81 µs | +14% |
| apply_remote (50 ops) | 26.6 µs | 26.7 µs | ~0% |
| text - delete (100) | 15.9 ms | 14.9 ms | -6% |

---

## Full Results

### OpLog

| Benchmark | Mean | σ | Range |
|---|---|---|---|
| get_op (1000 ops) | 4.09 µs | 0.02 µs | 4.06–4.13 µs |
| insert (100 ops) | 49.21 µs | 1.74 µs | 47.30–53.45 µs |
| insert (1000 ops) | 801.17 µs | 14.15 µs | 779.14–818.91 µs |
| insert and delete mix (100 ops) | 76.42 µs | 3.30 µs | 73.62–85.24 µs |
| apply_remote (50 ops) | 26.70 µs | 0.20 µs | 26.43–27.00 µs |
| get_frontier (single agent) | 0.02 µs | 0.00 µs | 0.01–0.02 µs |
| get_frontier (5 agents) | 0.02 µs | 0.00 µs | 0.02–0.02 µs |
| sequential typing (500 chars) | 320.05 µs | 4.61 µs | 314.55–329.07 µs |
| sequential typing (100k chars) | 6.70 s | 118.30 ms | 6.50–6.91 s |
| random position inserts (100 ops) | 46.19 µs | 0.51 µs | 45.10–47.01 µs |
| walk_and_collect (100 ops) | 81.22 µs | 0.87 µs | 80.33–82.93 µs |
| walk_and_collect (concurrent) | 76.78 µs | 1.06 µs | 75.41–78.43 µs |
| diff_and_collect (advance 20) | 38.15 µs | 0.37 µs | 37.73–38.75 µs |
| diff_and_collect (100k advance) | 14.39 s | 161.30 ms | 14.15–14.57 s |
| walk_filtered (inserts only) | 52.26 µs | 0.43 µs | 51.70–52.95 µs |

### Document / Text

| Benchmark | Mean | σ | Range |
|---|---|---|---|
| text - insert append (100 chars) | 4.28 ms | 156.56 µs | 4.12–4.52 ms |
| text - insert append (1000 chars) | 3.79 s | 35.60 ms | 3.75–3.86 s |
| text - insert prepend (100 chars) | 4.24 ms | 77.60 µs | 4.16–4.40 ms |
| text - delete (100 deletes) | 14.86 ms | 119.74 µs | 14.72–15.06 ms |
| text - text() (100 chars) | 98.19 µs | 0.42 µs | 97.65–98.72 µs |
| text - text() (1000 chars) | 12.30 ms | 171.20 µs | 12.06–12.56 ms |
| text - len() (1000 chars) | 0.01 µs | 0.00 µs | 0.01–0.01 µs |

### Walker

| Benchmark | Mean | σ | Range |
|---|---|---|---|
| walker - linear (10 ops) | 3.66 µs | 0.08 µs | 3.56–3.80 µs |
| walker - linear (100 ops) | 61.94 µs | 1.59 µs | 60.39–65.71 µs |
| walker - linear (1000 ops) | 1.10 ms | 14.78 µs | 1.08–1.12 ms |
| walker - large (10k ops) | 22.40 ms | 1.06 ms | 21.54–24.73 ms |
| walker - linear (100k ops) | 657.95 ms | 57.26 ms | 592.86–752.10 ms |
| walker - concurrent (2×50) | 59.15 µs | 1.21 µs | 57.70–61.52 µs |
| walker - concurrent (5×20) | 60.17 µs | 0.29 µs | 59.67–60.54 µs |
| walker - concurrent (100k, 5 agents) | 773.76 ms | 76.27 ms | 710.34–913.23 ms |
| walker - diamond (50 diamonds) | 116.00 µs | 1.14 µs | 114.43–117.77 µs |
| walker - diff advance (10 new ops) | 24.55 µs | 0.21 µs | 24.31–24.95 µs |
| walker - diff concurrent branches | 48.52 µs | 1.27 µs | 46.80–50.15 µs |

### Branch

| Benchmark | Mean | σ | Range |
|---|---|---|---|
| checkout (10 ops) | 4.93 µs | 0.03 µs | 4.89–4.98 µs |
| checkout (100 ops) | 94.87 µs | 5.76 µs | 90.93–105.84 µs |
| checkout (1000 ops) | 2.72 ms | 45.59 µs | 2.66–2.81 ms |
| advance (10 new ops) | 28.40 µs | 0.72 µs | 27.61–29.56 µs |
| advance (100 new ops) | 146.92 µs | 2.99 µs | 143.79–153.89 µs |
| single advance (1 new op) | 20.86 µs | 0.29 µs | 20.50–21.40 µs |
| single advance (50 new ops) | 83.58 µs | 0.91 µs | 82.46–85.33 µs |
| checkout concurrent branches | 82.61 µs | 0.61 µs | 81.82–83.51 µs |
| checkout with deletes | 133.85 µs | 1.52 µs | 131.83–135.94 µs |
| repeated advance steady-state | 108.96 µs | 12.52 µs | 96.93–133.67 µs |
| repeated advance with mutations | 21.23 ms | 9.39 ms | 10.90–35.63 ms |
| to_text (100 chars) | 101.77 µs | 0.78 µs | 100.70–102.96 µs |
| to_text (1000 chars) | 10.20 ms | 100.44 µs | 10.09–10.36 ms |
| realistic typing (50 chars) | 71.17 ms | 20.64 ms | 43.13–100.03 ms |
| concurrent merge scenario | 21.24 µs | 0.71 µs | 20.54–22.63 µs |

### Merge

| Benchmark | Mean | σ | Range |
|---|---|---|---|
| concurrent edits (2×10) | 22.57 µs | 0.49 µs | 22.15–23.81 µs |
| concurrent edits (2×50) | 153.38 µs | 2.61 µs | 149.46–157.49 µs |
| concurrent edits (2×200) | 844.81 µs | 16.09 µs | 819.60–874.02 µs |
| many agents (5×20) | 225.69 µs | 3.10 µs | 220.53–229.77 µs |
| with deletes (50 ins, 25 del) | 125.82 µs | 3.24 µs | 122.38–132.47 µs |
| graph_diff advance (20 ops) | 83.04 µs | 1.16 µs | 81.80–85.14 µs |
| repeated small (10×5 ops) | 186.21 µs | 2.16 µs | 183.29–189.49 µs |
| context apply ops (50 ops) | 11.67 µs | 0.06 µs | 11.58–11.78 µs |

### Text Sync

| Benchmark | Mean | σ | Range |
|---|---|---|---|
| sync export_all (100 ops) | 18.66 µs | 0.19 µs | 18.44–18.96 µs |
| sync export_all (1000 ops) | 1.41 ms | 20.30 µs | 1.39–1.45 ms |
| sync export_since (50-op delta) | 542.54 µs | 4.29 µs | 537.71–550.36 µs |
| sync apply (50 remote ops) | 80.36 µs | 1.80 µs | 77.81–83.10 µs |
| sync apply (500 remote ops) | 1.57 ms | 29.85 µs | 1.53–1.62 ms |
| bidirectional sync (2 peers, 50 each) | 164.70 µs | 2.02 µs | 161.55–168.23 µs |
| checkout (midpoint, 100 ops) | 41.46 µs | 0.52 µs | 40.97–42.67 µs |
| checkout (midpoint, 1000 ops) | 1.02 ms | 12.56 µs | 992.84–1.03 ms |

### Undo

| Benchmark | Mean | σ | Range |
|---|---|---|---|
| record_insert (100 ops, 1 group) | 1.65 µs | 0.02 µs | 1.62–1.69 µs |
| record_insert (100 ops, 100 groups) | 2.25 µs | 0.05 µs | 2.19–2.32 µs |
| undo() (10-op group) | 41.22 µs | 0.36 µs | 40.68–42.04 µs |
| undo() (50-op group) | 2.30 ms | 34.33 µs | 2.24–2.35 ms |
| undo+redo roundtrip (10-op) | 44.41 µs | 0.23 µs | 44.09–44.74 µs |
| 10 undo+redo cycles (10-op) | 363.17 µs | 6.02 µs | 355.73–374.30 µs |

### Version Vectors

| Benchmark | Mean | σ | Range |
|---|---|---|---|
| create (1 agent) | 0.05 µs | 0.00 µs | 0.05–0.05 µs |
| create (5 agents) | 0.25 µs | 0.00 µs | 0.25–0.26 µs |
| create (20 agents) | 1.19 µs | 0.02 µs | 1.17–1.22 µs |
| compare equal (5 agents) | 0.20 µs | 0.00 µs | 0.20–0.20 µs |
| compare <= (5 agents) | 0.11 µs | 0.00 µs | 0.11–0.12 µs |
| compare <= (20 agents) | 0.46 µs | 0.01 µs | 0.45–0.47 µs |
| merge (5 agents) | 0.36 µs | 0.01 µs | 0.35–0.38 µs |
| merge (20 agents) | 1.78 µs | 0.01 µs | 1.77–1.80 µs |
| includes (5 agents) | 0.18 µs | 0.00 µs | 0.17–0.18 µs |
| concurrent (5 agents) | 0.11 µs | 0.00 µs | 0.11–0.12 µs |
| from_frontier (10 ops) | 1.02 µs | 0.06 µs | 0.97–1.10 µs |
| from_frontier (100 ops, 5 agents) | 14.25 µs | 0.13 µs | 14.07–14.49 µs |
| to_frontier (5 agents) | 0.16 µs | 0.00 µs | 0.16–0.16 µs |
| roundtrip (5 agents) | 14.35 µs | 0.19 µs | 14.14–14.72 µs |
| agents (5 agents) | 0.04 µs | 0.00 µs | 0.04–0.05 µs |
| length (20 agents) | 0.01 µs | 0.00 µs | 0.01–0.01 µs |
