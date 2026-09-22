---
status: accepted
---

# Prepared local mutation is feasible but full-history evidence is not promotable

Phase A is a narrow GO as a semantic existence proof for the four-operation tree/property slice. Current whole-history fence and evidence representation is NO-GO for production promotion.

This ADR refines ADR 0006; it does not supersede it.

## Context

ADR 0006 rejected all public pre-mutation footprint APIs and identified an internal prepared-local-mutation design as the preferred research direction, conditional on nine pre-adoption requirements. Issue [#107](https://github.com/dowdiness/event-graph-walker/issues/107) implemented a test-only Phase A [model and correctness suite](https://github.com/dowdiness/event-graph-walker/tree/7ee3703/container) covering the four-operation tree/property append. The immutable [Phase A cost report and raw evidence](https://github.com/dowdiness/event-graph-walker/tree/70c6727/docs/benchmarks) characterize latency and memory cost.

## Decision

1. Phase A is accepted as a narrow semantic existence proof. The test-only model demonstrates: correctness gates (owner identity, single-use consumption, source-idle rejection, pending-state rejection, parent availability); exact record fidelity (the committed operations are the same stamped records, not re-planned); failure-injection coverage at every operation boundary; history and tracking fence detection without a version change; and exact post-commit match of successor JSON, canonical bytes, undo, and redo.

2. Current whole-history fence and evidence representation is NO-GO for production promotion. The full prepare retains successor JSON, fence JSON, successor canonical bytes, and fence canonical bytes as encoded values in memory. At 499 records this is approximately 2.2 MiB of logically retained encoded payload content, with baseline-adjusted median prepare+commit lifecycle RSS of 182936 KiB (JS) and 69928 KiB (wasm-gc), derived from five isolated child-process peak-RSS samples. Full prepare costs 113.79 ms (JS) and 79.53 ms (wasm-gc). Commit median is 70.795 ms (JS) and 43.753 ms (wasm-gc) versus direct-local mutation at 0.431 ms (JS) and 0.451 ms (wasm-gc).

3. No stable or public API, wire format, persistence format, or `.mbti` change is introduced. Living Chronicle integration remains blocked.

## Evidence summary

All numbers are from the immutable [Phase A cost report](https://github.com/dowdiness/event-graph-walker/blob/70c6727/docs/benchmarks/2026-08-03-prepared-local-mutation-phase-a-cost.md) and prototype commits cited above.

- Correctness: 18 test cases covering owner binding, single-use consumption, transaction/pending/parent rejection, exact successor replay, mixed-history preservation, frontier continuation, concurrent-frontier stamping, stale-source rejection, history/tracking/undo-mode fence detection, failure-injection range validation, boundary reporting, and detached overlay fidelity.
- Detached lowering: ~0.2 ms on both targets for the 499-record fixture.
- Full prepare: 113.79 ms (JS) / 79.53 ms (wasm-gc) at 499 records.
- Commit median: 70.795 ms (JS) / 43.753 ms (wasm-gc) versus direct-local 0.431 ms / 0.451 ms.
- 499-record successor JSON: 785861 bytes.
- Baseline-adjusted median prepare+commit lifecycle RSS: 182936 KiB (JS) / 69928 KiB (wasm-gc), from five isolated child-process peak-RSS samples.
- Exact retained object size: unsupported — RSS includes runtime heap, GC metadata, and allocator overhead.

## Architectural consequences

The following consequences must be resolved before any production promotion:

1. **Structural writer fence.** The current snapshot-fence captures full JSON and canonical bytes as encoded values for equality comparison. Production promotion requires a structural fence — a compact, deterministic comparison of source state — that replaces serialization equality.

2. **Codec-owned exact UTF-8 length.** Current evidence retains the full successor JSON string as admission proof. Production must replace retained full JSON with codec-owned exact UTF-8 byte length as the evidence payload.

3. **Full canonical bytes as oracle, not payload.** Full canonical bytes and full successor JSON remain valid as test and history oracle outputs. They must not be required as runtime admission payloads.

4. **Proof artifacts are not runtime authority.** Successor canonical bytes and successor JSON are proof artifacts for test verification. They do not authorize runtime admission decisions independently of the structural fence and codec evidence.

5. **Byte budget as codec state or counting evidence.** The encoded-byte budget must be maintained as codec-owned counting state or same-codec exact counting evidence, never as a guessed formula or heuristic constant.

6. **Counting encoder first.** The first step is a counting encoder that measures exact UTF-8 byte length without retaining full serialized content. Remeasure after implementing the counting encoder before considering any caching or pre-computation strategy.

## Required follow-up

Production promotion requires both:

- Follow-up research Issue [#108](https://github.com/dowdiness/event-graph-walker/issues/108), which addresses the architectural consequences above with its own ordered evidence gates.
- Measurements at each intended consumer's configured maximum encoded-byte and record limits, using acceptance criteria defined by that consumer before production integration.

Issue #108 now tracks the first requirement. Consumer-specific acceptance criteria and limit-scale evidence do not yet exist.

## ADR 0006 status

ADR 0006 remains in force and is refined by this decision. The nine pre-adoption requirements from ADR 0006 are unchanged. Phase A supplies executable semantic evidence for requirements 1–8 in the four-operation tree/property slice and separated latency/memory characterization on the required JS and wasm-gc release targets for requirement 9. Native and wasm cost measurements remain optional and unmeasured. Because ADR 0006 and Issue #107 established no production acceptance threshold, this research evidence does not authorize promotion. Issue #107's research question is answered for the tree/property slice; other operation types (text edits, moves, deletes, mixed chains) remain uncharacterized.

## Alternatives not selected

| Alternative | Why it is not selected |
|---|---|
| Promote Phase A as-is | Whole-history fence and evidence are too expensive and retain serialized content as proof. |
| Retain full JSON and canonical bytes as runtime payload | Memory cost scales with history size; 499 records already retains 2.2 MiB of encoded payload content. |
| Guess byte budget from operation count or heuristics | Does not prove no-underestimation fit for generated metadata and escaped strings (ADR 0006). |
| Cache serialized strings for repeated preparation | Does not address structural fence or codec-owned length requirements. |

## Consequences

No public API, sync wire format, persistence format, or `.mbti` change. Living Chronicle integration remains blocked. Phase A remains test-only until the required follow-up research issue is completed and accepted.
