# OpLog RLE Range Slice Expansion

**Date:** 2026-05-13
**Command:** `moon bench -p internal/oplog --release`
**Baseline:** `docs/benchmarks/2026-03-18-rle-all-phases-complete.md`

## Problem

After OpRun compression, `oplog - diff_and_collect (100000 ops advance)` regressed to 14.39s because `OpLog::get_ops_rle` expanded each LV range by calling `get_op` for every LV. That turned a compressed 100k-LV range into 100k RLE `find + decompress` lookups.

## Fix

`OpLog::get_ops_rle` now uses the dense-LV invariant: operations are stored in LV order, so an `LvRange` is also a positional slice of the compressed operation runs. It calls `Rle::range_clamped` once per LV range and decompresses offsets within each overlapping `OpRun`.

## Result

| Benchmark | Before | After | Speedup |
|---|---:|---:|---:|
| oplog - diff_and_collect (100000 ops advance) | 14.39s | 45.27ms | 318x |

Current run:

| Benchmark | Mean | sigma | Range |
|---|---:|---:|---:|
| oplog - diff_and_collect (100000 ops advance) | 45.27ms | 5.99ms | 36.75-50.69ms |

## Notes

- This preserves `get_ops_rle` behavior for out-of-range LVs by continuing to clamp/skip invalid positions.
- Focused tests cover middle-of-run expansion, retreat-style range ordering, and invalid-LV clamping.
