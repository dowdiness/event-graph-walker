# Remote-admission preparation with retained stale ready entries

Date: 2026-07-27

Issue: [#87](https://github.com/dowdiness/event-graph-walker/issues/87)

Commit: `a216026dcc403b52beb00aebb8ce5869c5414e00`

## Method

The benchmark fixture in `internal/oplog/oplog_benchmark.mbt` constructs all
state through `RemoteAdmissionPlanner` lifecycle transitions. It retains two
live pending nodes (one ready and one unresolved), then registers and
acknowledges 511, 512, or 513 ready nodes. Each acknowledged node leaves one
stale order tombstone and one stale ready reference.

| State | Live pending | Live ready | Stale ready | Weighted stale | Ready queue | Policy result |
|---|---:|---:|---:|---:|---:|---|
| Below | 2 | 1 | 511 | 1022 | 512 | Retained |
| At | 2 | 1 | 512 | 1024 | 513 | Compacted |
| Above | 2 | 1 | 513 | 1026 | 514 | Compacted |
| After compaction | 2 | 1 | 0 | 0 | 1 | Retained |

Setup, policy compaction, retained-count assertions, and exact planned and
remaining identity comparisons run outside timing. Each timed closure performs
100 non-mutating `prepare` calls with either one ready incoming operation or one
unresolved incoming operation.

Five independent raw invocations per target ran all eight scenarios in one
process:

```sh
NEW_MOON_MOD=0 moon bench --release --target <wasm-gc|js> \
  -p dowdiness/event-graph-walker/internal/oplog \
  -f oplog_benchmark.mbt -i 5-13 --no-parallelize
```

Environment: WSL2 Linux 6.6.114.1, AMD Ryzen 7 6800H, Moon
`0.1.20260713`, moonc `v0.10.4+2cc641edf`, Node `v24.14.1`.

## Results

Values are the benchmark means from each raw invocation. The median is across
those five means. Durations are per `prepare` after dividing the timed x100
closure by 100.

| Target | State and input | Raw means (µs/prepare) | Median (µs/prepare) |
|---|---|---:|---:|
| wasm-gc | Below, ready | 89.2, 90.2, 72.2, 88.2, 86.8 | 88.2 |
| wasm-gc | Below, unresolved | 87.0, 85.7, 69.7, 86.5, 86.6 | 86.5 |
| wasm-gc | At, ready | 86.5, 88.0, 70.8, 85.3, 86.7 | 86.5 |
| wasm-gc | At, unresolved | 88.3, 86.8, 68.7, 92.2, 84.6 | 86.8 |
| wasm-gc | After, ready | 0.9258, 0.9215, 0.8867, 0.9709, 0.9210 | 0.9215 |
| wasm-gc | After, unresolved | 0.8162, 0.8364, 0.7897, 0.9007, 0.7905 | 0.8162 |
| wasm-gc | Above, ready | 85.8, 86.8, 68.5, 90.8, 87.9 | 86.8 |
| wasm-gc | Above, unresolved | 86.8, 90.4, 70.8, 87.7, 87.7 | 87.7 |
| JS | Below, ready | 83.5, 83.7, 85.7, 84.5, 83.8 | 83.8 |
| JS | Below, unresolved | 82.7, 86.9, 85.6, 83.0, 83.5 | 83.5 |
| JS | At, ready | 102.3, 82.7, 84.6, 85.2, 84.8 | 84.8 |
| JS | At, unresolved | 87.3, 85.0, 85.4, 86.9, 88.2 | 86.9 |
| JS | After, ready | 1.8991, 1.8336, 1.6243, 1.8233, 1.7973 | 1.8233 |
| JS | After, unresolved | 1.7718, 1.5780, 1.7052, 1.6486, 1.5074 | 1.6486 |
| JS | Above, ready | 92.0, 84.0, 82.0, 81.4, 82.4 | 82.4 |
| JS | Above, unresolved | 89.3, 82.8, 84.5, 81.0, 81.6 | 82.8 |

At the policy boundary, compaction reduces median preparation time by 93.9x
(ready) and 106.3x (unresolved) on wasm-gc, and by 46.5x and 52.7x on JS.

## GO/NO-GO gate

**GO recommended for a separate optimization investigation; no production
change was made here.** The hypothesized queue-length cost is reproducible on
both deployment targets. A retained below-threshold state costs about 84–88 µs
per small preparation, so 100 repeated preparations accumulate about 8.4–8.8
ms. Quiescent compaction removes the cost at the boundary, but the existing
policy does not neutralize repeated preparation while 511 stale ready entries
remain below that boundary.

## Separate optimization investigation

A temporary private snapshot helper was evaluated and then removed. It kept the
existing queue copy when the queue was clean, stale ready entries were less than
half of the queue, or scanning retained order would exceed twice the ready-queue
length. In the measured stale-dominated state it instead scanned canonical order
and constructed a local queue from only live ready nodes. Preparation remained
non-mutating; canonical membership, retained indexes, generation, lifecycle
compaction, and admission ordering were unchanged.

The core `PriorityQueue::iter`/`from_iter` route was rejected before prototyping:
mutable `iter()` delegates to `to_array()`, which sorts the complete retained
queue, and mutable `from_iter()` pushes every selected entry. That route would
not avoid the measured stale-queue work.

Five additional raw invocations per target used the same command and scenario
order as the baseline. Medians below compare the independent five-run sets on
the same machine and toolchain.

| Target | State and input | Baseline (µs/prepare) | Prototype (µs/prepare) | Change |
|---|---|---:|---:|---:|
| wasm-gc | Below, ready | 88.2 | 16.8 | -81.0% (5.25x) |
| wasm-gc | Below, unresolved | 86.5 | 16.4 | -81.0% (5.27x) |
| wasm-gc | At, ready | 86.5 | 16.6 | -80.8% (5.21x) |
| wasm-gc | At, unresolved | 86.8 | 16.3 | -81.2% (5.33x) |
| wasm-gc | After, ready | 0.9215 | 0.9347 | +1.4% |
| wasm-gc | After, unresolved | 0.8162 | 0.8500 | +4.1% |
| JS | Below, ready | 83.8 | 25.1 | -70.0% (3.34x) |
| JS | Below, unresolved | 83.5 | 24.8 | -70.3% (3.37x) |
| JS | At, ready | 84.8 | 24.7 | -70.9% (3.43x) |
| JS | At, unresolved | 86.9 | 24.3 | -72.0% (3.58x) |
| JS | After, ready | 1.8233 | 1.6366 | -10.2% |
| JS | After, unresolved | 1.6486 | 1.5865 | -3.8% |

Above-threshold medians improved by 81.0–81.1% on wasm-gc and 69.2–69.4% on
JS. Clean post-compaction differences are within the existing 20% noise gate;
the clean path still executes the original queue copy.

**Prototype result: viable, not yet a production recommendation.** It removes
most of the reproduced cost without shifting work into lifecycle compaction,
but still costs 16–25 µs per preparation and its selection heuristic needs a
mixed live-ready/stale-ready calibration matrix before production adoption. No
public API or Canopy gitlink change is part of this prototype. The production
helper is not present in the Phase 2 measurement patch.

## Phase 2: realistic lifecycle incidence

Production caller inspection found one prepare followed by one commit in every
Document and Branch remote-application entry point. That does not eliminate the
risk: below-threshold stale state survives each quiescent `maybe_compact` call
and can affect later deliveries.

The Phase 2 trace therefore uses only production `OpLog` transitions:

1. Admit one unresolved operation so one canonical pending node remains live.
2. Deliver an in-order dependency chain of 512 operations one at a time through
   `OpLog::apply_remote`.
3. Compare it with the same 512 single deliveries without pending membership.
4. Compare it with one `prepare_remote`/`commit_remote` batch containing the
   same 512 operations while the unresolved node remains pending.

Before timing, all three paths are checked to admit the same operation identity
sequence. The retained stream records 511 of 512 prepares starting with stale
ready entries, maximum stale ready 511, maximum weighted stale 1022, ready queue
length 511, one live pending node, and exactly one policy compaction after the
final delivery. Each caller transition still performs exactly one prepare.

Five raw runs per target used:

```sh
NEW_MOON_MOD=0 moon bench --release --target <wasm-gc|js> \
  -p dowdiness/event-graph-walker/internal/oplog \
  -f oplog_benchmark.mbt -i 13-16 --no-parallelize
```

Values are complete lifecycle durations for the 512-operation trace, including
the fresh mutable `OpLog` required by each timed iteration.

| Target | Lifecycle | Raw means (ms) | Median (ms) |
|---|---|---:|---:|
| wasm-gc | Single deliveries, no pending | 0.81295, 0.78435, 0.78998, 0.72470, 0.79361 | 0.78998 |
| wasm-gc | Single deliveries, one unresolved pending | 12.92, 10.36, 12.00, 11.42, 12.12 | 12.00 |
| wasm-gc | One batch, one unresolved pending | 1.28, 1.22, 1.24, 1.24, 1.24 | 1.24 |
| JS | Single deliveries, no pending | 1.03, 1.06, 1.00, 1.01, 0.97993 | 1.01 |
| JS | Single deliveries, one unresolved pending | 12.84, 12.92, 12.70, 12.72, 12.44 | 12.72 |
| JS | One batch, one unresolved pending | 1.95, 1.91, 1.80, 1.88, 2.12 | 1.91 |

The retained single-delivery stream is 15.19x slower than the no-pending control
on wasm-gc and 12.59x slower on JS, adding 11.21 ms and 11.71 ms respectively.
It is 9.68x slower than the matched batch on wasm-gc and 6.66x slower on JS.

**Phase 2 decision: material production-lifecycle regression confirmed.** The
existing policy bounds retained state and compacts at the final boundary, but it
does not neutralize cumulative cost during a realistic one-operation delivery
stream with one long-lived unresolved dependency. A production optimization is
now evidence-backed, but this measurement patch intentionally contains no
production change.

## Phase 3: mixed-state snapshot selection

`internal/oplog/remote_ready_snapshot_benchmark.mbt` compares two disposable
ready snapshots without changing production preparation:

- **copy:** copy the retained priority queue and discard stale entries while
  popping it, matching the existing queue phase.
- **rebuild:** scan canonical pending order, push only live ready nodes into a
  fresh priority queue, then pop it in compatibility order.

`S`, `L`, and `U` below mean stale ready entries, live ready nodes, and live
unresolved nodes. Every matrix state is built through production planner
registration and acknowledgement transitions. Exact live identity order is
compared outside timing. Each raw invocation runs every copy/rebuild pair in one
process; values are five-run medians in µs per 100 snapshots.

```sh
NEW_MOON_MOD=0 moon bench --release --target <wasm-gc|js> \
  -p dowdiness/event-graph-walker/internal/oplog \
  -f remote_ready_snapshot_benchmark.mbt --no-parallelize
```

| S | L | U | wasm copy | wasm rebuild | Change | JS copy | JS rebuild | Change |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | 1 | 1 | 8.72 | 19.36 | +122.0% | 6.48 | 14.86 | +129.3% |
| 64 | 1 | 1 | 385.26 | 224.90 | -41.6% | 382.39 | 272.62 | -28.7% |
| 64 | 3 | 1 | 307.72 | 229.40 | -25.5% | 408.54 | 307.34 | -24.8% |
| 64 | 4 | 1 | 311.89 | 242.46 | -22.3% | 425.70 | 329.74 | -22.5% |
| 64 | 16 | 1 | 442.34 | 376.00 | -15.0% | 506.60 | 461.53 | -8.9% |
| 256 | 1 | 1 | 1360.00 | 824.26 | -39.4% | 1520.00 | 1030.00 | -32.2% |
| 256 | 15 | 1 | 1340.00 | 962.07 | -28.2% | 1710.00 | 1350.00 | -21.1% |
| 256 | 16 | 1 | 1530.00 | 1030.00 | -32.7% | 1730.00 | 1350.00 | -22.0% |
| 256 | 64 | 1 | 1860.00 | 1620.00 | -12.9% | 2060.00 | 1940.00 | -5.8% |
| 511 | 1 | 1 | 2850.00 | 1600.00 | -43.9% | 3150.00 | 2040.00 | -35.2% |
| 511 | 1 | 64 | 2950.00 | 2360.00 | -20.0% | 3290.00 | 2730.00 | -17.0% |
| 511 | 1 | 512 | 3280.00 | 5730.00 | +74.7% | 3390.00 | 5550.00 | +63.7% |
| 511 | 16 | 1 | 2820.00 | 1750.00 | -37.9% | 3420.00 | 2580.00 | -24.6% |
| 511 | 30 | 1 | 3440.00 | 2040.00 | -40.7% | 3430.00 | 2720.00 | -20.7% |
| 511 | 31 | 1 | 3510.00 | 2290.00 | -34.8% | 3440.00 | 2690.00 | -21.8% |
| 511 | 64 | 1 | 3100.00 | 2370.00 | -23.5% | 3820.00 | 3150.00 | -17.5% |
| 511 | 256 | 1 | 4460.00 | 4880.00 | +9.4% | 5260.00 | 5550.00 | +5.5% |
| 511 | 511 | 1 | 6560.00 | 8270.00 | +26.1% | 7260.00 | 8510.00 | +17.2% |

The results rule out unconditional rebuilding. Rebuilding is harmful for a
clean queue, many live ready nodes, or a long unresolved canonical order. The
following conservative selection rule chose only cells that improved by at
least 20% on both targets:

```text
live_pending > 0 && stale_ready_refs / live_pending >= 16
```

The matrix brackets this boundary at three scales: `64 / 4` versus `64 / 5`,
`256 / 16` versus `256 / 17`, and `511 / 31` versus `511 / 32`. Every selected
cell improves by at least 20% on both targets; rejecting some still-faster cells
is intentional. Production code should use division with non-negative counts
rather than unchecked multiplication. The explicit `live_pending > 0` guard is
required because the fast path can decline with no canonical pending membership
when an incoming operation itself is unresolved.

**Phase 3 decision: selection rule supported.** The next phase may reintroduce
the private live-ready snapshot behind this rule and validate the complete
Phase 2 lifecycle plus all retained Issue #86 planner/lifecycle gates. This
Phase 3 patch still contains no production change.

## Phase 4: conditional production snapshot

Production `prepare` now obtains its disposable ready queue through a private
snapshot method. It preserves `PriorityQueue::copy` unless the Phase 3 rule
selects canonical live-ready rebuilding. The rebuilt queue is local to the
preparation overlay; canonical membership, retained indexes, arrival ordinals,
and generation remain unchanged.

The complete Phase 2 lifecycle was rerun five times per target with the same
command and equivalence assertions. Values are full lifecycle means and their
five-run medians.

| Target | Lifecycle | Raw means (ms) | Median (ms) |
|---|---|---:|---:|
| wasm-gc | Single deliveries, no pending | 0.69023, 0.68214, 0.66836, 0.86751, 0.81640 | 0.69023 |
| wasm-gc | Single deliveries, one unresolved pending | 3.44, 3.57, 3.53, 4.52, 3.71 | 3.57 |
| wasm-gc | One batch, one unresolved pending | 1.19, 1.19, 1.22, 1.38, 1.21 | 1.21 |
| JS | Single deliveries, no pending | 1.21, 0.98145, 0.96616, 0.99716, 0.93770 | 0.98145 |
| JS | Single deliveries, one unresolved pending | 5.14, 5.25, 5.11, 5.80, 5.52 | 5.25 |
| JS | One batch, one unresolved pending | 1.92, 2.10, 1.95, 1.91, 2.16 | 1.95 |

Against the pre-optimization Phase 2 medians, the affected stream improves from
12.00 ms to 3.57 ms on wasm-gc (**70.25%**) and from 12.72 ms to 5.25 ms on JS
(**58.73%**). Excess over the matched no-pending control falls from 11.21 ms to
2.88 ms on wasm-gc and from 11.71 ms to 4.27 ms on JS. The clean stream cannot
select rebuilding because it has no live pending membership; the matched batch
has no retained stale-ready sweep to select.

**Phase 4 lifecycle decision: retain the conditional implementation.** It
materially reduces the confirmed production regression on both release targets
without changing admitted output. Semantic, full-suite, API-drift, and
independent-review gates were then run before finalizing the decision.

Phase 4 gates completed:

- `moon check --target all --deny-warn`
- `internal/oplog`: 99/99 tests
- full workspace: 811/811 tests
- release-mode retained/clean preparation gates: 8/8 on wasm-gc and 8/8 on JS
- `moon fmt` and `moon info`, with no `.mbti` drift
- independent MoonBit review: PASS with no findings
