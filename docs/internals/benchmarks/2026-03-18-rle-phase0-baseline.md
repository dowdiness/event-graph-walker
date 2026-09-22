# Benchmark Baseline: Post-Phase 0 / Pre-Phase 1&2

**Date:** 2026-03-18
**State:** Phase 0 (submodule swap) and Phase 3 (LvRange compression) complete. Phases 1 (OpRun) and 2 (VisibleRun) not yet started.
**Command:** `moon bench --release` in event-graph-walker worktree
**Platform:** Linux 6.6.87.2-microsoft-standard-WSL2

---

## OpLog (Phase 1 will change these)

| Benchmark | Mean | σ | Range |
|---|---|---|---|
| get_op (1000 ops) | 0.02 µs | 0.00 µs | 0.01–0.02 µs |
| insert (100 ops) | 44.03 µs | 0.87 µs | 43.11–45.33 µs |
| insert (1000 ops) | 710.12 µs | 49.97 µs | 645.13–811.93 µs |
| insert and delete mix (100 ops) | 75.82 µs | 2.74 µs | 71.65–79.27 µs |
| apply_remote (50 ops) | 26.57 µs | 0.56 µs | 26.01–27.84 µs |
| get_frontier (single agent) | 0.02 µs | 0.00 µs | 0.02–0.02 µs |
| get_frontier (5 agents) | 0.02 µs | 0.00 µs | 0.02–0.02 µs |
| sequential typing (500 chars) | 287.27 µs | 6.86 µs | 277.92–298.40 µs |
| sequential typing (100k chars) | 284.12 ms | 39.84 ms | 219.22–325.61 ms |
| random position inserts (100 ops) | 45.56 µs | 1.08 µs | 43.86–46.70 µs |
| walk_and_collect (100 ops) | 71.44 µs | 2.70 µs | 69.32–78.52 µs |
| walk_and_collect (concurrent) | 74.30 µs | 3.75 µs | 70.87–81.38 µs |
| diff_and_collect (advance 20) | 35.05 µs | 0.44 µs | 34.34–35.66 µs |
| diff_and_collect (100k advance) | 821.02 ms | 54.92 ms | 732.28–888.65 ms |
| walk_filtered (inserts only) | 52.75 µs | 4.12 µs | 49.40–59.92 µs |

**Phase 1 notes:**
- `get_op` is currently O(1) array index at 0.02 µs. After Phase 1 it becomes O(log n) via `Rle::find` + decompress. Watch for regression here.
- `insert`/`add_op` is currently `Array::push`. After Phase 1 it becomes `Rle::append` with merge attempt. Expect slight overhead per-op but massive memory savings.

## Document / Position Cache (Phase 2 will change these)

| Benchmark | Mean | σ | Range |
|---|---|---|---|
| text - insert append (100 chars) | 4.47 ms | 166.77 µs | 4.33–4.87 ms |
| text - insert append (1000 chars) | 4.16 s | 80.54 ms | 4.00–4.28 s |
| text - insert prepend (100 chars) | 4.33 ms | 62.26 µs | 4.24–4.43 ms |
| text - delete (100 deletes) | 15.91 ms | 373.93 µs | 15.43–16.28 ms |
| text - text() (100 chars) | 112.36 µs | 0.88 µs | 110.99–113.70 µs |
| text - text() (1000 chars) | 13.54 ms | 292.40 µs | 13.17–14.14 ms |
| text - len() (1000 chars) | 0.01 µs | 0.00 µs | 0.01–0.01 µs |

**Phase 2 notes:**
- `insert append (1000 chars)` at **4.16s** is O(n²) due to full cache rebuild per character. Phase 2 compresses the cache but doesn't eliminate the rebuild. Incremental cache updates (future, post-Phase 2) would fix this.
- `position_to_lv` is currently O(1) array index. After Phase 2 it becomes O(log n) via `Rle::find`.
- `lv_to_position` is currently O(n) linear scan. After Phase 2 it becomes O(k) where k = run count.

## Walker (Phase 3 already applied)

| Benchmark | Mean | σ | Range |
|---|---|---|---|
| walker - linear (10 ops) | 3.73 µs | 0.05 µs | 3.67–3.82 µs |
| walker - linear (100 ops) | 64.60 µs | 2.34 µs | 62.71–70.62 µs |
| walker - linear (1000 ops) | 1.20 ms | 19.63 µs | 1.17–1.23 ms |
| walker - large (10k ops) | 27.44 ms | 1.33 ms | 25.94–29.98 ms |
| walker - linear (100k ops) | 811.15 ms | 81.95 ms | 708.51–925.47 ms |
| walker - concurrent (2×50) | 65.08 µs | 0.92 µs | 63.92–66.90 µs |
| walker - concurrent (5×20) | 63.66 µs | 0.73 µs | 62.88–65.04 µs |
| walker - concurrent (100k, 5 agents) | 831.49 ms | 59.95 ms | 749.87–934.56 ms |
| walker - diamond (50 diamonds) | 163.77 µs | 45.95 µs | 124.98–220.88 µs |
| walker - diff advance (10 new ops) | 27.33 µs | 0.40 µs | 26.83–27.88 µs |
| walker - diff concurrent branches | 67.55 µs | 17.02 µs | 52.23–87.41 µs |

**Phase 3 notes:**
- These numbers include the Rle[LvRange] compression. The walker itself is dominated by Kahn's algorithm + HashSet operations, not by the output format. Compression benefit is in memory, not wall-clock time.

## Branch

