---
status: accepted
---

# Exact text causality and sparse synchronization versions

## Context and requirements

The text CRDT assigns every operation a stable `RawVersion` identity consisting
of an agent identifier and a sequence number. An operation also declares the
parent operations that form its causal context. These are separate facts:
identity names an operation, while declared parents determine what that
operation observed.

A text synchronization design must satisfy all of the following requirements:

- accept histories in which one agent allocates sequence numbers on independent
  branches;
- preserve deterministic Fugue ordering across replicas;
- represent an exact historical checkout point;
- compute an exact stateless delta even when the sender does not know every
  operation named by the peer;
- reject conflicting reuse of an operation identity before mutating state;
- avoid maintaining competing causal indexes in the graph and text façade;
- keep the ordinary local append path independent of wire-summary cost until a
  version is requested; and
- place fixed resource bounds on untrusted wire data without truncating causal
  knowledge.

This decision defines the text protocol. Tree and container protocols have
separate version contracts and are not interchangeable with text versions.

## Domain vocabulary

**Operation identity**
: A `RawVersion(agent, sequence)` that uniquely names one operation. Sequence
  order within an agent does not imply causal order.

**Declared parents**
: The exact operation identities observed when an operation was created. Their
  transitive closure defines the operation's causal history.

**Causal checkpoint**
: The maximal frontier of one causal cut. It contains the identities that are
  not ancestors of another identity in the same cut.

**Knowledge summary**
: The exact set of operation identities known at a checkpoint, encoded as
  canonical half-open sequence ranges grouped by agent.

**Text Version**
: An opaque value containing one causal checkpoint and its knowledge summary.
  The checkpoint supports checkout; the summary supports stateless delta
  export.

**Resident graph**
: The locally admitted causal graph against which a checkpoint can be resolved
  and validated.

## Authority and ownership

`CausalGraph` is the sole local authority for operation identity, declared-parent
causality, the current frontier, sparse identity knowledge, and identity
conflicts.

The text façade does not maintain another version vector or causal cache. It
wraps a defensive graph snapshot in an opaque `Version`. Arrays supplied by a
caller or returned to a wire adapter are copied so mutation outside the graph
cannot change an accepted checkpoint or knowledge summary.

The knowledge summary is not a second causal authority. For a locally produced
Version it is derived from the graph. For a received Version it is a peer's
claim about its own knowledge. A checkout validates that claim against the
resident graph before using it.

## Core invariants

Every structurally valid text Version satisfies these invariants:

1. Every frontier identity has a nonempty agent and a nonnegative sequence.
2. Frontier identities are unique and canonically ordered.
3. Agent entries are nonempty, unique, and canonically ordered.
4. Each sequence range is nonempty and half-open.
5. Ranges for one agent are sorted, disjoint, and non-adjacent.
6. Sequence values fit the public nonnegative `Int` identity domain. A
   half-open endpoint may be one greater than the maximum sequence.
7. Every frontier identity appears in the knowledge summary.
8. An empty checkpoint has an empty knowledge summary, and a nonempty
   checkpoint has a nonempty summary.

Resolving a Version against a resident graph establishes the contextual
invariant:

```text
knowledge summary = transitive closure of checkpoint frontier
```

The frontier must also be the maximal antichain of that closure. A redundant
ancestor in the frontier makes the Version invalid even if the union of
reachable operations would otherwise be unchanged.

## Operation admission and pending delivery

An operation is ready for admission only when all dependencies needed to apply
it are available. Dependencies include:

- every declared causal parent;
- Fugue origins referenced by an insertion; and
- operation targets referenced by delete or undelete actions.

The sequence immediately preceding an operation from the same agent is not an
implicit dependency.

Operations with missing dependencies remain pending. Pending operations do not
enter the causal graph, do not advance its frontier, and do not appear in a
Version. Admission inserts the operation identity, advances the frontier, and
updates a warm knowledge-summary cache as one atomic authority transition.

Re-delivery of an already admitted identity is idempotent only when the logical
operation is equivalent: content and origins match, and declared parents name
the same set regardless of array order. Reusing the identity for any other
operation is a terminal conflict rejected before graph, operation log, or
projection mutation.

## Deterministic text order

Concurrent Fugue siblings use stable source identity as their deterministic
order. The ordering key compares the agent identifier by lexical UTF-16 code
units, then compares the source sequence numerically.

Destination-local logical versions are allocation details and cannot
participate in cross-replica ordering. Every Fugue insertion therefore receives
the source sequence explicitly. Causal depth and arrival order do not override
the sibling identity order.

## Version construction and cache policy

A graph starts with its knowledge-summary cache cold. Local editing and remote
admission do not build or update a sparse summary while the cache remains cold.
The first request for the current Version constructs the summary from admitted
graph identities. Later admissions update the warm summary at the same point
that the graph accepts the corresponding identity.

A Version request returns defensive copies of the current maximal frontier and
knowledge summary. The cache is an optimization over graph authority; deleting
it and reconstructing from the graph must produce the same Version.

## Exact checkout

Checkout is defined only for a Version whose checkpoint and knowledge summary
resolve exactly in the resident graph.

