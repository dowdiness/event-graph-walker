---
status: proposed
---

# Text causality from declared parents with sparse Version summaries

ADR 0008 accepted same-agent sequence ancestry as part of the legacy text
admission contract. Differential testing against the official EG-walker
reference found that this policy rejects valid reference histories: sequence
numbers allocate stable operation identities across independently edited
branches, while declared parents name causal context.

## Proposed decision

For text only:

- `(agent, sequence)` is stable operation identity and deterministic Fugue
  sibling order; adjacent sequence numbers do not imply causality.
- Declared parents are the causal authority. Admission readiness also includes
  semantic origin and target dependencies, but no implicit same-agent
  predecessor.
- The opaque text `Version` contains an exact RawVersion frontier and canonical
  per-agent half-open sequence ranges for the frontier's causal closure.
- Checkout resolves the exact frontier and validates that the resident closure
  equals the supplied range summary.
- Delta export uses exact range membership. Schema-1 text Versions retain their
  legacy contiguous-prefix interpretation; schema 2 serializes frontier and
  ranges.
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
  delta export.

Targeted text, OpLog, causal-graph, document, branch, and container native tests
pass. Incremental cache maintenance keeps the existing 1,000-character append
benchmark near its prior baseline. Full lazy Version reconstruction is slower
and remains measured prototype cost.

## Consequences and unresolved migration work

This is a proposed replacement for ADR 0008's text sequence-ancestry rule, not
for its ownership and atomic-admission decisions. Production adoption still
requires:

- a mixed schema-1/schema-2 Version migration policy;
- persisted-Version and saved-document compatibility evidence;
- downstream Canopy consumer validation;
- explicit resource limits for hostile range fragmentation if encoded-byte
  limits prove insufficient; and
- a separate decision before changing container sequence semantics.

Gate V0 does not prove arbitrary mixed-operation partition schedules,
persistence, symbolic safety, or mixed-version interoperability.
