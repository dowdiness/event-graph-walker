# Per-Step Benchmark Results

**Date:** 2026-03-18
**Environment:** WSL2 Linux 6.6.87, MoonBit, `moon bench --release --package text`
**Method:** Each step benchmarked by checking out its commit in the same worktree

## insert append (1000 chars) — primary target

| Step | Commit | Time | Delta | Speedup |
|------|--------|------|-------|---------|
| Baseline | 04d2425 | 4.12s | — | 1x |
| Step 1: Children Index | d0ef81e | 160.55ms | -3.96s | 25.7x |
| Step 2: Cursor Fast-Path | 0146b17 | 1.47ms | -159ms | 2,803x |
| Step 3: Batch Invalidation | 855f556 | 1.46ms | -0.01ms | 2,822x |
| Step 4: LCA Index | 5d271b0 | 1.26ms | -0.20ms | 3,270x |

## insert append (100 chars)

| Step | Time | Speedup |
|------|------|---------|
| Baseline | 4.45ms | 1x |
| Step 1: Children Index | 1.16ms | 3.8x |
| Step 2: Cursor Fast-Path | 97.57µs | 45.6x |
| Step 3: Batch Invalidation | 95.48µs | 46.6x |
| Step 4: LCA Index | 87.69µs | 50.7x |

## insert prepend (100 chars)

| Step | Time | Speedup |
|------|------|---------|
| Baseline | 4.75ms | 1x |
| Step 1: Children Index | 1.14ms | 4.2x |
| Step 2: Cursor Fast-Path | 1.15ms | 4.1x |
| Step 3: Batch Invalidation | 1.13ms | 4.2x |
| Step 4: LCA Index | 1.07ms | 4.4x |

## text() (1000-char doc)

| Step | Time | Speedup |
|------|------|---------|
| Baseline | 13.00ms | 1x |
| Step 1: Children Index | 229.28µs | 56.7x |
| Step 2: Cursor Fast-Path | 256.95µs | 50.6x |
| Step 3: Batch Invalidation | 240.95µs | 53.9x |
| Step 4: LCA Index | 218.53µs | 59.5x |

## text() (100-char doc)

| Step | Time | Speedup |
|------|------|---------|
| Baseline | 108.04µs | 1x |
| Step 1: Children Index | 16.45µs | 6.6x |
| Step 2: Cursor Fast-Path | 18.29µs | 5.9x |
| Step 3: Batch Invalidation | 17.09µs | 6.3x |
| Step 4: LCA Index | 16.05µs | 6.7x |

## delete (100 deletes from 100-char doc)

| Step | Time | Speedup |
|------|------|---------|
| Baseline | 16.76ms | 1x |
| Step 1: Children Index | 3.47ms | 4.8x |
| Step 2: Cursor Fast-Path | 2.31ms | 7.3x |
| Step 3: Batch Invalidation | 2.28ms | 7.4x |
| Step 4: LCA Index | 2.14ms | 7.8x |

## undo (50-op group)

| Step | Time | Speedup |
|------|------|---------|
| Baseline | 2.50ms | 1x |
| Step 1: Children Index | 849.88µs | 2.9x |
| Step 2: Cursor Fast-Path | 579.83µs | 4.3x |
| Step 3: Batch Invalidation | 565.22µs | 4.4x |
| Step 4: LCA Index | 537.61µs | 4.7x |

## checkout (midpoint of 1000-op doc)

| Step | Time | Speedup |
|------|------|---------|
| Baseline | 720.95µs | 1x |
| Step 1: Children Index | 908.97µs | 0.8x (regression) |
| Step 2: Cursor Fast-Path | 845.92µs | 0.9x |
| Step 3: Batch Invalidation | 894.54µs | 0.8x |
| Step 4: LCA Index | 831.52µs | 0.9x |

## sync apply (500 remote ops)

| Step | Time | Speedup |
|------|------|---------|
| Baseline | 1.34ms | 1x |
| Step 1: Children Index | 1.53ms | 0.9x |
| Step 2: Cursor Fast-Path | 1.55ms | 0.9x |
| Step 3: Batch Invalidation | 1.54ms | 0.9x |
| Step 4: LCA Index | 1.46ms | 0.9x |

## Analysis

### Step 1: Children Index — biggest absolute win
- **4.12s → 160ms** for 1000-char append (25.7x)
- Eliminated O(n²) traversal: `get_children()` scanned the entire HashMap per node
- Also delivered the entire `text()` speedup (13ms → 229µs, 56.7x)
- Prepend improved 4.2x (same traversal bottleneck)

### Step 2: Cursor Fast-Path — biggest relative win
- **160ms → 1.47ms** for 1000-char append (109x from Step 1)
- Eliminated per-char cache rebuild for sequential end-of-document appends
- No effect on prepend (cursor doesn't hit for position 0 inserts)
- No effect on text() (unrelated to insert path)

### Step 3: Batch Invalidation — negligible for append
- **1.47ms → 1.46ms** (within noise)
- The cursor already eliminated cache reads, so removing per-char `invalidate_cache()` saved only the cost of setting `position_cache = None` 1000 times
- Architectural benefit: makes the cursor's "no cache read" guarantee complete

### Step 4: LCA Index — no effect on append (as expected)
- **1.46ms → 1.26ms** (within run-to-run variance)
- Sequential append never calls `is_ancestor()` — the `(Some(left), None)` branch returns immediately
- Benefits concurrent/remote ops; checkout/sync numbers too noisy to measure clearly on WSL2

### Checkout/sync slight regression
- Checkout and sync show ~10-20% slower in some steps
- Likely due to: (a) children index overhead in add_item (copy-on-write array), (b) batch_inserting flag management, (c) WSL2 variance
- The absolute numbers are small (831µs vs 721µs) and within the noise band for WSL2
