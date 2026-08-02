# Prepared local mutation — Phase A cost characterization

**Date:** 2026-08-03
**Issue:** #107
**Source revision:** `fcade51423de79865af953cd45dc4118b24ed7e9`
**Design:** ADR0006 (prepared local mutation)
**Supersedes:** [2026-08-02 Phase A stage measurements](2026-08-02-prepared-local-mutation-phase-a.md) (latency stages only; no commit-only, memory, or ops-scaling data)
**Scope:** Test-only Phase A model (`container/prepared_local_mutation_model_wbtest.mbt`). No production API promoted.

## Fixture and operation counts

`prepared_benchmark_fixture` builds a `Document` with `record_count` children under one `parent`, each carrying three property sets. One create + three property sets = **4 operations per record**.

| scenario | records | pre-command ops | post-commit ops | prepared ops |
|---|---:|---:|---:|---:|
| `empty-4` | 0 | 1 | 5 | 4 |
| `records-128-4` | 128 | 513 | 517 | 4 |
| `records-499-4` | 499 | 1997 | 2001 | 4 |
| `ops-1` | 0 | 1 | 2 | 1 |
| `ops-4` | 0 | 1 | 5 | 4 |
| `ops-16` | 0 | 1 | 17 | 16 |
| `ops-64` | 0 | 1 | 65 | 64 |

## Commands and provenance

Latency benchmarks:
```bash
just prototype-prepared-local-mutation-bench js
just prototype-prepared-local-mutation-bench wasm-gc
```
Underlying harness: `moon bench --release --target <target> --frozen -p dowdiness/event-graph-walker/container -f prepared_local_mutation_benchmark_wbtest.mbt --no-parallelize`

Memory benchmarks:
```bash
nu scripts/measure-prepared-local-mutation-memory.nu {js,wasm-gc} <scenario>
```
Each scenario spawns **5 isolated child processes** per lifecycle stage (baseline, fixture-only, prepare lifecycle, prepare+commit lifecycle). Peak RSS and wall time are captured with GNU `time` using `-f "%M\t%e"`.

Raw data: [bench JS log](raw/prepared-local-mutation-bench-js.log), [bench JS metadata](raw/prepared-local-mutation-bench-js.meta.txt), [bench wasm-gc log](raw/prepared-local-mutation-bench-wasm-gc.log), [bench wasm-gc metadata](raw/prepared-local-mutation-bench-wasm-gc.meta.txt), [memory summary](raw/prepared-local-mutation-memory-summary.log), [payload JS](raw/prepared-local-mutation-memory-payload-js.log), and [payload wasm-gc](raw/prepared-local-mutation-memory-payload-wasm-gc.log). Per-scenario RSS TSV and metadata files are in the same directory.

**Environment:** AMD Ryzen 7 6800H, Linux 6.18.33.2 WSL2, Node v24.14.1 (JS target), moon 0.1.20260713, moonc v0.10.4+2cc641edf.

**Not measured:** native and wasm latency; native and wasm peak RSS. The required release measurements in this report cover JS and wasm-gc only.

## JS target — release harness stages