The resolver:

1. maps every frontier identity to a resident graph node;
2. computes the frontier's transitive closure;
3. verifies that no frontier member is an ancestor of another frontier member;
4. derives the closure's canonical knowledge summary; and
5. compares the derived summary with the supplied summary.

Any missing identity, nonmaximal frontier, extra claimed identity, or omitted
identity rejects checkout. The resolver never approximates a checkpoint by
using per-agent maxima.

## Stateless delta export

A peer Version lets a sender test exact identity membership while walking its
own operations:

```text
send operation if peer knowledge does not contain its RawVersion
```

The peer's frontier alone is insufficient for this operation. A peer may name a
frontier identity that the sender does not possess. The sender cannot derive the
unknown identity's ancestors and therefore cannot know which local operations
are already present at the peer. A frontier-only protocol must either send the
full history in this case or introduce a stateful, multi-round reconciliation
protocol.

The sparse knowledge summary preserves exact one-message delta computation
without requiring persistent per-peer state. A peer that falsely overstates its
knowledge can prevent itself from receiving operations, but the claim cannot
mutate or weaken the sender's graph.

## Schema-2 wire contract

Text Version JSON contains exactly:

- schema identifier `2`;
- the text Version format identifier;
- the exact frontier; and
- per-agent sequence ranges.

The encoder emits frontier identities, agent entries, and ranges in canonical
order. The decoder accepts any frontier and agent-entry order, normalizes those
two levels, then rejects duplicates and noncanonical range order within an
agent. Semantic equality is independent of accepted top-level wire order.

Text SyncMessage JSON also uses schema `2`. Canonical bytes are domain-separated
with `event-graph-walker:text-sync:v2` so hashes and signatures cannot be
confused with another protocol domain.

Decoders reject missing fields, unknown fields, duplicate identities, malformed
ranges, invalid identities, unsupported schemas, and unsupported formats.
There is no synthetic-range conversion, downgrade encoding, mixed-schema
negotiation, or fallback interpretation.

Version JSON encoding is fallible. The encoder enforces the same cardinality and
encoded-byte limits as the decoder. It returns a classified limit error instead
of emitting a token that the decoder would reject. Neither direction truncates
frontiers or ranges, coalesces gaps, or substitutes a flat version vector.

## Resource and failure contract

A text Version wire token is bounded by all of the following limits:

```text
encoded UTF-8 bytes <= 512 KiB
frontier entries     <= 4,096
agent entries        <= 4,096
total ranges         <= 4,096
```

The byte limit is checked before parsing untrusted JSON. Cardinality limits are
checked after strict envelope decoding and before graph-version construction or
resident-graph resolution. Encoding checks cardinality before serialization and
checks encoded UTF-8 size before returning the token.

Byte excess is classified as `EncodedBytes`. Decoded frontier, agent, and range
excess use the existing `DecodedOperations` classification. These fixed wire
rules do not add public limit configuration or expose graph internals.

### Limit evolution

The four limits are part of the schema-2 interoperability contract, not local
tuning parameters. A conforming schema-2 encoder never exceeds them. A
conforming decoder accepts structurally and semantically valid tokens at the
boundary and rejects tokens above it.

An implementation may optimize how it enforces the limits but cannot change the
schema-2 sending envelope. Raising an encoder limit would produce tokens that a
conforming peer must reject. Lowering a decoder limit would reject tokens that
a conforming peer may send. Either change requires a new schema or format, or a
future capability protocol that selects a different envelope before sending.
It must not be deployed as an unannounced schema-2 policy change.

A decoder may inspect a larger token only in an explicitly nonstandard trusted
adapter. Such an adapter cannot emit the larger token as schema 2, cannot be
used as evidence of standard interoperability, and does not weaken the default
untrusted-wire boundary.

An arbitrary exact sparse set cannot always fit in a fixed-size stateless
message. The design therefore permits an in-memory graph to outgrow the wire
Version boundary and makes serialization failure explicit. Ordinary
`export_all` does not compact such a graph: applying the same operations
reconstructs the same sparse identity set. Operational recovery requires either
of the following actions:

- perform application-controlled rematerialization: create an empty document
  with a new identity, insert the current visible text as a new operation
  history, and retire the old history, checkpoints, and undo identities after
  explicit user or owner approval; or
- use a future stateful reconciliation protocol that transfers exact knowledge
  over multiple bounded messages.

A local Version serialization failure is terminal for that wire attempt and is
not retried unchanged. Adapters must propagate the error; they must not replace
it with an empty Version, empty SyncMessage, or successful no-op.

### Adapter failure policy

Every boundary that serializes a Version owns an explicit response to encoding
failure:

| Boundary | Required behavior |
|---|---|
| Sync request | Do not send. End the unchanged retry cycle and report a terminal local resource failure. |
| Persistence | Do not report a successful save and do not overwrite the last valid persisted state. |
| FFI | Propagate an exception or typed error. Do not return an empty string or valid empty payload. |
| Diagnostics | Report serialization failure separately from document content and sync success. |
| Equality and local revision tracking | Compare opaque `Version` values with `Eq` or derive an in-memory token with `Hash`; do not serialize them for local comparison or cache invalidation. |
| Hashing and signing | Produce no hash or signature when canonical serialization fails. Propagate the cause. |
| Recovery loop | Do not retry the same over-limit Version. Require rematerialization or a different reconciliation protocol. |

