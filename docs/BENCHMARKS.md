# Performance Benchmarks for eg-walker CRDT

This document describes the performance benchmarks for the eg-walker CRDT implementation and provides guidance for performance profiling and optimization.

## CRDT Core Performance Policy

This section defines the core performance policy for the Canopy CRDT core, drawing from our sequential text/tree history and the Issue #73 benchmark contexts.

### 1. Algorithmic Scalability as the Primary Metric
Performance is judged first and foremost as core algorithmic scalability (computational and memory complexity as a function of operation count), rather than client UI frame timing or browser rendering loops. While immediate frame budget indicators are valuable for integration context, they do not prove core scalability. A fast but poorly scaling core remains a defect.

### 2. Hot-Path Append Operations
Representative operations—specifically sequential text append and sibling/node append—must avoid avoidable full materialization, full document scans, or global sorting on their hot paths. All operations on the critical path must scale locally and incrementally.

### 3. Deployed and Comparison Targets
- **JavaScript (JS)** is the primary deployed target.
- **WebAssembly GC (wasm-gc)** is the comparison target.
All profiling, scaling checks, and performance regression reviews must be measured and compared on both targets.

### 4. Evidence-Based Optimization
Optimization begins from reproducible release-mode evidence. Developers must
remeasure 1k, 10k, and, where practical, 100k scales on JS and wasm-gc.

Two decision paths apply:

- **Pareto improvements** remove measured, local overhead without changing
  semantics, public APIs, wire formats, memory ownership, or another measured
  workload. Adopt them when both targets improve and correctness gates pass.
- **Workload trade-offs** move cost among insert, merge, memory, or query
  paths. They require an explicit workload assumption and a benchmark matrix
  covering the affected paths before adoption.

No cache, index, or complex data structure is selected without a confirmed
bottleneck and a prototype result.

### 5. Scalability Diagnostics
The 1k-to-10k `<=15x` ratio is a machine/noise diagnostic for operations
expected to scale near-linearly. It is not a universal SLO and must not reject
an intentional workload trade-off solely because its asymptotic cost differs.
Such trade-offs are evaluated against their declared workload matrix.

### 6. Supplementary Nature of Public-Operation Latency
Public-operation latency measurements (e.g., individual synchronous insert or create node operations on a pre-built document) are supplementary. While useful for verifying immediate responsiveness, they do not constitute proof of core scalability or linear growth characteristics across long histories.

## Post-v0.4 Performance Baselines

`container/performance_benchmark.mbt` defines release-mode baselines for:

- 1,000 and 10,000 sequential block-text operations;
- 1,000 and 10,000 sequential tree operations;
- 1,000 and 10,000 reverse-ordered causal batches; and
- a valid batch whose dependency remains permanently missing.

Run them with:

```bash
moon bench --release -p dowdiness/event-graph-walker/container
```

Deterministic comparison-count tests separately require 10,000 monotonic tree
history records and 10,000 reverse-ordered protocol records to remain linear
in ordering comparisons. Wall-clock benchmark noise therefore cannot hide an
ordering-complexity regression.

### PR #70 comparison

One controlled local comparison against the published v0.4.0 `main` measured:

| Scenario | v0.4.0 `main` | PR #70 | Change |
| --- | ---: | ---: | ---: |
| Sequential block text 1k | 80.82 ms | 67.20 ms | 16.9% faster |
| Sequential block text 10k | 12.81 s | 11.25 s | 12.2% faster |
| Sequential tree 1k | 55.93 ms | 54.93 ms | 1.8% faster |
| Sequential tree 10k | 6.92 s | 6.16 s | 11.0% faster |
| Reverse causal batch 1k | 36.34 ms | 31.12 ms | 14.4% faster |
| Reverse causal batch 10k | 824.35 ms | 419.74 ms | 49.1% faster |
| Permanently missing dependency | 17.76 µs | 15.75 µs | 11.3% faster |

The measurement used an AMD Ryzen 7 6800H under virtualization, Moon
0.1.20260713, moonc v0.10.4+2cc641edf, and the release-mode wasm-gc backend.
The small differences should be treated as directional rather than stable
cross-machine thresholds.

