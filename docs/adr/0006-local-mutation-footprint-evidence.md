---
status: accepted
---

# Keep local mutation footprint evidence unavailable until it can prove fit

Event Graph Walker does not currently expose a production mechanism that can prove, before authoritative local mutation, how many canonical encoded bytes the resulting document will occupy. Do not fill that gap with reconstructed replicas, transaction-shaped dry runs, operation-count proxies, or heuristic constants. Full same-writer replay remains an unsupported, isolated characterization fixture; a stable local-preparation API remains unavailable until it can preserve Recoverable Edit Atomicity and commit the exact operations it measured.

## Evidence

The public container seam exposes exact evidence only after operations exist. Local methods such as `Document::create_node` and `Document::set_property` allocate and apply operations immediately, while `SyncSession::export_since`, `SyncSession::export_all`, `SyncMessage::op_count`, and `SyncMessage::to_canonical_bytes` report the resulting history (`container/document.mbt:1062-1077`, `:1335-1351`, `:1430-1442`; `container/sync_protocol.mbt:1321-1323`, `:1660-1669`). Existing causal identities and parents can be inspected after allocation, but the next operation's identity, parents, timestamp, and tree position are not available before mutation. The public seam therefore provides no input from which a caller can prove a useful no-underestimation encoded-byte bound before mutation.

`Document::transaction` is not a dry-run boundary. If its action raises, its buffered undo items are discarded, but mutations already applied to the shared document remain (`container/undo.mbt:445-466`). This follows ADR 0003's separation between Recoverable Edit Atomicity, Document Convergence, and Local History Best-Effort; undo grouping cannot stand in for shared-state rollback (`docs/adr/0003-consistency-boundaries.md`).

