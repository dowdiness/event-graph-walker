# Issue #115 Gate 1 — bounded causal-cut identity prototype

## Question

Can the text module retain a frozen, payload-bound causal-cut identity that:

1. distinguishes independent histories with equal `Version` values and conflicting operation payloads;
2. remains unchanged when its owning document later advances;
3. compares equal for equivalent merged histories admitted in different orders; and
4. captures and compares without work proportional to total retained history?

This is throwaway Gate 1 evidence. It does not propose a stable API or authorize production promotion.

## Candidate

The prototype retains:

- the owning append-only `TextState`;
- the operation count at the cut; and
- an owning copy of the raw causal heads at the cut.

Capture does not copy operations. For the same owner, equality compares the cut metadata directly. Across different owners, exact equality reconstructs each retained prefix as a `SyncMessage` and compares canonical bytes. The fallback intentionally exposes the cost that an owner-bound token cannot solve.

The prototype lives in `text/issue_115_gate1_causal_cut_prototype_wbtest.mbt` and has no generated-interface effect; `moon info --frozen` produced no `.mbti` drift.

## Correctness matrix

| Case | Expected | Result |
|---|---|---|
| Same replica ID and sequence, payload `A` versus `B` | versions equal; cuts unequal | PASS |
| Retain cut, then append locally | retained cut still equals independent baseline | PASS |
| Retain cut, then admit a remote operation | retained cut still equals independent baseline | PASS |
| Fresh cut after local or remote advancement | differs from retained cut | PASS |
| Same concurrent operations admitted in opposite orders | text, versions, and cuts equal | PASS |

Targeted tests passed 4/4 on wasm, wasm-gc, JavaScript, and native. The complete text package passed 119/119 tests on all four targets.

## Static complexity

| Operation | Time | Allocation | Retention |
|---|---:|---:|---:|
| Capture cut | `O(frontier width)` | copied head array | owning document reference |
| Same-owner equality | `O(frontier width)` | none | none |
| Cross-owner exact equality | `O(total operations + payload)` plus canonical ordering/encoding | complete operation arrays, structural arrays, maps, buffers, bytes | temporary complete-history evidence |

The retained document reference keeps the complete append-only document alive. It is process-local and is not a durable identity across restart. The operation-count cut is frozen only because admitted operation history is append-only; it is not an independent persistence value.

## Release benchmark results

All timed fixtures use a linear history with frontier width 1 and one ASCII byte of inserted payload per operation. Setup runs outside the timed region.

### JavaScript

| Benchmark | Mean ± σ | Range |
|---|---:|---:|
| Capture, empty | 32.40 ns ± 1.30 ns | 31.31–34.97 ns |
| Capture, 1,000 ops | 55.59 ns ± 1.46 ns | 53.25–57.52 ns |
| Capture, 10,000 ops | 72.46 ns ± 4.23 ns | 66.49–80.05 ns |
| Capture, 100,000 ops | 70.03 ns ± 2.62 ns | 65.60–74.32 ns |
| Same-owner equality, 1,000 ops | 16.19 ns ± 2.26 ns | 14.74–22.16 ns |
| Same-owner equality, 100,000 ops | 16.92 ns ± 0.76 ns | 16.33–18.96 ns |
| Cross-owner equality, 1,000 ops | 21.44 ms ± 0.81 ms | 20.19–22.78 ms |
| Cross-owner equality, 10,000 ops | 272.96 ms ± 9.53 ms | 262.71–295.53 ms |

### wasm-gc