The remaining 1k-to-10k growth is about 167x for block text and 112x for tree
creation. [Issue #73](https://github.com/dowdiness/event-graph-walker/issues/73)
tracks isolated microbenchmarks for the suspected costs before selecting
another optimization.

### Issue #73 public-operation measurements

These benchmarks measure the public synchronous edit operations rather than
an isolated private lookup. Each timed closure performs one local append
against a prebuilt 10,000-operation document:

- `Document::insert_text` appends one character to a 10,000-character block;
- `Document::create_node` appends one node under the root after 10,000 root
  children (the feasible tree case).

Because `Document` has no copy API, each benchmark prepares a bounded pool of
four independently built 10,000-operation documents before `b.bench` and
rotates through them. The documents intentionally drift during a run. The
reported maximum is the largest number of added operations observed on any
one document, including benchmark warm-up and timed batches.

JS is the primary comparison; wasm-gc is included as a comparison backend.
Reproduce only these two benchmarks with:

```bash
# Primary: JS
moon bench --release --target js \
  -p dowdiness/event-graph-walker/container \
  -f 'performance_benchmark.mbt' -i 9-11

# Comparison: wasm-gc
moon bench --release --target wasm-gc \
  -p dowdiness/event-graph-walker/container \
  -f 'performance_benchmark.mbt' -i 9-11
```

Raw output from one run:

| Backend | Operation | Raw mean ± σ | Pool / max added per document | 16.7 ms diagnostic one-frame criterion |
| --- | --- | ---: | ---: | --- |
| js | `Document::insert_text` append | 2.41 ms ± 44.21 µs | 4 / 140 | below |
| js | `Document::create_node` root append | 2.43 ms ± 86.64 µs | 4 / 140 | below |
| wasm-gc | `Document::insert_text` append | 3.55 ms ± 43.57 µs | 4 / 86 | below |
| wasm-gc | `Document::create_node` root append | 2.70 ms ± 53.35 µs | 4 / 90 | below |

The 16.7 ms value is a diagnostic one-frame criterion for interpreting these
measurements, not a product SLO. These measurements make no attribution claim
about internal costs or end-to-end browser latency, and do not change
production behavior.

## Stage 2C direct FugueTree sequential insertion evidence

This section isolates the FugueTree Right-child insertion path at 1k, 10k, and
100k. Prebuilt `InsertOp[String]` values use direct local LVs,
`origin_left = previous LV`, and `origin_right = None`, making each item a
sequential Right child without TextBlock identity maps, cache work, or
interleaving.

Input setup is outside each timed closure. Each closure constructs a new
`FugueTree`, performs the sequential insertions, and calls `b.keep` on the
resulting visible count. No production code or cache semantics are changed by
these benchmarks.

Commands (run from `event-graph-walker/`) were:

```bash
moon bench --release --target js -p container \
  -f performance_benchmark.mbt -i 3-5 --no-parallelize
moon bench --release --target wasm-gc -p container \
  -f performance_benchmark.mbt -i 3-5 --no-parallelize
```

Raw release-mode output from one run:

| Backend | Component | 1k mean ± σ | 10k mean ± σ | 100k mean ± σ |
| --- | --- | ---: | ---: | ---: |
| js | FugueTree Right-child insert | 212.74 µs ± 32.74 µs | 2.73 ms ± 116.13 µs | 64.15 ms ± 4.38 ms |
| wasm-gc | FugueTree Right-child insert | 139.63 µs ± 2.89 µs | 2.58 ms ± 33.62 µs | 66.02 ms ± 4.33 ms |

Ratios computed from the raw means:

| Backend | Component | 1k→10k | 10k→100k | 1k→100k |
| --- | --- | ---: | ---: | ---: |
| js | FugueTree Right-child insert | 12.83x | 23.50x | 301.54x |
| wasm-gc | FugueTree Right-child insert | 18.48x | 25.59x | 472.82x |

These measurements are raw release-mode observations only and make no claim
about attribution or end-to-end browser latency.

## Ancestry representation decision matrix

The current eager ancestry index is the decision baseline. The benchmark
matrix lives in `internal/fugue/jump_ancestors_benchmark.mbt` and measures the
same deep Right-child chain at 1k, 10k, and 100k where practical:

| Workload | Timed work | Setup and query shape |
| --- | --- | --- |
| Sequential insert-only | Build a new chain and insert every item | Deep Right chain; this explicitly measures build/insertion |
| Midpoint concurrent insert | Insert one remote item | Chain is prebuilt outside timing; origins straddle the midpoint |
| Eager deep ancestry query | One ancestry check | Prebuilt-chain pool; varied pairs target the deepest descendant; jump rows are already built |
| Warm ancestry query | One ancestry check | One prebuilt chain; repeated samples rotate through varied pairs |
| Mixed insert + ancestry query | One midpoint insert plus six ancestry checks | Four prebuilt chains; each timed closure performs a small edit/query batch |

The query pairs include deep positive, reflexive, and reverse-direction checks.
The prebuilt pools keep setup outside the timed closures and bound mutable state
drift across benchmark samples. The sequential workload is the explicit
exception because chain construction is the operation being measured. Every
result is retained with `b.keep`.

JS is the primary deployed target; wasm-gc is the comparison target. Run the
focused release matrix from `event-graph-walker/` with:

```bash
moon bench --release --target js -p internal/fugue \
  -f jump_ancestors_benchmark.mbt --no-parallelize
moon bench --release --target wasm-gc -p internal/fugue \
  -f jump_ancestors_benchmark.mbt --no-parallelize
```

### Decision inputs before a prototype

This matrix establishes evidence; it does not itself authorize an
ancestry-representation change. Before a prototype is accepted, maintainers
must record workload-specific limits for:

1. required sequential-append improvement;
2. maximum regression for midpoint concurrent insertion;
3. maximum eager-query and, when a lazy design is proposed, true first-materialization query regression; and
4. maximum mixed insert-and-query regression.

Every candidate must also leave the Phase 1 parent-walk oracle and L5
properties green, and preserve the wire format and public API. The existing
1k-to-10k `<=15x` ratio remains a machine/noise diagnostic, not a substitute
for those workload limits.

### Raw baseline output and environment

Captured on 2026-07-22 at `16:45:14+09:00` in
`/home/antisatori/ghq/github.com/dowdiness/canopy/event-graph-walker` at
`703e740`.

Environment:

```text
Linux A6 6.6.114.1-microsoft-standard-WSL2 #1 SMP PREEMPT_DYNAMIC Dec 1 2025 x86_64
moon 0.1.20260713 (75c7e1f 2026-07-13)
moonc v0.10.4+2cc641edf (2026-07-15)
moonrun 0.1.20260713 (75c7e1f 2026-07-13)
targets: js, wasm-gc
```

Raw release output, JS primary:

```text
sequential Right chain 1k: 178.23 µs ± 15.01 µs
sequential Right chain 10k: 2.36 ms ± 25.71 µs
sequential Right chain 100k: 62.48 ms ± 6.05 ms
midpoint concurrent insert 1k: 881.29 ns ± 363.89 ns
midpoint concurrent insert 10k: 758.44 ns ± 227.39 ns
midpoint concurrent insert 100k: 1.03 µs ± 531.87 ns
eager deep query 1k: 51.44 ns ± 1.83 ns
eager deep query 10k: 57.61 ns ± 3.57 ns
eager deep query 100k: 71.34 ns ± 1.74 ns
warm varied query 1k: 34.42 ns ± 2.00 ns
warm varied query 10k: 50.59 ns ± 1.90 ns
warm varied query 100k: 66.69 ns ± 4.04 ns
mixed insert plus queries 1k: 984.59 ns ± 213.08 ns
mixed insert plus queries 10k: 1.39 µs ± 307.55 ns
mixed insert plus queries 100k: 1.32 µs ± 146.16 ns
Total tests: 15, passed: 15, failed: 0.
```

Raw release output, wasm-gc comparison:

```text
sequential Right chain 1k: 137.50 µs ± 2.16 µs
sequential Right chain 10k: 3.16 ms ± 288.01 µs
sequential Right chain 100k: 73.72 ms ± 5.96 ms
midpoint concurrent insert 1k: 699.12 ns ± 575.42 ns
midpoint concurrent insert 10k: 552.36 ns ± 348.15 ns
midpoint concurrent insert 100k: 788.53 ns ± 552.64 ns
eager deep query 1k: 48.03 ns ± 2.73 ns
eager deep query 10k: 60.43 ns ± 2.82 ns
eager deep query 100k: 79.26 ns ± 2.80 ns
warm varied query 1k: 41.18 ns ± 2.46 ns
warm varied query 10k: 52.91 ns ± 2.17 ns
warm varied query 100k: 59.42 ns ± 2.84 ns
mixed insert plus queries 1k: 1.01 µs ± 551.19 ns
mixed insert plus queries 10k: 1.09 µs ± 640.34 ns
mixed insert plus queries 100k: 1.20 µs ± 374.06 ns
Total tests: 15, passed: 15, failed: 0.
```

These are raw release observations, not cross-machine thresholds or an
attribution claim. Re-run both targets under comparable conditions before
using the matrix to select a representation.

## Fugue projection paired matrix runner

The accepted Fugue projection performance gate is persisted in
`scripts/run-fugue-projection-bench.py` and
`scripts/summarize-fugue-projection-bench.py`. The selector map is frozen at
B1–B5 and D1–D12, as defined in the implementation plan; do not substitute
benchmark names or indexes. The runner executes one Moon process at a time,
runs baseline first for odd pair numbers and candidate first for even pair
numbers, and writes every stdout/stderr sample plus elapsed seconds and peak
RSS under the explicitly supplied output directory.

From the Event Graph Walker worktree, run the initial ten-pair matrix on both
targets with no implicit worktree or temporary path:

```bash
python3 scripts/run-fugue-projection-bench.py \
  --baseline-worktree /path/to/baseline/event-graph-walker \
  --candidate-worktree /path/to/candidate/event-graph-walker \
  --output-dir /path/to/evidence/fugue-projection-$(date +%Y%m%d-%H%M%S)
```

Use `--target js` or `--target wasm-gc` to restrict targets and
`--selector B1` (repeatable) or `--selector js:D3` to restrict the initial
matrix. The summarized gate requires exactly 10 initial pairs. The runner
records the frozen map, commands, worktree revisions, environment, and
pre-run provenance in `run.json`. It resolves the exact `--moon` executable
and records its version and the actual Moon/moonc/moonrun toolchain. It also
captures the exact output of `<resolved moon executable> version --all`,
including feature flags, and fingerprints that output as part of provenance.
Provenance also includes the revision, SHA-256 of the exact `git diff HEAD --binary`,
staged status, SHA-256 values for every untracked `.mbt`/`.mbti`/Moon manifest,
lock hashes, host, CPU, memory, frequency policy, and time. The persisted
environment is a strict non-sensitive reproducibility allowlist; secrets,
full environment values, and full-environment hashes are never recorded.

If the first ten-pair summary is inconclusive, extend only the named
`target:key` selectors. The extension range is exactly 11–15:

```bash
python3 scripts/run-fugue-projection-bench.py \
  --baseline-worktree /path/to/baseline/event-graph-walker \
  --candidate-worktree /path/to/candidate/event-graph-walker \
  --output-dir /path/to/evidence/fugue-projection-YYYYMMDD-HHMMSS \
  --extension-selector js:D3 \
  --extension-selector wasm-gc:D2 \
  --pair-range 11-15
```

The extension invocation must use an exact `target:key` selector whose
baseline and candidate expected and completed inventories each contain pairs
1–10. Before changing `run.json` or launching any benchmark process, the runner
invokes the summarizer's authorization mode for every selector:

```bash
python3 scripts/summarize-fugue-projection-bench.py \
  --input-dir /path/to/evidence/fugue-projection-YYYYMMDD-HHMMSS \
  --authorize-extension js:D3
```

Authorization succeeds only when that exact selector's first-ten result is
`INCONCLUSIVE`—the two five-pair block verdicts disagree. An initial `PASS` or
`FAIL` is never eligible for extension. The extension must use
`--pair-range 11-15` exactly and `--pair-count 10`; the initial runner also
rejects every other `--pair-count`, so every generated run is summarizable.
It must reuse the original worktrees, targets, and noise controls, and match
the original pre-run provenance. Every benchmark invocation is checked against
that original provenance. It appends to the existing `run.json`; it does not
overwrite or delete logs. Preview either invocation with `--dry-run`.

Noise controls are explicit and recorded: `--cpu-affinity 2-3` requests a
fail-fast child CPU affinity; `--load-average-max 2.0` waits for the one-minute
load average with `--load-average-timeout` and `--load-average-poll`; and
`--cooldown-seconds 2` inserts a delay between processes. Without these flags,
the selected policy is still recorded as not requested. A requested control
that cannot be honored aborts rather than silently weakening the experiment.
There is no outlier deletion: raw samples and failed-process logs remain in the
output directory. A wide baseline tolerance is evidence of an unstable host,
not permission to ignore a regression.

Summarize to an explicit Markdown path:

```bash
python3 scripts/summarize-fugue-projection-bench.py \
  --input-dir /path/to/evidence/fugue-projection-YYYYMMDD-HHMMSS \
  --output /path/to/evidence/fugue-projection-YYYYMMDD-HHMMSS/summary.md
```

The summarizer parses every required `.time` file, validates elapsed/RSS
format, and requires those values to agree with each sample's metadata. It
validates the complete baseline/candidate pair inventory and rejects malformed,
missing, or extra extension logs. It accepts Moon JSON
median values and displayed values with units, normalizes to microseconds,
computes the symmetric paired log-ratio median, and reports the first-ten
baseline central-80% radius with `max(5%, spread)` tolerance. It reports both
five-pair block diagnostics; disagreeing block verdicts are `INCONCLUSIVE`.
A 15-pair inventory is rejected unless its first-ten block verdicts disagree,
so extension samples cannot convert an initial `PASS` or `FAIL`. A valid
15-pair extension is classified by its pooled estimate against the unchanged
first-ten tolerance. The command exits nonzero for `FAIL` or
`INCONCLUSIVE` (and also for malformed input).

Run the stdlib-only tooling tests with:

```bash
python3 -m unittest scripts/test_fugue_projection_bench.py
```

Rerun this complete paired matrix after any MoonBit compiler, runtime, or
`moonrun` update. `#inline` behavior and cross-package code generation are
evidence-sensitive, so old timing evidence is not portable across toolchain
changes. Keep the same declared controls when comparing runs and interpret
large tolerances as a host-stability finding requiring better controls or a
repeat—not as a reason to waive a regression.

## Running Benchmarks

```bash
# Run all benchmarks
moon bench --release

# Run benchmarks for specific package
moon bench --package internal/causal_graph --release
moon bench --package internal/branch --release
moon bench --package internal/oplog --release
# Merge benchmarks live in the branch package (see section 4 below)

# Run specific benchmark test
moon bench --package internal/causal_graph --release -f "walker - linear history"
```

**Important**: Always use `--release` flag for accurate performance measurements!

## Benchmark Categories

### 1. Walker Performance (`internal/causal_graph/walker_benchmark.mbt`)

Tests the event graph walker's ability to traverse operations in topological order.

**Benchmarks:**
- **Linear history**: 10, 100, 1000, 10000 operations
  - *Purpose*: Baseline performance for sequential edits
  - *Optimization target*: Should scale linearly O(n)

- **Concurrent branches**: 2 agents × 50 ops, 5 agents × 20 ops
  - *Purpose*: Multi-agent collaboration performance
  - *Optimization target*: Should handle concurrent branches efficiently

- **Diamond pattern**: 50 merges
  - *Purpose*: Frequent merge performance (common in real-time collaboration)
  - *Optimization target*: Efficient merge point detection

- **Diff operations**: Advance-only, concurrent branches
  - *Purpose*: Incremental sync performance
  - *Optimization target*: Fast diff computation for network sync

**Key Metrics:**
- Throughput: operations/second for walker traversal
- Scalability: performance with increasing operation count
- Merge overhead: cost of handling concurrent branches

**Optimization Opportunities:**
- [ ] Cache topological sort results
- [ ] Incremental diff computation
- [ ] Batch operation processing
- [ ] Parallel walking of independent branches

### 2. Branch Performance (`internal/branch/branch_benchmark.mbt`)

Tests branch checkout and advance operations for document state reconstruction.

**Benchmarks:**
- **Checkout**: 10, 100, 1000 operations
  - *Purpose*: Full document reconstruction performance
  - *Optimization target*: Fast initial load

- **Advance**: 10, 100 new operations
  - *Purpose*: Incremental update performance (critical for real-time editing)
  - *Optimization target*: Should be much faster than full checkout

- **Concurrent branches**: 2 agents concurrent edits
  - *Purpose*: Merge performance
  - *Optimization target*: Efficient handling of conflicts

- **With deletes**: 50% delete rate
  - *Purpose*: Performance with tombstones
  - *Optimization target*: Efficient tombstone handling

- **Repeated advance**: 10 iterations (simulates real-time editing)
  - *Purpose*: Real-world usage pattern
  - *Optimization target*: Consistent performance across iterations

- **to_text conversion**: 100, 1000 characters
  - *Purpose*: Text extraction performance
  - *Optimization target*: Fast UI updates

**Key Metrics:**
- Checkout latency: time to reconstruct document at frontier
- Advance speedup: advance vs full checkout performance ratio
- Text conversion throughput: characters/second

**Optimization Opportunities:**
- [x] Incremental advance (already implemented)
- [ ] Delta encoding for advance
- [ ] Lazy text materialization
- [ ] Character buffer pooling
- [ ] Parallel operation application

### 3. Version Vector Performance (`internal/causal_graph/version_vector_benchmark.mbt`)

Tests version vector operations for efficient frontier representation.

**Benchmarks:**
- **Creation**: 1, 5, 20 agents
  - *Purpose*: Version vector construction cost
  - *Optimization target*: Fast initialization

- **Comparison**: ==, <=, concurrent checks (5, 20 agents)
  - *Purpose*: Network sync decision performance
  - *Optimization target*: O(agents) comparison

- **Merge**: 5, 20 agents
  - *Purpose*: Version vector union performance
  - *Optimization target*: Fast merge for network sync

- **Conversion**: from_frontier, to_frontier, roundtrip
  - *Purpose*: Frontier ↔ version vector conversion cost
  - *Optimization target*: Minimize conversion overhead

- **Includes**: Frequent checks
  - *Purpose*: Operation coverage checks
  - *Optimization target*: O(1) or O(log n) lookup

**Key Metrics:**
- Comparison speed: comparisons/second
- Merge overhead: cost vs naive frontier merge
- Conversion latency: time to convert frontier ↔ version vector

**Optimization Opportunities:**
- [x] Operator overloading for comparisons (already implemented)
- [ ] Sparse representation for many agents
- [ ] Bloom filters for quick includes checks
- [ ] Cached frontier conversions

### 4. Merge Performance (`internal/branch/branch_merge_benchmark.mbt`)

Tests the three-phase retreat-advance-apply merge algorithm.

**Benchmarks:**
- **Concurrent edits**: 2 agents × 10/50/200 ops
  - *Purpose*: Multi-peer collaboration performance
  - *Optimization target*: Fast conflict resolution

- **Many agents**: 5 agents × 20 ops
  - *Purpose*: Scalability with peer count
  - *Optimization target*: Efficient multi-way merge

- **With deletes**: 50 inserts, 25 deletes
  - *Purpose*: Delete operation cost
  - *Optimization target*: Efficient tombstone handling

- **Graph diff merge**: Advance 20 ops
  - *Purpose*: Incremental merge using diff
  - *Optimization target*: Fast forward merge

- **Repeated small merges**: 10 iterations × 5 ops
  - *Purpose*: Real-time collaboration simulation
  - *Optimization target*: Low latency per merge

- **Context operations**: Apply 50 ops
  - *Purpose*: Operation application overhead
  - *Optimization target*: Batch processing efficiency

**Key Metrics:**
- Merge latency: time to merge remote operations
- Throughput: operations merged/second
- Scalability: performance with agent count

**Optimization Opportunities:**
- [ ] Parallel operation application
- [ ] Operation batching
- [ ] Delta compression for network
- [ ] Lazy conflict resolution
- [ ] Smart retreat (avoid unnecessary undo)

### 5. OpLog Performance (`internal/oplog/oplog_benchmark.mbt`)

Tests operation log storage and retrieval performance.

**Benchmarks:**
- **Insert**: 100, 1000, 500 sequential ops
  - *Purpose*: Write throughput
  - *Optimization target*: Fast append-only storage

- **Insert/delete mix**: 50% delete rate
  - *Purpose*: Mixed workload performance
  - *Optimization target*: Efficient delete handling

- **apply_remote**: 50 ops
  - *Purpose*: Network operation ingestion
  - *Optimization target*: Fast remote merge

- **get_op**: Random access from 1000 ops
  - *Purpose*: Lookup performance
  - *Optimization target*: O(1) or O(log n) access

- **get_frontier**: Single agent, 5 agents
  - *Purpose*: Version tracking overhead
  - *Optimization target*: Fast frontier computation

- **walk_and_collect**: 100 ops, concurrent branches
  - *Purpose*: Operation collection for replay
  - *Optimization target*: Efficient traversal

- **diff_and_collect**: Advance 20 ops
  - *Purpose*: Incremental sync
  - *Optimization target*: Fast diff computation

- **walk_filtered**: Filter inserts only
  - *Purpose*: Selective operation replay
  - *Optimization target*: Efficient filtering

- **Random position inserts**: 100 ops
  - *Purpose*: Non-sequential editing
  - *Optimization target*: Maintain fast insert regardless of position

**Key Metrics:**
- Insert throughput: operations/second
- Lookup latency: time to retrieve operation by LV
- Walk throughput: operations traversed/second

**Optimization Opportunities:**
- [ ] Index by agent + sequence for fast lookup
- [ ] Compressed operation storage
- [ ] Memory-mapped oplog for large documents
- [ ] Operation pooling/reuse
- [ ] Lazy operation materialization

### 6. Frontier Canonicalization Performance (`internal/core/frontier_benchmark.mbt`)

Tests frontier deduplication and normalization during canonicalization.

**Production Strategy:**
- **Fast paths**: Empty arrays and singletons return fresh owned storage without a deduplication scan or `HashSet` allocation.
- **Canonical path**: All larger inputs use a preallocated `@hashset.HashSet` with capacity matching the input length. This avoids backend-sensitive crossover tuning, provides expected linear-time canonicalization, and preserves first-occurrence order.
- **Graph advance**: Updating an existing canonical frontier filters consumed parents and checks the new version directly, preserving the invariant without canonicalizing the complete result again.

**Benchmark Matrix:**
- **Unique elements**: Evaluates sizes 5, 20, 50, 100, and 500.
- **Duplicate-heavy inputs**: Tests 5 elements and 100 elements cycling modulo 8.
- **Linear references**: Retains an intentionally quadratic reference implementation to expose the small-input allocation tradeoff and large-input scaling difference.
- **Graph advance**: Compares invariant-preserving `advance` against rebuilding and recanonicalizing a five-tip frontier.

**Reproducible Commands:**
```bash
# Target wasm-gc
moon bench internal/core/frontier_benchmark.mbt --release --target wasm-gc

# Target JS
moon bench internal/core/frontier_benchmark.mbt --release --target js
```

## Expected Performance Characteristics

### Scalability Targets

| Component | Small (≤100 ops) | Medium (≤1000 ops) | Large (≤10000 ops) |
|-----------|------------------|--------------------|--------------------|
| Walker | < 1ms | < 10ms | < 100ms |
| Checkout | < 5ms | < 50ms | < 500ms |
| Advance (10 ops) | < 1ms | < 1ms | < 2ms |
| Merge (2 agents) | < 2ms | < 20ms | < 200ms |
| Version Vector Compare | < 0.01ms | < 0.01ms | < 0.01ms |

### Memory Usage Targets

| Component | Per Operation | Per Agent | Notes |
|-----------|---------------|-----------|-------|
| OpLog Entry | ~64 bytes | - | Operation + metadata |
| CausalGraph Entry | ~48 bytes | - | Parents + timestamp |
| FugueTree Node | ~80 bytes | - | Character + tree pointers |
| VersionVector | - | ~40 bytes | Agent ID + sequence |

## Performance Profiling Guide

### 1. Identify Bottlenecks

```bash
# Run benchmarks with detailed output
moon bench --release > benchmark_results.txt

# Look for slow operations (> 10ms for small documents)
grep -A 2 "time:" benchmark_results.txt | grep -E "ms|s"
```

### 2. Profile Specific Operations

Use `moon bench --release` with a focused `*_benchmark.mbt` file rather than ad-hoc
timing — the bench harness handles warmup, iteration count, and statistical reporting.
See existing files like `internal/causal_graph/walker_benchmark.mbt` for the pattern.

### 3. Memory Profiling

```bash
# Build with debug symbols
moon build --debug

# Profile with system tools
# valgrind, heaptrack, or platform-specific memory profilers
```

### 4. Benchmark Regressions

```bash
# Run benchmarks before changes
moon bench --release > before.txt

# Make changes...

# Run benchmarks after changes
moon bench --release > after.txt

# Compare results
diff before.txt after.txt
```

## Future Optimization Roadmap

### Phase 1: Low-Hanging Fruit (Current)
- [x] Version vectors for frontier compression
- [x] Incremental branch advance
- [ ] Operation batching in merge
- [ ] Cached topological sorts

### Phase 2: Algorithmic Improvements
- [ ] Delta encoding for network sync
- [ ] Parallel operation application
- [ ] Lazy conflict resolution
- [ ] Smart retreat algorithm

### Phase 3: Data Structure Optimizations
- [ ] Compressed operation storage
- [ ] Memory-mapped oplog for large documents
- [ ] Sparse version vectors
- [ ] Bloom filters for includes checks

### Phase 4: Advanced Optimizations
- [ ] Incremental diff computation
- [ ] SIMD for batch operations
- [ ] Lock-free concurrent data structures
- [ ] GPU acceleration for large merges

## Benchmark Interpretation

### Good Performance Indicators
- ✅ Linear scaling with operation count (O(n))
- ✅ Sub-millisecond version vector comparisons
- ✅ Advance 10x faster than full checkout
- ✅ Constant-time frontier lookups
- ✅ Merge time proportional to delta size, not document size

### Performance Red Flags
- ⚠️ Quadratic scaling (O(n²))
- ⚠️ Merge time proportional to total document size
- ⚠️ Memory growth beyond expected operation count
- ⚠️ Slow version vector operations (> 1ms)
- ⚠️ Checkout slower than 100 ops/ms

## Contributing Benchmarks

When adding new features:

1. **Add benchmark** - Create test in appropriate `*_benchmark.mbt` file
2. **Baseline** - Record performance before optimization
3. **Optimize** - Implement improvements
4. **Validate** - Ensure performance improves without breaking tests
5. **Document** - Update this file with results and insights

**Benchmark Naming Convention:**
```moonbit
test "component - operation (size)" (b : @bench.T) {
  // e.g., "walker - linear history (1000 ops)"
}
```

## References

- [MoonBit Benchmark Documentation](https://docs.moonbitlang.com)
- [Eg-walker Paper](https://arxiv.org/abs/2409.14252) - Performance characteristics
- [Performance Testing Best Practices](https://github.com/moonbitlang/moonbit-docs)

---

**Last Updated**: 2026-07-22
**Total Benchmarks**: 130 across 14 project benchmark files (`container/{performance,sync_apply}_benchmark.mbt`, `internal/branch/{branch,branch_merge}_benchmark.mbt`, `internal/causal_graph/{walker,version_vector}_benchmark.mbt`, `internal/core/frontier_benchmark.mbt`, `internal/document/document_benchmark.mbt`, `internal/fugue/{jump_ancestors,tree_position}_benchmark.mbt`, `internal/oplog/oplog_benchmark.mbt`, `text/{text,position_cache}_benchmark.mbt`, `tree/json_size_benchmark.mbt`)