| stage | mean ± σ | range (min … max) | iterations × runs |
|---|---|---|---|
| full prepare empty-4 | 115.45 µs ± 5.81 µs | 109.85 µs … 125.03 µs | 10 × 757 |
| full prepare records-128-4 | 25.19 ms ± 3.06 ms | 23.56 ms … 31.18 ms | 10 × 4 |
| full prepare records-499-4 | 113.79 ms ± 10.25 ms | 100.12 ms … 134.87 ms | 10 × 1 |
| detached lowering records-499-4 | 202.81 µs ± 7.48 µs | 193.27 µs … 213.84 µs | 10 × 508 |
| successor message records-499-4 | 3.88 ms ± 362.85 µs | 3.32 ms … 4.39 ms | 10 × 29 |
| JSON encoding records-499-4 | 27.10 ms ± 879.65 µs | 25.92 ms … 28.36 ms | 10 × 4 |
| canonical encoding records-499-4 | 14.69 ms ± 519.48 µs | 13.95 ms … 15.39 ms | 10 × 7 |
| fence validation records-499-4 | 48.76 ms ± 1.67 ms | 46.68 ms … 51.84 ms | 10 × 3 |
| post-commit full export records-499-4 | 2.16 ms ± 120.90 µs | 2.03 ms … 2.35 ms | 10 × 39 |
| post-commit JSON encoding records-499-4 | 30.91 ms ± 2.41 ms | 27.74 ms … 34.82 ms | 10 × 4 |
| post-commit canonical encoding records-499-4 | 19.45 ms ± 1.37 ms | 17.60 ms … 21.82 ms | 10 × 6 |

## wasm-gc target — release harness stages

| stage | mean ± σ | range (min … max) | iterations × runs |
|---|---|---|---|
| full prepare empty-4 | 64.90 µs ± 8.19 µs | 58.37 µs … 86.00 µs | 10 × 1454 |
| full prepare records-128-4 | 16.21 ms ± 987.80 µs | 15.23 ms … 18.23 ms | 10 × 7 |
| full prepare records-499-4 | 79.53 ms ± 4.13 ms | 74.05 ms … 87.10 ms | 10 × 2 |
| detached lowering records-499-4 | 186.86 µs ± 17.74 µs | 174.56 µs … 223.68 µs | 10 × 567 |
| successor message records-499-4 | 2.88 ms ± 206.99 µs | 2.62 ms … 3.32 ms | 10 × 34 |
| JSON encoding records-499-4 | 27.11 ms ± 2.20 ms | 24.95 ms … 32.13 ms | 10 × 4 |
| canonical encoding records-499-4 | 8.15 ms ± 332.29 µs | 7.72 ms … 8.67 ms | 10 × 13 |
| fence validation records-499-4 | 36.74 ms ± 2.81 ms | 33.50 ms … 40.64 ms | 10 × 3 |
| post-commit full export records-499-4 | 2.12 ms ± 175.65 µs | 1.88 ms … 2.35 ms | 10 × 44 |
| post-commit JSON encoding records-499-4 | 28.72 ms ± 1.75 ms | 26.56 ms … 31.46 ms | 10 × 4 |
| post-commit canonical encoding records-499-4 | 9.27 ms ± 514.04 µs | 8.65 ms … 10.53 ms | 10 × 11 |

Each harness row isolates the named call with setup outside the timed closure. Full prepare is a composite measurement that includes fence capture, lowering, successor construction, and both encodings; the isolated rows are not additive attribution.

## Commit-only and direct-local (manual timer, 10 samples, 499-record fixture)

Custom `println`-based timer in the benchmark test (not harness-aggregated). 3 warmup calls before recorded samples.

**JS — commit-only (µs):** 63788.60, 67982.56, 68320.82, 69464.16, 70794.49, 70796.22, 71276.66, 81937.01, 86684.04, 107593.50
**JS — direct-local (µs):** 338.04, 377.77, 387.24, 396.89, 413.32, 449.00, 556.75, 583.02, 588.38, 650.39

| stage | target | median | range |
|---|---|---:|---|
| commit-only | JS | **70.795 ms** | 63.789 ms … 107.593 ms |
| direct-local | JS | **0.431 ms** | 338.04 µs … 650.39 µs |
| commit-only | wasm-gc | **43.753 ms** | 37.761 ms … 57.873 ms |
| direct-local | wasm-gc | **0.451 ms** | 411.83 µs … 614.92 µs |

The commit clock surrounds only `PreparedLocalMutation::commit` on fresh state. That call performs exact fence validation and applies four prepared records. The directional baseline runs the equivalent create-plus-three-properties sequence through current public mutation methods inside one `Document::transaction`, using the same fixture identity and shape. The medians differ by about 164× on JS and 97× on wasm-gc; no acceptance threshold is inferred from those ratios.