| Benchmark | Mean | σ | Range |
|---|---|---|---|
| checkout (10 ops) | 4.94 µs | 0.09 µs | 4.87–5.12 µs |
| checkout (100 ops) | 82.07 µs | 2.41 µs | 78.69–85.01 µs |
| checkout (1000 ops) | 1.63 ms | 51.46 µs | 1.57–1.73 ms |
| advance (10 new ops) | 29.95 µs | 0.26 µs | 29.64–30.47 µs |
| advance (100 new ops) | 124.22 µs | 1.72 µs | 121.72–127.25 µs |
| single advance (1 new op) | 22.62 µs | 0.33 µs | 22.14–23.25 µs |
| single advance (50 new ops) | 70.00 µs | 1.25 µs | 67.91–72.56 µs |
| checkout concurrent branches | 83.53 µs | 3.46 µs | 81.27–91.25 µs |
| checkout with deletes | 141.48 µs | 4.78 µs | 136.04–149.40 µs |
| repeated advance steady-state | 122.55 µs | 2.37 µs | 119.12–127.22 µs |
| repeated advance with mutations | 18.25 ms | 5.52 ms | 11.17–26.08 ms |
| to_text (100 chars) | 112.88 µs | 4.10 µs | 110.19–124.10 µs |
| to_text (1000 chars) | 11.27 ms | 292.87 µs | 10.94–11.69 ms |
| realistic typing (50 chars) | 76.09 ms | 20.92 ms | 47.37–106.75 ms |
| concurrent merge scenario | 25.95 µs | 5.24 µs | 19.08–30.18 µs |

## Merge

| Benchmark | Mean | σ | Range |
|---|---|---|---|
| concurrent edits (2×10) | 19.30 µs | 0.47 µs | 18.89–20.29 µs |
| concurrent edits (2×50) | 134.30 µs | 1.83 µs | 130.94–137.50 µs |
| concurrent edits (2×200) | 747.59 µs | 10.95 µs | 730.04–761.90 µs |
| many agents (5×20) | 211.04 µs | 5.46 µs | 206.16–222.61 µs |
| with deletes (50 ins, 25 del) | 118.14 µs | 3.30 µs | 115.04–124.21 µs |
| graph_diff advance (20 ops) | 74.81 µs | 4.46 µs | 70.53–83.07 µs |
| repeated small (10×5 ops) | 202.77 µs | 6.66 µs | 193.44–213.15 µs |
| context apply ops (50 ops) | 7.00 µs | 0.56 µs | 6.56–8.12 µs |

## Text Sync

| Benchmark | Mean | σ | Range |
|---|---|---|---|
| sync export_all (100 ops) | 0.21 µs | 0.01 µs | 0.21–0.24 µs |
| sync export_all (1000 ops) | 1.60 µs | 0.02 µs | 1.58–1.64 µs |
| sync export_since (50-op delta) | 472.51 µs | 23.70 µs | 450.53–517.37 µs |
| sync apply (50 remote ops) | 79.86 µs | 0.81 µs | 78.92–81.40 µs |
| sync apply (500 remote ops) | 1.35 ms | 58.26 µs | 1.29–1.44 ms |
| bidirectional sync (2 peers, 50 each) | 172.20 µs | 5.39 µs | 164.55–179.92 µs |
| checkout (midpoint, 100 ops) | 37.99 µs | 0.52 µs | 37.30–38.98 µs |
| checkout (midpoint, 1000 ops) | 689.97 µs | 22.18 µs | 662.77–722.60 µs |

## Undo

| Benchmark | Mean | σ | Range |
|---|---|---|---|
| record_insert (100 ops, 1 group) | 1.88 µs | 0.02 µs | 1.84–1.91 µs |
| record_insert (100 ops, 100 groups) | 2.68 µs | 0.07 µs | 2.57–2.83 µs |
| undo() (10-op group) | 40.44 µs | 0.44 µs | 39.99–41.16 µs |
| undo() (50-op group) | 2.52 ms | 116.48 µs | 2.44–2.78 ms |
| undo+redo roundtrip (10-op) | 46.05 µs | 0.54 µs | 45.51–46.95 µs |
| 10 undo+redo cycles (10-op) | 396.83 µs | 11.15 µs | 386.87–416.79 µs |

## Version Vectors

| Benchmark | Mean | σ | Range |
|---|---|---|---|
| create (1 agent) | 0.05 µs | 0.00 µs | 0.05–0.05 µs |
| create (5 agents) | 0.27 µs | 0.00 µs | 0.26–0.27 µs |
| create (20 agents) | 1.21 µs | 0.01 µs | 1.19–1.23 µs |
| compare equal (5 agents) | 0.20 µs | 0.00 µs | 0.20–0.21 µs |
| compare <= (5 agents) | 0.11 µs | 0.00 µs | 0.11–0.12 µs |
| compare <= (20 agents) | 0.47 µs | 0.01 µs | 0.47–0.48 µs |
| merge (5 agents) | 0.37 µs | 0.00 µs | 0.37–0.38 µs |
| merge (20 agents) | 1.93 µs | 0.07 µs | 1.90–2.12 µs |
| includes (5 agents) | 0.22 µs | 0.04 µs | 0.18–0.29 µs |
| concurrent (5 agents) | 0.14 µs | 0.04 µs | 0.12–0.21 µs |
| from_frontier (10 ops) | 1.12 µs | 0.15 µs | 1.02–1.42 µs |
| from_frontier (100 ops, 5 agents) | 14.40 µs | 0.10 µs | 14.26–14.53 µs |
| to_frontier (5 agents) | 0.18 µs | 0.00 µs | 0.17–0.18 µs |
| roundtrip (5 agents) | 14.86 µs | 0.26 µs | 14.56–15.18 µs |
| agents (5 agents) | 0.04 µs | 0.00 µs | 0.04–0.04 µs |
| length (20 agents) | 0.01 µs | 0.00 µs | 0.01–0.01 µs |
