# Parse, don't validate audit and improvement plan

**Date:** 2026-07-21  
**Status:** Proposed  
**Scope:** `dowdiness/event-graph-walker`

## Executive summary

Event Graph Walker already applies the central idea from Alexis King's ["Parse, don't validate"](https://lexi-lambda.github.io/blog/2019/11/05/parse-don-t-validate/) at its most important boundary: remote synchronization. Raw wire data is decoded into sealed messages, receiver-dependent applicability is represented by private types, and only a prepared transition reaches mutation. This is a strong fit with the project's Functional Core / Imperative Shell architecture.

The first cleanup removed the temporary invalid `RawVersion` previously used while emitting block-text inserts. The remaining work focuses on values whose documented invariants can still be bypassed, checks whose result is discarded, structural `Range` invariants, and the distinction between structural parsing and receiver-specific policy checks.

## CRDT-specific interpretation

For this project, "parse" does not mean that every value can be proved valid at the JSON boundary. There are three distinct stages:

1. **Wire parsing** establishes shape and state-independent invariants: exact fields, recognized operation variants, non-empty identities, non-negative sequences, and Unicode scalar content. Sealed constructors then canonicalize internal ordering; the codecs do not necessarily reject every equivalent noncanonical wire order.
2. **Receiver-context parsing** establishes facts that depend on the current causal graph and document: dependencies are present, sequence ancestry is correct, origins identify inserts, and target blocks exist.
3. **Commit** mutates state using only the result of the first two stages.

Missing causal dependencies are not malformed input. They represent an incomplete but potentially valid distributed state and should remain an explicit `Defer` outcome rather than a validation failure.

## Existing strengths

The text synchronization path already preserves validation knowledge in types:

- `SyncMessage` has private storage and a private validating constructor (`text/sync.mbt:409-445`).
- `ApplicableOp` represents an operation parsed for the receiver's causal context (`text/sync.mbt:467-523`).
- `ParsedCandidate` preserves `Apply`, `Defer`, and invalid-pending decisions instead of reducing them to a Boolean (`text/sync.mbt:533-577`).
- `PreparedSync` is the only transition consumed by the apply shell (`text/sync.mbt:580-599`, `text/sync.mbt:1130-1149`).

The container path follows the same design:

- `ApplicableSyncOp` prevents the apply shell from consuming an unparsed wire record (`container/document.mbt:153-166`).
- `parse_applicable_sync_record` performs receiver-state checks before constructing it (`container/sync_protocol.mbt:403-425`).
- `prepare_container_sync` is a deterministic functional core, while `SyncSession::apply` is the mutation shell (`container/sync_protocol.mbt:1132-1254`, `container/document.mbt:1448-1475`).

These types should be treated as the reference pattern for the opportunities below.

## Ranked opportunities

### 1. Make `Frontier` uniqueness unconditional

**Benefit:** High  
**Risk:** High because callers also access the public backing array

`Frontier` documents uniqueness as an invariant but derives `FromJson` and exposes `from_array`, which accepts duplicates (`internal/core/graph_types.mbt:1-20`). More importantly, its `pub(all)` tuple representation lets other packages bypass both functions with direct construction. The separate `from_array_dedup` constructor and `has_duplicates` query (`internal/core/graph_types.mbt:22-56`) therefore leave callers responsible for retaining or rechecking knowledge that belongs in the type.

Make the backing array private and expose only invariant-preserving constructors and accessors. The existing `from_array_dedup`, backed by `@hashset.HashSet[Int]`, is the first parser candidate. Replace derived deserialization with a custom parser that preserves the same invariant. If canonical construction affects a measured hot path, optimize that parser without reopening a public unchecked constructor.

`docs/STABILIZATION_ROADMAP.md:34` records duplicate handling as fixed because deduplication and detection APIs were added. Under the stronger parse-don't-validate criterion, duplicates remain representable, so this is a refinement of that completed work rather than a contradiction of it.

Verification should include existing frontier tests, causal graph property tests, walker tests, and release benchmarks if canonicalization enters a hot path.

### 2. Remove the invalid `RawVersion("", 0)` placeholder

**Status:** Implemented 2026-07-21  
**Benefit:** Medium  
**Risk:** Low

`Document::emit_text_op` now returns the stable identity after applying and recording the operation (`container/undo.mbt:111-124`). `Document::insert_text` consumes that result directly when recording undo state (`container/text_ops.mbt:47-50`); callers that do not need the identity discard it explicitly.

This removes the previous illegal intermediate state without introducing a new type or validation branch. It also makes the data flow from allocation to undo recording explicit.

### 3. Parse stable `Range` invariants at construction

**Benefit:** Medium  
**Risk:** High because this changes the public facade representation and constructor contract

`Range` uses non-negative `Pos` values but permits `start > end` (`text/types.mbt:29-45`). Its `pub(all)` fields also let callers bypass `Range::new` through direct struct construction. The ordering check is deferred until an edit through `checked_range_bounds` (`text/text_doc.mbt:179-189`).

Make the fields private, provide read-only accessors, and enforce the state-independent invariant `start <= end` in every public constructor. The document-dependent invariant `end <= current_length` must remain close to mutation because concurrent and local edits can make a previously bounded position stale. A private, short-lived resolved range may preserve that second proof between the functional decision and the immediate mutation, but it must not imply long-term validity.

Do not silently reorder endpoints. Reject a reversed range, or introduce an explicitly named normalizing constructor if normalization is a desired API contract. Because `Pos::at` intentionally clamps negatives (`text/types.mbt:6-17`; `docs/FORMAL_SPECIFICATION.md:936-943`), changing its behavior is outside this proposal.