## Ops scaling — latency (detached lowering + full prepare)

### JS target

| ops | detached lowering | full prepare |
|---:|---|---|
| 1 | 737.32 ns ± 11.49 ns | 64.11 µs ± 8.14 µs |
| 4 | 1.18 µs ± 18.51 ns | 113.76 µs ± 6.91 µs |
| 16 | 4.38 µs ± 68.08 ns | 346.91 µs ± 23.60 µs |
| 64 | 17.87 µs ± 661.71 ns | 1.28 ms ± 135.10 µs |

### wasm-gc target

| ops | detached lowering | full prepare |
|---:|---|---|
| 1 | 617.05 ns ± 89.09 ns | 28.19 µs ± 487.01 ns |
| 4 | 813.56 ns ± 17.40 ns | 57.42 µs ± 1.14 µs |
| 16 | 2.04 µs ± 172.61 ns | 194.12 µs ± 28.15 µs |
| 64 | 7.17 µs ± 226.81 ns | 656.56 µs ± 11.32 µs |

Detached lowering remains small and grows approximately with batch size in these empty-history fixtures. Full prepare additionally pays history-dependent fence and serialization costs.

## Memory — method

For each scenario and target, **5 isolated child processes** measure peak RSS via GNU `time` at each of four lifecycle stages:

1. **baseline** — empty test runner; no `Document`
2. **fixture** — `Document` constructed with all records/operations, no prepare
3. **prepare** — fixture plus `prepare_tree_property_append`, with the capability retained through test completion
4. **commit** — fixture plus prepare plus `commit`; this is the complete prepare+commit child lifecycle

Each stage is an independent child process. Median RSS reported per stage.

**Limitations:** Exact retained object/heap size is **unsupported** — RSS includes runtime heap, GC metadata, mapped memory, and allocator overhead. The baseline-adjusted and fixture-delta values below are **attribution aids, not object sizes**. Independent child median differences are not causal measurements; they indicate order-of-magnitude cost allocation only. Commit-lifecycle RSS is **not** commit-only memory — it includes the full fixture, prepare artifacts, and all committed state.

## JS target — memory (KiB, 5 child processes per stage)

| scenario | stage | median RSS | baseline-adjusted | fixture-delta |
|---|---|---:|---:|---:|
| empty-4 | fixture | 57460 | 332 | — |
| empty-4 | prepare | 58464 | 1336 | 1004 |
| empty-4 | commit | 58728 | 1600 | 1268 |
| records-128-4 | fixture | 73712 | 16376 | — |
| records-128-4 | prepare | 102180 | 44844 | 28468 |
| records-128-4 | commit | 110072 | 52736 | 36360 |
| records-499-4 | fixture | 87320 | 30084 | — |
| records-499-4 | prepare | **190060** | **132824** | 102740 |
| records-499-4 | commit | **240172** | **182936** | 152852 |

## wasm-gc target — memory (KiB, 5 child processes per stage)

| scenario | stage | median RSS | baseline-adjusted | fixture-delta |
|---|---|---:|---:|---:|
| empty-4 | fixture | 23260 | 268 | — |
| empty-4 | prepare | 25528 | 2536 | 2268 |
| empty-4 | commit | 25692 | 2700 | 2432 |
| records-128-4 | fixture | 36772 | 13704 | — |
| records-128-4 | prepare | 46972 | 23904 | 10200 |
| records-128-4 | commit | 55144 | 32076 | 18372 |
| records-499-4 | fixture | 46288 | 23192 | — |
| records-499-4 | prepare | **85352** | **62256** | 39064 |
| records-499-4 | commit | **93024** | **69928** | 46736 |

