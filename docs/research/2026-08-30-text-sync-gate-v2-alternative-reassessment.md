# EGW Text Sync Gate V2: Alternative Reassessment

Status: decision-ready research note  
Date: 2026-08-30

## Question

Is there a materially better way to complete Text Sync Gate V2 than the current
raw Quint model, Apalache verification, ITF export, and public MoonBit replay?

The decision criteria are:

1. detect partial, duplicate, reordered, and conflicting delivery bugs;
2. preserve an oracle independent from the MoonBit implementation;
3. compare through public schema-2 APIs without production hooks;
4. diagnose a failure as a small reproducible schedule;
5. avoid a second production implementation or a general verification
   framework;
6. remain native-only and outside normal CI;
7. remain maintainable by contributors who know MoonBit but are not formal
   methods specialists.

## Sources and method

This reassessment used primary source repositories, release metadata, current
EGW source, and local tool probes. The web-search provider was quota-limited, so
release facts were retrieved through the GitHub API and implementation facts
were checked in source clones rather than inferred from secondary articles.

Primary sources:

- Quint Connect README and source at
  [`quint-co/quint-connect@4f018f5`](https://github.com/quint-co/quint-connect/tree/4f018f54fc7dd4cef341d10111427bab59d3b307),
  especially
  [`connect/src/trace/generator/run.rs`](https://github.com/quint-co/quint-connect/blob/4f018f54fc7dd4cef341d10111427bab59d3b307/connect/src/trace/generator/run.rs).
- Automerge Model Checker at
  [`jeffa5/automerge-model-checker@9037b92`](https://github.com/jeffa5/automerge-model-checker/tree/9037b92fde7951e18c3949d45514b875c1c6160d).
- Stateright's
  [official repository](https://github.com/stateright/stateright) and README.
- CRDT-Redis MET at
  [`elem-azar-unis/CRDT-Redis@f8d18e0`](https://github.com/elem-azar-unis/CRDT-Redis/tree/f8d18e0a6202eba295a27bff1126555f9b81cd5f),
  especially [`MET/README.md`](https://github.com/elem-azar-unis/CRDT-Redis/blob/f8d18e0a6202eba295a27bff1126555f9b81cd5f/MET/README.md).
- Apalache
  [`v0.62.2`](https://github.com/apalache-mc/apalache/releases/tag/v0.62.2)
  release metadata and local execution.
- Mooncakes registry package
  `moonbit-community/quickcheck_statemachine@0.0.1`, whose published manifest
  has no repository URL.
- Current EGW implementation:
  [`tools/verification/text_sync_gate_v2/`](../../tools/verification/text_sync_gate_v2/),
  [`text/text_convergence_fuzz_test.mbt`](../../text/text_convergence_fuzz_test.mbt),
  [`text/text_properties_test.mbt`](../../text/text_properties_test.mbt), and
  [`tools/verification/text_reference/`](../../tools/verification/text_reference/).

## Important distinction discovered

Apalache exhaustively checks the **Quint model** within its bounds. It does not
execute the MoonBit implementation for every explored transition. The current
ITF replay executes named or sampled Quint traces through MoonBit. Therefore:

- model safety is bounded-exhaustive;
- implementation correspondence is trace-based;
- implementation delivery permutations are not bounded-exhaustive merely
  because the model was checked exhaustively.

This is not an error in the current design, but it is the highest-value remaining
assurance gap. A completion plan should close that gap without pretending that
Apalache can emit and replay every explored path.

## Candidate comparison

| Candidate | Main strength | Main cost or limitation | Decision |
|---|---|---|---|
| Raw Quint + Apalache + direct ITF replay | Independent semantic model, bounded safety, public implementation boundary | Replays named/sampled traces, not every Apalache path | Retain |
| Quint Connect | Packages Quint trace generation, action dispatch, state comparison, seed reproduction | Rust-only adapter; invokes experimental `quint run --mbt`; would wrap or reimplement the MoonBit driver | Reject for EGW |
| Stateright | Excellent unordered/lossy/duplicating network model, symmetry reduction, explorer UI | Embedded Rust model/runtime; cannot branch opaque mutable MoonBit state without a second implementation or process replay | Reject for EGW |
| Automerge Model Checker | Concrete CRDT precedent on Stateright; application/driver split | Automerge/Rust-oriented, low current activity, still requires a Rust-side EGW model and adapter | Reject for EGW |
| MET with TLA+/TLC | Systematically turns TLC states into implementation tests | Requires parsers, generated cases, and added observability; duplicates the existing Quint model and driver | Reject |
| TLC as a second backend | Independent checker implementation | Prior Canopy distributed-model probe cost about 500 seconds and 3.28 GiB; not evidence about this smaller model, but a warning for soup growth | Optional tiny-core cross-check only |
| `quickcheck_statemachine` | Pure model, generated command programs, sequential shrinking, replay and coverage labels | Version 0.0.1, no repository URL, new dependency; parallel root runner is deterministic and async parallel failures do not shrink | Do not make Gate V2 depend on it |
| Existing `moonbitlang/quickcheck` | Already used by EGW; good for larger random traces and shrinking | A second exact causal model in MoonBit would duplicate Quint and weaken oracle independence | Reuse only for focused properties if a measured gap remains |
| Independent TypeScript/Rust semantic oracle | Strong triangulation and shrinkable differential traces | A second complete protocol implementation, schema adapter, and long-term drift burden | Reject initially |
| Proof-oriented/extracted core | Highest possible theorem assurance | Tooling and proof ownership dominate this bounded verification task; public wire and projection correspondence remain separate | Reject |
| Coverage-certified Quint schedule catalog | Makes every canonical fixed-fixture delivery order produce model-derived prefix observations and a public MoonBit replay; no new dependency | Not a general model checker; fixture bounds and symmetry reductions must stay explicit | Add |

## Findings by alternative

### Quint Connect is not a better adapter here

Observed:

- Quint Connect `v0.1.1` targets Rust applications.
- Its `Driver` and `State` traits are implemented in Rust.
- Its run generator invokes `quint run --mbt`; Quint 0.32.0 labels `--mbt` as
  experimental.
- It provides seed reproduction and convenient diffs, but no documented trace
  shrinker.

For MoonBit, adopting it would require a Rust process adapter, C ABI, or a second
Rust implementation of the test driver. Direct ITF decoding in the existing
native MoonBit executable already provides the useful part without the extra
language boundary. Quint Connect validates the architecture pattern, but is not
an implementation dependency worth adding.

### Stateright and AMC solve a different integration problem

Observed:

- Stateright supports unordered, lossy, and duplicating network semantics,
  symmetry reduction, model checking, and an explorer UI.
- Its strongest claim applies when the Rust actor implementation can itself run
  under the model checker.
- AMC wraps Stateright with Automerge-specific application and driver traits.

EGW's mutable `TextState` is a MoonBit value with no public clone/snapshot API
for checker branching. A Stateright integration would therefore model EGW in
Rust and separately replay into MoonBit, recreating the same correspondence seam
with more code. It is not direct implementation model checking in this project.

### MET/TLA+ would duplicate the toolchain and model

Observed:

- CRDT-Redis MET model-checks a TLA+ design with TLC, writes final states, parses
  those states into cases, and adds implementation read operations for
  observability.
- The source explicitly asks implementations to add testability operations when
  needed.

Gate V2 already has Quint, ITF, public Version observations, and a MoonBit
replay driver. Replacing these with TLA+, output parsers, and MET drivers adds a
parallel model and conflicts with the no-white-box-hook boundary.

### MoonBit state-machine QuickCheck is promising but premature

Observed:

- `quickcheck_statemachine@0.0.1` supports pure models, preconditions,
  transitions, postconditions, generated command programs, sequential shrinking,
  replay, and required coverage labels.
- The published manifest has no source repository URL.
- The root parallel runner deterministically linearizes branches. The native
  async package performs linearizability search, but its parallel failures do
  not shrink and branch operations are bounded to six.

This library is a good future candidate for stateful MoonBit applications. It is
not the right foundation for Gate V2 now: network delivery is deliberately
controlled rather than concurrent, symbolic handle machinery is unnecessary,
and introducing a 0.0.1 dependency would replace a small explicit driver with a
large generic contract.

### A second full semantic oracle is not justified yet

An immutable TypeScript, Rust, or MoonBit reducer could generate and shrink
larger schedules while comparing exact admitted, pending, frontier, checkpoint,
and delta state. It would also duplicate nearly all of `TextSyncCore.qnt`.

The independent `reference-frh` oracle already owns visible text compatibility,
while Quint owns causal semantics. A third full causal implementation should be
added only after a concrete escaped defect demonstrates that mutation controls
and direct replay cannot expose a shared modeling error.

## Better architecture found

The reassessment and adversarial review found an improvement that is materially
better than simply expanding the current plan:

> Add a finite, coverage-certified schedule catalog to Quint. Generate ITF until
> every catalog entry has appeared, then replay every entry and every prefix
> through fresh public MoonBit `TextState` values.

This is a complement, not a replacement, for the unordered Quint soup. Unlike a
MoonBit-only permutation runner, expected prefix observations come from the
independent Quint reducer. It therefore extends model-to-implementation
correspondence rather than providing only implementation robustness.

### Refined assurance stack

1. **Pure Quint causal core**
   - exact operation equivalence;
   - declared dependencies only;
   - admitted/pending/frontier/knowledge/checkpoint/delta authority.
2. **Apalache bounded verification**
   - all six named obligations over the finite abstract state space.
3. **Coverage-certified Quint schedule catalog and ITF replay**
   - a finite set of canonical delivery schedules selected nondeterministically;
   - a stable `scheduleId` in every trace;
   - a fixed-seed, fixed-size simulation batch;
   - the runner rejects missing IDs rather than treating random sampling as
     exhaustive;
   - every model-derived prefix is replayed through public MoonBit APIs.
4. **Named checkpoint, delta, overclaim, and resource-boundary traces**
   - state-dependent sends remain explicit rather than being forced into the
     fixed-message schedule catalog.
5. **Existing Gate V0 and resource contracts**
   - independent visible-text oracle and wire bounds.

### Why the catalog improves the plan

- Apalache proves the abstract reducer for all bounded schedules, while catalog
  coverage ensures that each selected implementation schedule is actually
  replayed.
- Expected prefix observations remain model-derived; there is no MoonBit-only
  hand-written oracle.
- It needs no Rust adapter, new dependency, production hook, or generic state
  machine framework.
- A failing schedule is already a small counterexample, so a generic shrinker is
  unnecessary at the proposed bounds.
- It keeps Fugue ordering with Gate V0. Gate V0 already has substantial public
  reversed and duplicate delivery evidence; the catalog adds exhaustive
  canonical permutations for causal fixtures rather than claiming to introduce
  reordered delivery testing for the first time.

### Deliberate bounds and symmetry reduction

Start with fixed three-operation fixtures:

- root insert;
- declared child insert;
- concurrent root, or an insert/delete/undelete chain;
- at most one explicit equivalent duplicate in a separate catalog;
- two receiving replicas.

Three fixed messages have six orders at one receiver. Two independent receivers
have 36 order pairs. There are 720 raw interleavings of the six delivery events,
but events at different receivers commute while messages are fixed and no send
is generated from intermediate state. The 36 order pairs are therefore the
canonical equivalence classes. State-dependent `RequestDelta` and checkpoint
actions are excluded from this reduction and remain named traces.

The Quint schedule model owns the catalog and expected prefixes. `run.sh`
generates a recorded trace corpus, deduplicates by `scheduleId`, checks the
required ID set exactly, and passes all retained traces to the existing MoonBit
replay executable. Increase catalog size only after measuring Quint generation,
ITF size, replay runtime, and Apalache state growth.

A local feasibility probe used a Quint `Set` of six explicit schedule records,
nondeterministically selected one record during `init`, and emitted 100 ITF
traces with Quint 0.32.0. The recorded `scheduleId` values covered all six
permutations. Because supplying a seed changes Quint's default `--max-samples`
to one, the real runner must set `--max-samples` explicitly alongside
`--n-traces`. The gate still checks exact catalog coverage; the probe does not
turn probabilistic generation into a formal coverage claim.

## Apalache pin reassessment

Official release metadata shows Apalache `v0.62.2` was published on 2026-08-26.
The existing Gate V2 pin is `0.56.1`, which is also Quint 0.32.0's CLI default.

Local serial probes on the two current deterministic models produced:

| Model | Apalache | Java | elapsed | max RSS |
|---|---:|---:|---:|---:|
| sparse distributed | 0.56.1 | 17 | 11.47 s | 140,148 KiB |
| admission | 0.56.1 | 17 | 11.50 s | 137,136 KiB |
| sparse distributed | 0.62.2 | 21 | 9.51 s | 212,752 KiB |
| admission | 0.62.2 | 21 | 9.44 s | 208,212 KiB |

Observed caveats:

- Apalache 0.62.2 bytecode requires Java 21; Java 17 fails to load it.
- The local launcher uses a fixed server port, so two verification invocations
  run concurrently collided. Gate V2 already runs them serially.
- 0.62.2 emitted a protobuf generated-code warning that did not fail checking.

Decision: test 0.62.2/Java 21 against the completed soup model before changing
the pin. It was about 18% faster on these tiny models but used about 50% more
resident memory. The tiny staged models are not predictive enough to select a
checker solely from this result. Avoid migrating mid-model unless the completed
probe is green and the release pin is documented atomically.

## Revised implementation sequence

1. Preserve the current sparse and admission traces as regression baselines.
2. Replace duplicated scenario state updates with one pure Quint causal reducer.
3. Expand the event and operation shape to exact identity, parents, kind,
   content, and directional origins.
4. Add the implicit-sequence-parent mutation before expanding state space.
5. Add a bounded unordered Quint soup and all six named obligations.
6. Replay named traces and a recorded seeded simulation corpus through the
   public MoonBit executable.
7. Add the finite Quint schedule catalog, require exact `scheduleId` coverage,
   and replay every retained trace through public MoonBit APIs.
8. Add historical/multi-head checkpoint, fresh-peer delta, explicit overclaim,
   delete, and undelete traces.
9. Benchmark the completed model under Apalache 0.56.1/Java 17 and
   0.62.2/Java 21, then pin one pair.
10. Run Gate V0 and resource contracts.
11. Require a clean worktree for candidate evidence and record the exact commit,
    bounds, seeds, trace/permutation counts, states, runtime, and memory.
12. Run an independent model-to-public-observation review.

## Rejected additions

Do not add initially:

- a Rust Quint Connect adapter;
- Stateright or AMC;
- a second TLA+ model and MET parser;
- a new state-machine QuickCheck dependency;
- a full executable causal oracle in another language;
- a general trace normalization framework;
- production clone/snapshot/test hooks;
- TLC as a required backend;
- proof-assistant extraction.

Each can be reconsidered only after a measured failure of the refined stack,
not because it raises the theoretical assurance ceiling in isolation.

## Decision

A better plan was found, but it is an incremental refinement rather than a tool
replacement.

**Select the existing raw Quint + direct public replay architecture, amended
with a finite, coverage-certified Quint schedule catalog.**

This gives bounded exhaustive model safety, named and seeded correspondence,
and complete replay coverage of the catalog's canonical delivery-order classes.
It improves the strongest remaining blind spot without introducing another
semantic implementation or verification framework. It does not claim exhaustive
correspondence outside the explicitly recorded catalog.