Issue [#101](https://github.com/dowdiness/event-graph-walker/issues/101) compared two public-seam candidate lifecycles in the throwaway [`prototype/issue-101-local-footprint-evidence`](https://github.com/dowdiness/event-graph-walker/tree/prototype/issue-101-local-footprint-evidence) branch at [`364e70f`](https://github.com/dowdiness/event-graph-walker/commit/364e70f17190cb89bb2a2bc9338cb79ee008ea99). The [prototype README](https://github.com/dowdiness/event-graph-walker/blob/364e70f17190cb89bb2a2bc9338cb79ee008ea99/prototypes/issue_101_local_footprint/README.md), [interactive source](https://github.com/dowdiness/event-graph-walker/blob/364e70f17190cb89bb2a2bc9338cb79ee008ea99/prototypes/issue_101_local_footprint/main.mbt), and [batch source](https://github.com/dowdiness/event-graph-walker/blob/364e70f17190cb89bb2a2bc9338cb79ee008ea99/prototypes/issue_101_local_footprint/batch/main.mbt) are the immutable evidence:

- complete replay into a fresh in-memory `Document` carrying the same writer identity produced deterministic canonical CRDT output without changing the source;
- one node creation plus three property writes produced exactly four operations;
- a `Version` plus canonical-byte fence rejected a candidate after the source advanced;
- replacing the active document with the candidate reproduced canonical shared state but lost prior local undo availability;
- an empty-history replay probe observed that applying the candidate delta as remote work did not create local undo availability; this rejects delta-back as a local-history boundary but does not characterize every existing undo stack;
- a different replica produced the same operation count with different canonical bytes;
- zero source pending operations, exclusive writer ownership, and an external atomic head and persistence fence remained assumptions rather than guarantees of the public API.

These are executable observations for one representative tree/property batch, not a proof for text edits, moves, deletes, mixed operation chains, or a production commit protocol. The fixture deliberately creates multiple live `Document` instances with one replica ID, contrary to `Document::new`'s globally-unique-per-instance contract (`container/document.mbt:488-496`). Its result may characterize private design possibilities under an isolated, frozen, non-syncing harness, but it does not authorize this construction in an application. Canonical shared state does not imply equivalent process-local history or writer authority.

Complete replay is also too expensive to assume on every local command. At 499 existing records, the representative four-operation command produced a 2,002-operation, 320,782-byte canonical history. The median of five isolated process medians was:

| Backend | End-to-end reconstruction median |
|---|---:|
| native | 142.752 ms |
| JavaScript | 299.768 ms |
| wasm-gc | 195.437 ms |
| WebAssembly | 366.038 ms |

Each timed sample combined complete JSON replay under the same writer identity, the four-operation append, full export, and canonical encoding. These measurements are empirical end-to-end costs, not isolated attribution to one implementation layer. Issue [#98](https://github.com/dowdiness/event-graph-walker/issues/98) remains responsible for property-replay performance attribution.

## Decision

No stable local mutation footprint or prepared-local-mutation API is accepted from Issue #101.

For hard pre-mutation budgets:

- exact operation count after mutation does not prove encoded-byte fit;
- a fresh replica is not an exact byte oracle;
- `Document::transaction` must not be used as rollback or discarded preparation;
- complete same-writer replay may exist only in an isolated, non-syncing diagnostic fixture; applications must not use it as either a normal or exceptional commit mechanism;
- external candidate replacement and candidate-delta apply-back are not production commit boundaries because they do not preserve local-history semantics;
- EGW must not report a conservative bound unless the concrete lowering and encoding path establishes a no-underestimation law over all generated metadata and encoded payloads;
- if neither exact candidate evidence nor a codec-owned no-underestimation bound proves fit, the caller must choose a non-applying outcome such as rejection or document rotation.

A future internal prepared-local-mutation design is the preferred research direction, not an accepted API. Any proposal must demonstrate all of the following before production adoption:

1. preparation is bound to the exact document head and current writer state;
2. preparation leaves shared state, causal history, sync output, pending state, and local history unchanged;
3. the measured immutable operations are the same operations committed, without restamping or replanning;
4. the capability is opaque, process-local, non-serializable, single-use, and rejects stale or repeated commit before mutation;
5. pending-state requirements and exclusive writer ownership are explicit;
6. successful commit has defined local undo and redo semantics rather than inheriting remote-apply behavior accidentally;
7. recoverable preparation and pre-commit failures preserve Recoverable Edit Atomicity, or the capability remains unavailable;
8. latency and memory are measured separately for preparation, commit, export, and canonical encoding on supported targets.

This research direction must inspect whether existing private stamping and undo machinery can stage closure-free local mutation descriptions safely. It must not introduce a generic application command abstraction or make replica identity itself a write capability.

`RemoteAdmissionPlan` remains semantically distinct. It prepares already-stamped remote operations for dependency and semantic admission under the canonical pending owner; it does not allocate local operation identity or predict local encoded history (ADR 0004). Issue [#72](https://github.com/dowdiness/event-graph-walker/issues/72) continues to own generic commit receipts and local/remote report unification.

## Alternatives

| Alternative | Why it is not selected |
|---|---|
| Fresh-replica reconstruction | Replica-specific operation metadata changes canonical bytes. |
| Same-writer full reconstruction | It is useful only as an isolated characterization fixture: multiple live instances violate the replica-ID uniqueness contract, reconstruction is expensive, and external swap/apply does not preserve local history as a production boundary. |
| Candidate replacement | Canonical CRDT state can match while prior process-local undo history is lost. |
| Candidate delta applied back to the source | Canonical CRDT state can match while the candidate command is recorded as remote rather than local history. |
| `Document::transaction` dry run | Raising discards undo grouping, not mutations already applied to shared state. |
| Operation count or heuristic byte multiplier | Neither proves canonical encoded-byte fit, especially for generated metadata and escaped strings. |
| Immediate stable prepared-local-mutation API | Current evidence does not establish writer transfer, single use, persistence fencing, crash behavior, or local-history semantics. |

## Consequences

Issue #101's research question is answered and may close when this ADR is merged. The prototype branch remains a primary source and is not merged into `main`.

No public API, sync wire format, persistence format, or production interface changes as a result of this decision. Applications requiring a hard encoded-byte budget must keep their authoritative document unchanged whenever fit cannot be proven.

A future prepared-local-mutation implementation requires a new narrowly scoped follow-up issue and its own evidence. Process crashes, durable writer leases, persistence compare-and-swap, and crash recovery remain external runtime concerns rather than guarantees inferred from Recoverable Edit Atomicity. Performance work does not broaden this ADR: Issue #98 owns full-sync property-replay attribution, while same-writer reconstruction remains an unsupported diagnostic fixture even if that path becomes faster.
