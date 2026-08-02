# Prepared local mutation — Phase A stage measurements

**Date:** 2026-08-02
**Issue:** #107
**Design:** ADR0006 (prepared local mutation)
**Scope:** Test-only Phase A model (`container/prepared_local_mutation_model_wbtest.mbt`).
No production API and no promoted wrapper. Any promotion requires a later accepted design decision; these numbers characterize a `wbtest`-only fixture.

## Fixture construction

`prepared_benchmark_fixture` builds a `Document`, creates one `parent` node under `root_id`, then appends `record_count` children each carrying three property sets (`record_type`, `entity_id`, `body`). One create + three property sets = **4 operations per record**.

Pre-command operation counts printed by the fixture:

| bench | records | pre-command operations |
|---|---:|---:|
| `empty` | 0 | 1 |
| `records-128` | 128 | 513 |
| `records-499` | 499 | 1997 |

The staged benchmarks (`successor message`, `JSON encoding`, `canonical encoding`, `fence validation`) reuse the 499-record / 1997-pre-command fixture and a prepared capability built against it.

## What "full prepare" measures

`benchmark_prepared_full_prepare` times one call to
`Document::prepare_tree_property_append(parent, [3 properties])`, which is
**not** an isolated stage. A single prepare invocation performs, in order:

1. rejection-rule checks (idle / sync-pending / text-pending / parent-available);
2. fence snapshot (`prepared_local_source_snapshot`) — full `export_all`, JSON,
   canonical bytes, counters;
3. `DetachedLocalWriter::from_document` — frontier, version vector, timestamp /
   lv / sequence derivation;
4. record construction (1 move + 3 `SetProperty`, each with cloned version,
   parents, undo item);
5. `prepared_local_successor_message` — deep clone of the source's existing tree
   and text ops plus the prepared records into a new `SyncMessage`;
6. `SyncMessage::to_json_string` and `to_canonical_bytes` for the successor
   evidence.

The stage benchmarks below isolate steps 5, 6, and a slice of step 2. The
"full prepare" value is therefore **characterisation of the composed call**,
not an additive attribution — do not sum the stage rows to reconstruct it.

## Correctness evidence

- 18 behavioral tests in `container/prepared_local_mutation_wbtest.mbt`, backed by the executable model in `container/prepared_local_mutation_model_wbtest.mbt`, on all four targets.
- Full suite: 837 tests, all four targets.
- `just ci` green.
- No `pkg.generated.mbti` drift (the model is `wbtest`-only; no public
  interface changes).

## Benchmark commands

```bash
moon bench --release --target js --frozen \
  container/prepared_local_mutation_benchmark_wbtest.mbt --no-parallelize
moon bench --release --target wasm-gc --frozen \
  container/prepared_local_mutation_benchmark_wbtest.mbt --no-parallelize
```

Each result reports 10 samples; the runs per sample are selected by the benchmark harness and shown in the tables.

## JS target

Source: `/tmp/egw-107-bench-js.log`.

| bench | fixture (records / pre-ops) | mean ± σ | range (min … max) | iterations × runs |
|---|---|---|---|---|
| `prepare empty` | 0 / 1 | 110.35 µs ± 7.80 µs | 102.67 µs … 123.73 µs | 10 × 813 |
| `prepare records-128` | 128 / 513 | 21.25 ms ± 2.87 ms | 19.23 ms … 28.34 ms | 10 × 4 |
| `prepare records-499` | 499 / 1997 | 90.33 ms ± 1.62 ms | 87.37 ms … 92.62 ms | 10 × 1 |
| `successor message` | 499 / 1997 | 3.59 ms ± 173.01 µs | 3.40 ms … 3.86 ms | 10 × 29 |
| `JSON encoding` | 499 / 1997 | 24.75 ms ± 1.22 ms | 23.31 ms … 26.63 ms | 10 × 4 |
| `canonical encoding` | 499 / 1997 | 15.97 ms ± 276.87 µs | 15.52 ms … 16.22 ms | 10 × 6 |
| `fence validation` | 499 / 1997 | 48.98 ms ± 1.34 ms | 47.30 ms … 50.92 ms | 10 × 2 |

## wasm-gc target

Source: `/tmp/egw-107-bench-wasm-gc.log`.

| bench | fixture (records / pre-ops) | mean ± σ | range (min … max) | iterations × runs |
|---|---|---|---|---|
| `prepare empty` | 0 / 1 | 64.66 µs ± 11.97 µs | 55.83 µs … 90.19 µs | 10 × 1523 |
| `prepare records-128` | 128 / 513 | 14.29 ms ± 329.81 µs | 13.85 ms … 14.89 ms | 10 × 7 |
| `prepare records-499` | 499 / 1997 | 79.27 ms ± 6.17 ms | 71.24 ms … 90.16 ms | 10 × 2 |
| `successor message` | 499 / 1997 | 3.59 ms ± 274.43 µs | 3.15 ms … 3.93 ms | 10 × 31 |
| `JSON encoding` | 499 / 1997 | 23.40 ms ± 1.40 ms | 21.68 ms … 25.90 ms | 10 × 5 |
| `canonical encoding` | 499 / 1997 | 7.46 ms ± 326.23 µs | 7.12 ms … 7.99 ms | 10 × 13 |
| `fence validation` | 499 / 1997 | 32.43 ms ± 1.55 ms | 30.79 ms … 34.83 ms | 10 × 4 |

## Comparison with Issue #101 reconstruction fixture

Issue #101's reconstruction measurement used a **499-record / 2002-post-command**
fixture (post-command count reflects the reconstruction's own committed ops plus
the baseline's prior history). This Phase A measurement uses a
**499-record / 1997-pre-command / 2001-operation prospective successor** fixture. The fixtures
are not directly comparable: different operation totals, different measured
calls, different semantics. Treat the two as independent characterizations.

## NOT YET MEASURED

The following are required before a GO / NO-GO verdict on Phase A is defensible:

- **Commit-only latency.** Time `PreparedLocalMutation::commit` in isolation on
  the 499 / 1997 fixture, split from the prepare call. Neither JS nor wasm-gc
  numbers exist yet.
- **Detached-lowering-only latency.** Time `DetachedLocalWriter::from_document`
  plus record construction without the successor/JSON/canonical stages. No
  measurements yet on either target.
- **Memory / RSS.** Peak resident set during full prepare and during commit on
  the 499 / 1997 fixture, both targets. No measurements yet.

## Verdict

**No GO verdict.** The staged measurements in this document characterise the
Phase A model but do not cover the commit hot path or memory behaviour. The
GO / NO-GO decision on Phase A is deferred until commit-only latency,
detached-lowering-only latency, and memory/RSS are measured, recorded in a
follow-up report, and reviewed alongside the numbers above.