Adapters may translate the error into their own taxonomy, but they must preserve
that it is a local Version resource failure. Inbound untrusted-token rejection
and outbound local serialization failure are distinct events even when both use
`LimitExceeded` internally.

## Security and trust boundary

Wire data is untrusted. Structural validation and resource checks occur before
it reaches graph authority. Contextual checkpoint validation occurs before
checkout. Operation admission validates identity and dependencies before
mutation.

Knowledge supplied for delta export is a request-scoped peer claim, not a local
state transition. Sending fewer operations because a peer overclaims knowledge
can only deprive that peer of data. It cannot delete local operations or alter
local causality.

## Performance policy

The common local append path performs graph admission and projection work only.
It does not scan history to maintain a Version before one is requested.
After the first Version request, incremental range insertion is allowed because
its cost is coupled to the accepted identity transition.

The normative limits above are justified by the adversarial native and
JavaScript measurements in `docs/BENCHMARKS.md`, including fragmented
single-agent histories, many-agent histories, and mixed fragmentation. Both
cold reconstruction and warm snapshots require benchmarks. Optimizations may
change storage or encoding, but must preserve exact membership and the
authority invariants above.

## Text and container boundary

This decision applies only to the text protocol. A container Version may use a
different identity or summary contract and cannot be decoded as a text Version.
Shared synchronization failure types do not imply wire or causal compatibility.

Changing container causality requires its own compatibility target, wire
schema, downstream migration, and validation evidence. Text semantics must not
be copied into container code without that decision.

## Non-goals

This design does not provide:

- interoperability with another text schema;
- causal validity inferred from adjacent agent sequences;
- one fixed-size token for every possible sparse history;
- Byzantine proof that a peer's delta-knowledge claim is truthful;
- garbage collection or history compaction;
- durable per-peer synchronization state;
- Merkle, Bloom-filter, or IBLT reconciliation; or
- a change to tree or container causality.

## Rejected alternatives

### Flat version vectors

A single maximum sequence per agent claims that every lower sequence is known.
That is valid only for strictly sequential agent histories and cannot represent
independent same-agent branches or holes.

### Frontier-only stateless synchronization

A frontier is sufficient for checkout when all frontier identities are locally
resident. It is insufficient for exact delta export when the sender does not
know a peer head. Full-history fallback is correct but loses incremental
behavior whenever peers diverge.

### Text-owned summary cache

Maintaining ranges in the text façade duplicates graph knowledge and allows
identity admission and summary advancement to drift. The cache belongs beside
the graph transition it summarizes.

### Public checkpoint and summary types

Exposing separate caller-managed values makes it possible to pair a checkpoint
with unrelated knowledge and increases transport complexity. The public
Version remains opaque while the implementation preserves the conceptual
separation internally.

### Dotted vectors, bitmaps, and adaptive binary sets

Dotted vectors represent a contiguous prefix plus a bounded number of
exceptions; arbitrary sparse history needs an unbounded exception set. Bitmaps
and adaptive sets can improve encoding density but cannot remove the
information bound. They remain possible internal encoding optimizations.

### Stateful or probabilistic reconciliation

Shared-head sessions, need messages, Bloom filters, Merkle indexes, and IBLTs
can spread reconciliation across bounded messages. They require durable peer
state, additional rounds, reset behavior, and new failure handling. They are a
separate transport design, not a simpler implementation of stateless
`export_since`.

## Validation obligations

A conforming implementation must provide evidence for all of these boundaries:

- terminal visible-text agreement with an independent EG-walker reference;
- exact replay of histories containing sparse same-agent identities;
- duplicate and reordered delivery;
- identity conflict rejection before mutation;
- Version structure validation and defensive ownership;
- exact checkout closure and maximal-frontier checks;
- exact delta export across sparse knowledge;
- insert, delete, and undelete round-trips;
- encoder/decoder closure at every accepted resource boundary;
- classified encoder and decoder rejection immediately above each boundary;
- cold, warm, fragmented, and ordinary append benchmarks on native and
  JavaScript targets; and
- downstream transport, persistence, FFI, recovery, and browser validation.

Model checking, simulation, reference differential testing, implementation
replay, and downstream integration tests provide different evidence. A result
from one layer must not be presented as proof supplied by another.

## Consequences

The graph owns one exact causal model, and text synchronization exposes a small
opaque interface over it. Valid sparse histories remain admissible even when an
agent's sequence allocation is not a causal chain. Stateless delta export stays
exact for wire-representable Versions, while hostile or excessively fragmented
wire claims fail with bounded, classified errors.

The protocol deliberately rejects incompatible text payloads and may require
application-controlled rematerialization when an exact history no longer fits
the bounded stateless Version format. A future stateful reconciliation protocol can remove
that availability limit without changing the underlying operation identity,
declared-parent causality, or exact checkpoint model.