### 4. Separate structural parsing from receiver policy

**Benefit:** Medium  
**Risk:** Medium

Text operations are structurally checked when `SyncMessage` is constructed and checked again during preparation (`text/sync.mbt:251-285`, `text/sync.mbt:417-445`, `text/sync.mbt:1059`). Container records are similarly checked during decoding and preparation (`container/sync_protocol.mbt:595-695`, `container/sync_protocol.mbt:1152`, `container/sync_protocol.mbt:1372`).

Some repeated checks are necessary: the receiver may enforce stricter encoded-size, operation-count, pending-count, or parent-count limits than the sender. State-independent facts should nevertheless be parsed once and retained. Split operation shape/content parsing from receiver policy and receiver-state applicability so each stage has a distinct output type or sealed constructor.

The strict facade codecs use dedicated decoders rather than the generic derived `FromJson` implementations on `RawVersion`, `OpContent`, `Op`, and `Frontier` (`internal/core/version.mbt:19-22`, `internal/core/operation.mbt:5-26`, `internal/core/graph_types.mbt:6`). Those traits are not all unused, however: `OpRun::FromJson` decodes its parents and origins through `RawVersion::FromJson` (`internal/core/op_run_json.mbt:75-85`), and the trait remains visible in `internal/core/pkg.generated.mbti`. Inventory all serialization consumers before removal. Migrate `OpRun` to a validated identity decoder first, preserve or explicitly version its JSON compatibility, and treat trait removal as an interface change.

### 5. Distinguish wire identity from valid operation identity

**Benefit:** High in the long term  
**Risk:** High due to broad internal use

`RawVersion` can contain an empty agent or negative sequence (`internal/core/version.mbt:19-33`), so identity checks recur at text and container ingress (`text/sync.mbt:251-275`, `container/sync_protocol.mbt:552-577`). A future design could parse a raw wire identity into an opaque operation identity containing a non-empty replica ID and non-negative sequence.

Schedule this as the final phase. `RawVersion::new` is widely used by the causal graph, oplog, compression, text, and container packages. The migration should first identify which call sites consume untrusted wire values and which derive identities from already valid graph state. Global uniqueness of a replica ID cannot be encoded by this local parser; only its structural properties can.

## Non-goals

- Do not turn missing causal dependencies into malformed-message errors. Preserve `Defer`.
- Do not introduce document-bound positions that claim to remain valid across later edits.
- Do not wrap every snapshot-local LV. `CausalSnapshot::entry(Int) -> SnapshotEntry?` correctly represents snapshot-relative lookup failure (`history/snapshot.mbt:36-39`).
- Do not claim that a non-empty replica ID is globally unique. Deployment remains responsible for assigning unique replica-instance identities.
- Do not replace resource budgets with value types. Limits are receiver policy and are already represented by the validating, immutable `Limits` type (`sync/types.mbt:45-101`).

## Phased implementation order

1. **Completed 2026-07-21:** Remove the invalid text-operation identity placeholder.
2. Inventory generic JSON trait consumers and generated `.mbti` exposure, including the `OpRun` dependency on `RawVersion::FromJson`, and pin required round-trip compatibility.
3. Make `Frontier` opaque and invariant-preserving, then benchmark affected graph paths.
4. Make `Range` opaque and strengthen its constructors in an API-breaking release.
5. Separate structural sync parsing from receiver policy checks while preserving `ApplicableOp` and `ApplicableSyncOp`.
6. Reassess an opaque operation identity, migrate dependent codecs such as `OpRun`, and remove generic deserialization traits only when their consumers have moved.

Each phase should be independently reviewable and should preserve the wire formats unless explicitly documented otherwise.

## Existing API and core reuse check

Project patterns to reuse:

- `TreeNodeId` validating constructor (`container/document.mbt:8-21`)
- immutable validating `Limits` constructor (`sync/types.mbt:45-101`)
- existing `Frontier::from_array_dedup`, including its `@hashset.HashSet[Int]` uniqueness pass (`internal/core/graph_types.mbt:22-39`)
- `ApplicableOp`, `ParsedCandidate`, `PreparedSync`, and their container counterparts
- defensive copies and `ArrayView` at read-only boundaries, as used by `SnapshotEntry::parents` (`history/snapshot.mbt:72-90`)

MoonBit core APIs checked for implementation planning:

- `Option` for context-dependent lookup and deferred availability
- `Result` or typed raised errors for parsers that must explain rejection
- `Map[Int, Unit]` as a core uniqueness-set fallback; the existing `@hashset.HashSet[Int]` remains the preferred project implementation
- `ArrayView` for exposing parsed collections without mutable aliases
- `String`/`StringView` and `Bytes`/`BytesView` for non-copying codec boundaries where the existing JSON APIs permit them

## Verification

For each implementation phase:

1. Run `moon check` and `moon test` from the workspace root.
2. Run package-focused tests for every changed internal and facade package.
3. Run `moon fmt` and `moon info`, then inspect `internal/core/pkg.generated.mbti`, `text/pkg.generated.mbti`, and all other generated interface diffs for intended API changes.
4. Before changing a serialization trait, use `moon ide find-references` and repository search to enumerate consumers; preserve `OpRun` JSON round trips or version the format explicitly.
5. Preserve malformed-wire, duplicate-parent, missing-dependency, pending-operation, and failure-atomicity tests.
6. For `Frontier`, compare causal graph and walker release benchmarks before and after canonical construction.
7. If web-facing wire behavior changes, rebuild the JS target and run the parent Canopy integration checks.
