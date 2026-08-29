---
status: accepted
---

# Text causality from declared parents with sparse Version summaries

ADR 0008 accepted same-agent sequence ancestry as part of the legacy text
admission contract. Differential testing against the official EG-walker
reference found that this policy rejects valid reference histories: sequence
numbers allocate stable operation identities across independently edited
branches, while declared parents name causal context.

## Decision

For text only:

- `(agent, sequence)` is stable operation identity and deterministic Fugue
  sibling order; adjacent sequence numbers do not imply causality.
- Declared parents are the causal authority. Admission readiness also includes
  semantic origin and target dependencies, but no implicit same-agent
  predecessor.
- The causal graph owns an exact RawVersion checkpoint and canonical per-agent
  half-open ranges. Its cache remains cold until first Version observation and
  then advances at the same admission point as RawVersion identity.
- The opaque text `Version` is a façade over a defensive graph snapshot; text
  mutation paths do not maintain a second version cache.
- Checkout resolves a maximal frontier and validates that the resident closure
  equals the supplied range summary.
- Delta export uses exact range membership. Text Version and SyncMessage use
  schema 2. Schema 1 is rejected because it cannot encode the new semantics.
- Local producers continue allocating monotonically and should normally use a
  fresh agent ID per editing session. This is a producer policy, not receiver
  validation.
- Reusing one RawVersion for a different operation remains a terminal identity
  conflict. The causal graph rejects duplicate RawVersion registration before
  mutation.

Container causality is not changed by this decision. Generic flat
`VersionVector` interfaces are not promoted as exact text checkpoints.

## Gate V0 evidence

The prototype passes:

- 15 hand-written public differential traces;
- all 1,000 official corpus runs with original identities as full batches;
- all 1,000 runs in reverse operation order, one operation per message, with
  every delivery duplicated; and
- Version schema-2 round-trip and exact terminal checkout in both corpus modes;
  and
- 40 seeded sparse same-agent disconnect/reconnect schedules through exact
  delta export; and
- insert/delete/undelete version round-trip, checkout, and exact delta export.

Targeted text, OpLog, causal-graph, document, branch, and container native tests
pass. Cold and hot 1,000-character append remain near the prior baseline. Cold
1,000-operation summary reconstruction is materially faster than the earlier
text-owned sparse implementation; fragmented warm snapshots have a dedicated
32-agent × 32-range benchmark.

## Consequences and release evidence

This replaces ADR 0008's text sequence-ancestry rule, not its ownership and
atomic-admission decisions. The schema-2 release gates are complete:

- persisted schema-1 text state is rejected and removed by the Canopy browser
  boundary instead of being converted;
- a Canopy downstream probe against the exact EGW candidate passes all-target
  tests, the JavaScript build, and schema-1 persistence and FFI rejection;
- adversarial fragmentation measurements establish fixed decoder limits of
  512 KiB, 4,096 frontier entries, 4,096 agent entries, and 4,096 total ranges;
  and
- the migration contract is recorded in `docs/MIGRATING_TEXT_SCHEMA_2.md`.

The Canopy migration must land after the EGW candidate is remotely reachable.
Changing container sequence semantics still requires a separate decision and
validation gate.

Gate V0/V1 does not prove arbitrary mixed-operation partition schedules or
symbolic safety. Mixed text schemas are intentionally non-interoperable.