| Benchmark | Mean ± σ | Range |
|---|---:|---:|
| Capture, empty | 61.25 ns ± 3.26 ns | 57.27–66.08 ns |
| Capture, 1,000 ops | 75.37 ns ± 1.17 ns | 73.96–77.26 ns |
| Capture, 10,000 ops | 88.46 ns ± 4.55 ns | 82.13–94.62 ns |
| Capture, 100,000 ops | 88.31 ns ± 3.53 ns | 83.24–92.73 ns |
| Same-owner equality, 1,000 ops | 28.77 ns ± 1.11 ns | 27.57–30.39 ns |
| Same-owner equality, 100,000 ops | 28.81 ns ± 1.36 ns | 27.05–31.19 ns |
| Cross-owner equality, 1,000 ops | 7.07 ms ± 0.11 ms | 6.94–7.25 ms |
| Cross-owner equality, 10,000 ops | 114.55 ms ± 7.40 ms | 106.32–125.72 ms |

Capture and same-owner equality are independent of retained operation count for the linear, width-one fixture. Cross-owner exact equality grows with retained history and allocates complete-history proof artifacts. Exact allocation and retained-object size are unsupported by the current runtime seam; no allocation or peak-RSS value is claimed. The benchmark is characterization evidence, not a universal latency threshold.

## Existing API First

| Candidate | Covers | Reused? | Decision |
|---|---|---|---|
| `Version` | Bounded replica-sequence frontier | No | Equal values do not bind operation payload. |
| `CausalSnapshot::op_count` | Constant-time append-only cut position | Yes, prototype only | Helps freeze one owner prefix but does not identify its payload across owners. |
| Raw causal heads | Exact frontier at capture time | Yes, prototype only | Necessary cut metadata, insufficient history identity. |
| `SyncMessage` canonical bytes | Exact canonical-history oracle | Test/fallback only | Correct across owners but walks and allocates complete retained history. |
| `SyncSession::export_since` | Operation delta after a `Version` | No | Scans all retained operations and does not provide baseline identity. |
| Process-local owner identity | Same-runtime owner binding | Conceptually | Supports a fast same-owner path but is not causal-history identity or durable replay evidence. |
| Internal graph diff | Operation difference | No | Walks reachable history, is not a public text seam, and does not identify baseline payload. |

MoonBit core candidates checked:

- `Array` owns copied causal heads; copying complete operations would be linear.
- `ArrayView` avoids a prefix copy only while borrowing mutable owner storage and therefore does not create an independent frozen value.
- `Bytes`/`BytesView` and `Buffer` support canonical encoding but still process complete history.
- `Map` and `Set` are mutable; copying them per cut is linear, while retaining one would not freeze a cut.
- `Hash`/`Hasher` yields a finite `Int` fingerprint. It can be incremental but cannot provide the issue's exact collision semantics and is not a durable causal identity.
- `Option` and `Result` remain suitable for later outcome classification but do not solve identity.

## Gate 1 verdict

**STOP.**

A narrow owner-bound cut can be captured in bounded time and can remain frozen while that owner advances. It does not satisfy Issue #115's payload-bound replay requirement across independent owners or restored processes. The only existing exact cross-owner comparison available to the text façade reconstructs and canonically encodes complete retained history, which is the explicit Gate 1 stop condition.

Do not proceed to Gate 2 on this branch. Before exact accepted-delta work begins, EGW needs one of the following decisions:

1. a checkpoint-backed, structurally shared causal-cut value whose exact equality and restore semantics are defined by Issue #114; or
2. an accepted, explicitly probabilistic payload fingerprint contract with collision semantics strong enough for replay and acknowledgment.

The second option is a domain-contract change, not an implementation shortcut. MoonBit core `Hasher` is not sufficient evidence for it.

## Validation commands

```text
NEW_MOON_MOD=0 moon check text --target all --deny-warn
NEW_MOON_MOD=0 moon test text/issue_115_gate1_causal_cut_prototype_wbtest.mbt --target js -v
NEW_MOON_MOD=0 moon bench --release --target js --package dowdiness/event-graph-walker/text --file issue_115_gate1_causal_cut_prototype_wbtest.mbt
NEW_MOON_MOD=0 moon bench --release --target wasm-gc --package dowdiness/event-graph-walker/text --file issue_115_gate1_causal_cut_prototype_wbtest.mbt
```