**499-record peak:** prepare lifecycle baseline-adjusted **132824 KiB JS / 62256 KiB wasm-gc**; prepare+commit lifecycle **182936 KiB JS / 69928 KiB wasm-gc**.

## Ops scaling — memory (baseline-adjusted, KiB)

### JS target

| scenario | fixture | prepare | commit |
|---|---:|---:|---:|
| ops-1 | 392 | 944 | 1064 |
| ops-4 | 312 | 1136 | 1608 |
| ops-16 | 484 | 3684 | 9856 |
| ops-64 | 212 | 11124 | 12372 |

### wasm-gc target

| scenario | fixture | prepare | commit |
|---|---:|---:|---:|
| ops-1 | 228 | 2424 | 2364 |
| ops-4 | 200 | 2388 | 2488 |
| ops-16 | 288 | 2688 | 3712 |
| ops-64 | 208 | 7480 | 7852 |

## Logical encoded-payload lower bounds (bytes)

This is the sum of four exact lengths logically retained by the capability: successor JSON UTF-8 bytes, fence JSON UTF-8 bytes, successor canonical bytes, and fence canonical bytes. It is a lower bound on the capability's encoded payload content because it excludes operation records, container/object overhead, and runtime string representation. It is **not** a wire-size or heap-object-size measurement.

| scenario | successor JSON | fence JSON | successor canonical | fence canonical | lower bound |
|---|---:|---:|---:|---:|---:|
| empty-4 | 1752 | 357 | 619 | 120 | 2848 |
| records-128-4 | 201502 | 199973 | 83486 | 82869 | 567830 |
| records-499-4 | 785861 | 784320 | 326491 | 325874 | **2222546** |
| ops-1 | 731 | 351 | 237 | 114 | 1433 |
| ops-4 | 1712 | 351 | 579 | 114 | 2756 |
| ops-16 | 5736 | 354 | 2027 | 117 | 8234 |
| ops-64 | 21864 | 354 | 7787 | 117 | 30122 |

## Interpretation

1. **Detached lowering is ~0.2 ms** on both targets for the 499-record fixture — negligible relative to full prepare.
2. **Fence snapshot and serialization dominate** prepare cost: fence validation alone is 48.76 ms (JS) / 36.74 ms (wasm-gc), JSON encoding 27.10 ms / 27.11 ms, canonical encoding 14.69 ms / 8.15 ms.
3. **Commit-only median** is 70.795 ms (JS) vs 0.431 ms direct-local, and 43.753 ms (wasm-gc) vs 0.451 ms direct-local — the prepare/commit machinery adds ~100–160× over raw mutation.
4. **Memory at 499 records:** prepare lifecycle baseline-adjusted 132824 KiB (JS) / 62256 KiB (wasm-gc); prepare+commit lifecycle 182936 KiB (JS) / 69928 KiB (wasm-gc).
5. **Encoded-payload content lower bound:** records-499-4 logically retains 2222546 bytes across the four encoded representations. This is not a wire-size claim.
6. **Ops scaling:** detached lowering grows approximately with batch size and remains much smaller than history-dependent fence and serialization work.

## Comparability notes

- **Issue #101** used a 499-record / 2002-post-command reconstruction fixture with different measured calls and semantics. **Not directly comparable.**
- **2026-08-02 report** measured stage latency on the same fixture but lacked commit-only, direct-local, memory, and ops-scaling data. Superseded for cost characterization by this report; its correctness checkpoint remains valid historical evidence.

## What is NOT concluded

- **No optimization proposal.** This report characterizes cost; it does not prescribe changes.
- **No performance-threshold verdict.** Issue #107 defined no threshold. The final **GO / NO-GO** decision on Phase A requires a separate ADR or design review that establishes acceptance criteria and weighs these numbers against workload requirements.
- **No exact retained object/heap size.** Encoded-payload content and independent-process peak RSS are reported separately; neither gives exact object size.
- **No native/wasm latency or RSS data.** Those optional targets were not measured.
