# EGW Text Sync Gate V2 design

Date: 2026-08-29
Status: implemented

## Purpose

Gate V2 validates the causal and synchronization contracts of Event Graph
Walker’s schema-2 text API under sparse, partial, duplicated, reordered, and
conflicting delivery.

The suite combines a small formal model with replay against the production
public API. The model checks protocol rules; replay checks that the MoonBit
implementation follows those rules. Existing differential and resource tests
remain responsible for concerns they already cover.

Gate V2 is a native-only verification tool. It is not part of the production
module, published package, or normal CI path.

## Text sync contract

An EGW text operation has a stable identity:

```text
RawVersion(agent, sequence)
```

The sequence allocates identity within an agent. It does not imply that the
previous same-agent sequence is a causal parent.

Causality comes only from relationships declared by the operation:

- declared parents;
- insertion origins;
- delete targets;
- undelete targets.

`CausalGraph` owns the authoritative admitted operation graph. It derives:

- the exact maximal frontier;
- exact admitted identity knowledge;
- identity conflict detection for admitted identities;
- historical checkpoint resolution.

`Document` and `OpLog` own causal applicability, pending operations, and the
transition from pending to admitted. Gate V2 preserves this boundary: pending is
modeled separately from the admitted graph, and admission updates the modeled
`CausalGraph` authority only after all declared dependencies are available.

The public `text.Version` type is opaque. Its schema-2 wire representation
contains:

- an exact frontier;
- canonical per-agent half-open ranges representing exact admitted identities.

The Version wire envelope is bounded:

- encoded UTF-8: at most 512 KiB;
- frontier entries: at most 4,096;
- agent entries: at most 4,096;
- total ranges: at most 4,096.

An in-memory graph may remain valid after its Version exceeds these limits. In
that state, Version serialization fails; the graph is not reinterpreted as
corrupt or truncated.

The sync envelope uses schema `2` and format
`event-graph-walker/text-sync`. Canonical bytes are domain-separated by
`event-graph-walker:text-sync:v2`. Schema 1 is not decoded or synthesized.

The implementation contract is defined by:

- `docs/adr/0009-text-causality-and-sparse-version.md`;
- `internal/causal_graph/graph.mbt`;
- `internal/causal_graph/graph_version.mbt`;
- `text/sync.mbt`;
- `text/types.mbt`;
- `text/pkg.generated.mbti`.

## Assurance boundaries

EGW uses separate evidence for separate claims.

| Evidence | Claim |
|---|---|
| Gate V2 Quint model | Bounded causal, identity, pending, sparse knowledge, delta, and delivery safety |
| Gate V2 MoonBit replay | Production public API conforms to generated model traces at every observable prefix |
| Gate V0 `reference-frh` differential | Visible Fugue text ordering matches the independent executable reference for covered traces |
| Existing MoonBit codec/resource tests | Concrete schema, round-trip, 4,096/4,097, and 512 KiB boundaries |
| Existing benchmarks | Measured costs for specific fixtures and candidate commits |

No layer inherits another layer’s claim. In particular:

- model safety does not prove visible text ordering;
- final text convergence does not prove exact sparse knowledge;
- codec limits do not bound resident history or outgoing sync message size;
- bounded model checking does not prove unbounded distributed liveness.

## Goals

Gate V2 must check that:

1. an identity cannot denote conflicting admitted content;
2. conflicts are rejected before authoritative state changes;
3. operations remain pending until declared dependencies are admitted;
4. pending operations do not affect Version, checkout, or delta export;
5. equivalent duplicates are idempotent;
6. same-agent sequence adjacency never creates causality;
7. exact sparse knowledge represents exactly admitted identities;
8. the frontier contains only maximal admitted identities;
9. checkpoints resolve to their declared causal closure;
10. `export_since` omits only identities represented by the supplied peer
    knowledge;
11. sparse gaps are not hidden by a larger same-agent sequence;
12. dependency-safe delivery permutations converge by admitted operation set;
13. the production public API matches the model after every observable step.

## Non-goals

Gate V2 does not:

- model Fugue visible ordering;
- replace Gate V0;
- add production APIs, white-box hooks, or test-only fields;
- add Quint, Java, Apalache, or verification libraries to production packages;
- implement stateful multi-round reconciliation;
- implement application rematerialization;
- add schema-1 compatibility;
- prove unbounded liveness;
- model Version limits a second time in Quint;
- introduce a new state-machine QuickCheck dependency;
- use TLC as a required backend;
- run in normal CI.

## Design principles

### Functional core

The Quint model is a deterministic transition system:

```text
State + Event -> State + Outcome
```

It contains no filesystem, process, MoonBit, or transport effects.

### Imperative shell

A small shell:

1. invokes Quint;
2. saves ITF traces;
3. runs the MoonBit replay executable;
4. runs existing Gate V0 and resource contracts;
5. reports the exact candidate commit and tool versions.

### Public implementation boundary

The replay driver imports the public `dowdiness/event-graph-walker/text`
package. It may also import the public `dowdiness/event-graph-walker/sync`
package solely to classify the `Failure` carried by `TextError::SyncFailed`.
It must not import `internal/causal_graph`, `internal/oplog`,
`internal/document`, or `internal/core`.

### Existing evidence first

Gate V2 reuses existing tests instead of restating them. New checks must cover a
causal or correspondence boundary that existing fuzz, codec, resource, or
reference tests do not already establish.

## Repository layout

```text
tools/verification/text_sync_gate_v2/
  README.md
  run.sh
  package.json
  package-lock.json
  TextSyncCore.qnt
  TextSyncScenarios.qnt
  replay/
    moon.mod
    moon.work
    moon.pkg
    main.mbt
```

`replay/moon.work` contains the EGW root and replay module, following the
isolation pattern used by `tools/verification/text_reference/moon.work`.

The replay module is native-only and executable. Its module dependency may name
the released EGW version, while the local workspace member resolves the current
candidate source.

## Quint model

### Identity

```text
RawVersion = {
  agent: str,
  sequence: int
}
```

Sequences are finite non-negative integers within the model bounds. Sparse
identities such as `(a,0)`, `(a,2)`, and `(a,7)` are first-class cases.

### Operation

```text
Operation = {
  id: RawVersion,
  parents: Set[RawVersion],
  kind: Insert | Delete | Undelete,
  content: Option[str],
  originLeft: Option[RawVersion],
  originRight: Option[RawVersion]
}
```

The directional origin fields follow the public wire operation exactly. For an
insert, `content` is the exact inserted string and both origins retain their
direction. For a delete or undelete, `content` is absent, `originLeft` is the
target, and `originRight` is absent.

Two operations are equivalent only when identity, parent set, kind, exact
content, `originLeft`, and `originRight` are all equal. Reuse of an identity with
any different field is a conflict. The finite model restricts strings to a small
set but does not replace exact content with a potentially colliding hash. It does
not model Fugue positions beyond the directional origins required by the wire
operation.

### Replica state

Each replica contains:

```text
Replica = {
  admitted: Set[Operation],
  pending: Set[Operation]
}
```

Admitted and pending operations are the only replica authority. Knowledge,
maximal frontier, pending count, checkpoints, delta contents, message heads,
and report counts are pure derived observations. They are emitted on
`lastEvent` for replay but are not independently updated model state. Pending
release uses eight pure passes under an invariant-backed bound of at most eight
known operations per replica; this covers every acyclic dependency chain in the
recorded domain and is reported with the other run bounds.

### Network state

The model retains fixture messages in a set and represents outstanding schedule
deliveries as an unordered set. Apalache chooses either receiver's next eligible
delivery, so cross-receiver interleavings are explored while each generated
schedule case fixes only the receiver-local order. Explicit duplicate messages
remain ordinary named events.

### Events

Every transition stores one serializable tagged event in `lastEvent`. The event
schema is part of the verification tool and is decoded exhaustively by the
replay driver:

```text
Event =
  | BuildFixture(messageId, operations, heads)
  | DuplicateMessage(sourceMessageId, newMessageId)
  | Deliver(messageId, receiver)
  | CaptureCheckpoint(replica, checkpointId)
  | RequestDelta(sender, checkpointId, messageId)
  | RequestDeltaClaim(sender, knowledge, frontier, messageId)
  | RequestAll(sender, messageId)
  | Checkout(replica, checkpointId)
```

`BuildFixture` operations carry explicit identity, parent set, kind, exact
content, and directional origins. It creates messages that local edit methods
cannot express, including sparse identities, missing dependencies, equivalent
duplicates, and conflicts.

`BuildFixture` and `DuplicateMessage` change only the modeled network soup and
the replay harness message table. `Deliver` performs admission. Delivery of a
missing dependency followed by delivery of its parent exercises pending release;
there is no separate production retry action. `RequestDelta` uses a checkpoint
captured from the receiving replica. `RequestDeltaClaim` represents an external
Version claim, including an overclaim, as structured exact knowledge and
frontier. The replay driver independently encodes that structure as schema-2
Version JSON and parses it through `Version::from_json_string`; this avoids
embedding escaped JSON inside Quint strings while still testing public wire
ingress. A delta becomes an ordinary stored
message and is later applied with `Deliver`.

The driver reads this schema directly from ITF. Unknown tags or missing fields
are malformed trace errors. The suite does not depend on Quint’s experimental
`--mbt` metadata.

## Assurance obligations

The model groups related assertions into six named obligations.

### 1. Identity safety

- Every admitted identity maps to one equivalent operation.
- Reuse with different payload or dependencies produces `Conflict`.
- A conflict leaves admitted operations, pending operations, frontier, and
  knowledge unchanged.
- Equivalent duplicate delivery changes no authoritative observation.

### 2. Admission safety

- Every admitted operation has all declared dependencies admitted.
- An unready operation is present only in pending state.
- Pending state does not affect frontier or knowledge.
- Sequence adjacency does not add a dependency or make an operation ready.

### 3. Version exactness

- Knowledge equals the set of admitted identities.
- Every frontier member is admitted.
- Declared parents alone determine graph ancestry and frontier reduction;
  directional origins remain admission/readiness dependencies. An origin-only
  fixture checks this distinction against production.
- No frontier member is an ancestor of another frontier member.
- Every admitted maximal identity is in the frontier.
- A checkpoint frontier resolves to its exact declared transitive closure.

### 4. Delta exactness

For a peer Version freshly observed from the receiving replica:

- every locally admitted identity absent from peer knowledge is exported;
- no identity represented by peer knowledge is required for export;
- sparse gaps remain absent and therefore exportable;
- exported operations are dependency-safe;
- applying the delta equalizes admitted operation sets when all required
  operations are available.

A supplied Version is a peer knowledge claim. If it overclaims identities, the
sender may omit them. Gate V2 checks this behavior explicitly and does not claim
that `export_since` repairs a dishonest or stale external claim.

### 5. Delivery convergence

For non-conflicting operations and fair eventual delivery within the checked
finite model:

- dependency-respecting delivery order does not change the admitted operation
  map;
- duplicate delivery does not prevent convergence;
- delayed dependencies eventually release pending operations;
- replicas with equal admitted operation maps derive equal frontier and
  knowledge.

This is a finite-state, bounded claim. The result must state the bounds and
fairness assumptions.

### 6. Implementation correspondence

For each replayed prefix, the public implementation observation equals the model
observation whenever that observation is representable through the public wire
contract.

## Public observations

### Representable states

When `Version::to_json_string` succeeds, the replay driver observes:

- canonical frontier and sparse ranges from Version JSON;
- current text;
- historical checkout result when the event requests checkout;
- `SyncSession::pending_sync_count`;
- `SyncReport` applied, duplicate, and pending counts;
- the normalized exact operation set from `SyncMessage::to_json_string` for
  every message produced by `export_all`, `RequestDelta`, or
  `RequestDeltaClaim`;
- that a produced message’s `to_canonical_bytes()` is stable across public
  JSON round-trip; exact payload distinction is checked structurally through
  normalized operations rather than by duplicating the private byte codec;
- the raised `TextError` category, if any.

JSON arrays are normalized as semantic sets or ordered range lists according to
the schema contract. Raw string equality is not used for set-valued fields.

### Over-limit states

When Version serialization fails because a valid in-memory graph exceeds the
wire envelope, exact frontier and range observations are unavailable through the
public API. The replay driver checks only:

- the classified limit failure;
- absence of a Version token;
- stable current text;
- stable pending and report observations relevant to the event;
- no automatic reinterpretation as graph corruption.

Concrete limit construction remains in existing MoonBit tests. Gate V2 does not
generate 4,097-entry Quint state spaces.

## Replay driver

The native replay executable receives one or more ITF files.

For each trace it creates replicas through `TextState::new`, then maps every
event tag to one explicit harness or public action:

| Event | Replay action |
|---|---|
| `LocalInsert` | Validate that `scalar` contains one Unicode scalar, then call public `TextState::insert` |
| `LocalDelete` | Call public `TextState::delete` |
| `BuildFixture` | Build minimal independent schema-2 JSON, parse it with `SyncMessage::from_json_string`, and store it by `messageId`; no document call |
| `DuplicateMessage` | Store the same immutable message under `newMessageId`; no document call |
| `Deliver` | Apply the stored message through `SyncSession::apply` |
| `CaptureCheckpoint` | Store public `TextState::version()` under `checkpointId` |
| `RequestDelta` | Call `sender.sync().export_since(storedCheckpoint)`, record the returned message’s normalized exact operation set and canonical-byte round-trip stability, then store it by `messageId` |
| `RequestDeltaClaim` | Independently encode the modeled knowledge/frontier as schema-2 Version JSON, parse it with `Version::from_json_string`, call `export_since`, record the returned message observation, then store it |
| `Checkout` | Call public `TextState::checkout(storedCheckpoint)` and record its text |

The fixture builder maps the model shape to the exact wire keys `id`, `parents`,
`kind`, `content`, `origin_left`, and `origin_right`. Insert operations encode
the exact scalar string in `content`. Delete and undelete operations encode a
present `"content": null`, their target as `origin_left`, and a present
`"origin_right": null`. Optional insert origins are encoded under their
directional wire keys. The builder wraps operations and heads in a schema-2
`event-graph-walker/text-sync` envelope.

Fixture-origin events cover sparse identities, arbitrary declared dependencies,
delete/undelete targets, and conflicts that public local edit methods cannot
construct.

After every event, including harness-only network events, the driver captures
the public replica observation and compares it with the expected model
observation. Harness-only events must leave all document observations unchanged.
The driver stops at the first divergence.

The fixture builder is intentionally narrow. It supports only the operation
forms required by Gate V2. It is not a general replacement for the production
codec and does not call the production encoder to create inbound fixtures.

Failure output includes:

```text
trace file
trace seed
step index
event name
event arguments
expected outcome
observed outcome
expected observation
observed observation
first differing field
candidate commit
Quint version
Apalache version
```

Malformed ITF, malformed fixture generation, expected protocol rejection, and
model/implementation divergence are distinct failure categories.

## Mutation controls

The implementation contains reducer and replay mutations that target distinct
blind spots.

### Model mutation: implicit sequence parent

Treat `(agent,n-1)` as a parent of `(agent,n)` without a declared relationship.
A sparse same-agent trace must violate admission, knowledge, or delta exactness.

### Model mutation: flat per-agent maximum

Treat knowledge of `(agent,n)` as knowledge of every lower sequence. A sparse-gap
delta trace must violate delta exactness.

### Model mutation: premature admission

Admit an operation before all declared dependencies arrive. Pending and
admission obligations must fail.

### Replay mutation: incorrect expected Version

Alter one expected public Version observation. The replay driver must report a
correspondence divergence at the mutated step.

### Replay mutation: incorrect expected message heads

Alter the model-derived expected heads for an exported delta. The replay driver
must reject the otherwise structurally valid operation set.

### Coverage mutation: incomplete catalog observation

Replay only one generated schedule trace. Exact observed/required ID equality
must fail.

Full-operation conflict traces also send content, parent-set, left-origin, and
right-origin identity conflicts through the production public API.

## Existing suites invoked by Gate V2

### Gate V0

Run:

```bash
cd tools/verification/text_reference
./run.sh
./run_corpus.sh
```

This preserves independent visible-text evidence from the hand-written traces
and official corpus. Gate V2 does not use Gate V0’s origin translator as its
causal oracle.

### Codec and resource tests

Run the existing tests covering:

- Version encode/decode round-trip;
- schema-1 rejection;
- frontier/range consistency;
- 4,096 acceptance and 4,097 rejection;
- 512 KiB acceptance and oversized rejection;
- valid admitted history whose Version cannot be serialized.

Relevant files include:

- `text/sync_json_properties_test.mbt`;
- `text/text_wire_contract_test.mbt`;
- `text/version_resource_limit_wbtest.mbt`;
- `text/sparse_version_properties_wbtest.mbt`.

## Tooling

The suite pins exact tool versions in `package.json` and records them in output.
The initial versions are:

- Quint `0.32.0`;
- Apalache `0.62.2`;
- Java 21 or a documented Nix JDK 21 fallback.

Quint is used for:

- typechecking;
- named deterministic simulations;
- seeded randomized simulation;
- ITF output;
- bounded Apalache verification.

TLC is not a required Gate V2 backend. It may be used manually for a small
finite model, but its result is supplementary and must include measured runtime
and memory.

## Entry point

The completed suite provides one command:

```bash
cd tools/verification/text_sync_gate_v2
./run.sh
```

The command performs, in order:

1. tool-version checks;
2. Quint typechecking;
3. named sparse, pending, duplicate, conflict, checkpoint, and delta traces;
4. bounded safety verification;
5. seeded distributed simulations with recorded counts;
6. MoonBit public-API replay for every emitted trace;
7. reducer, replay, and coverage mutation controls;
8. existing codec/resource contracts;
9. Gate V0 hand-written and corpus differential runs.

Temporary traces are stored under a temporary directory unless a failure occurs.
On failure, the command preserves or prints the artifact path needed for replay.

## Implementation sequence

### Phase 1: package and API reconnaissance

- confirm the current public surface with `moon ide outline`, `doc`, and
  `peek-def`;
- inspect `text/pkg.generated.mbti`;
- confirm the standalone workspace resolves the current EGW source;
- record reused project and MoonBit core APIs.

No production definition is added for verification.

### Phase 2: smallest sparse trace

Implement two replicas and identities `(a,0)`, `(a,2)`, `(a,7)`.

The receiving replica knows `(a,0)` and `(a,7)`. Verify that `(a,2)` remains
absent from its knowledge and is exported. Run the flat-maximum mutation and
confirm failure.

### Phase 3: first public replay

Emit one ITF trace with explicit events. Implement the native driver and minimal
independent fixture builder. Compare Version, pending count, report counts, and
text after every prefix. Run the replay mutation.

This phase is the feasibility gate. Do not expand the state space until it
passes.

### Phase 4: pending and conflict

Add child-before-parent delivery, later dependency arrival, equivalent
duplicate, and conflicting identity reuse. Confirm that conflict and premature
admission mutations are detected.

### Phase 5: distributed soup

Add unordered messages, duplication, delayed delivery, and arbitrary delivery
choice. Keep finite bounds explicit and increase them only after measuring state
count, runtime, and memory.

### Phase 6: checkpoint and delta

Add current, historical, and multi-head checkpoints. Add fresh-peer delta and
explicit peer-overclaim cases. Compare public checkout and Version observations.

### Phase 7: integrated evidence

Run existing resource contracts and Gate V0. Record exact seeds, trace count,
state count, bounds, tool versions, candidate commit, runtime, and memory.

### Phase 8: independent review

Review:

- model-to-production event mapping;
- public observation completeness;
- fixture-builder independence;
- mutation detection;
- bounded guarantee wording;
- absence of production dependencies and hooks.

## Validation evidence

A successful run reports categories rather than one undifferentiated PASS:

```text
PASS: Quint typecheck
PASS: named sparse/pending/duplicate/conflict/checkpoint/delta traces
PASS: bounded safety verification under recorded bounds
PASS: seeded distributed simulation under recorded seeds
PASS: public MoonBit replay for every emitted trace
PASS: implicit-sequence-parent mutation detected
PASS: flat-maximum-knowledge mutation detected
PASS: premature-admission mutation detected
PASS: replay observation mutation detected
PASS: existing schema/resource contracts
PASS: Gate V0 hand-written differential traces
PASS: Gate V0 official corpus in both delivery modes
```

Skipped or unavailable evidence is reported as skipped or stopped, never as
passed.

## Acceptance criteria

Gate V2 is complete when:

- identity, admission, pending, Version, delta, and convergence obligations are
  encoded as pure model predicates, while implementation correspondence remains
  exclusively the MoonBit replay responsibility;
- sparse same-agent identities are explored without implicit causality;
- partial, duplicate, reordered, and conflicting delivery are first-class
  events;
- pending operations are observationally isolated;
- fresh-peer delta is exact across sparse gaps;
- peer knowledge overclaim behavior is documented and tested;
- every generated trace replays through public MoonBit APIs without divergence;
- representable and over-limit observation domains are not conflated;
- all reducer, replay, and coverage mutation controls fail for the expected
  reason;
- existing resource tests remain green;
- Gate V0 remains green;
- bounds, seeds, state counts, versions, runtime, memory, and candidate commit
  are recorded;
- no production API, dependency, white-box hook, or normal-CI requirement is
  added;
- an independent review finds no model/implementation correspondence blocker.

## Guarantee statement

When Gate V2 passes, the project may claim:

> Within the recorded finite model bounds, the schema-2 text authority model
> preserves identity uniqueness, declared-dependency admission, pending
> isolation, exact sparse knowledge, maximal frontier, conflict atomicity, exact
> fresh-peer delta, and convergence under the modeled delivery assumptions. All
> generated traces conform to the production MoonBit public API at every
> publicly observable prefix. Existing independent differential tests continue
> to establish visible text compatibility for their covered corpus, and concrete
> MoonBit tests continue to establish the documented Version resource envelope.

The project must not claim:

- an unbounded proof of distributed liveness;
- proof of all possible text projection behavior;
- protection against dishonest peer knowledge claims;
- a bound on resident history or outgoing sync message size;
- production recovery from an over-limit Version;
- verification of behavior outside the recorded model, trace, and resource
  bounds.

## Reuse check

Production APIs reused by replay:

- `TextState::new`;
- public local text mutations where applicable;
- `TextState::version`;
- `TextState::checkout`;
- `TextState::text`;
- `TextState::sync`;
- `SyncMessage::from_json_string`;
- `SyncMessage::to_canonical_bytes`;
- `SyncSession::apply`;
- `SyncSession::export_since`;
- `SyncSession::export_all`;
- `SyncSession::pending_sync_count`;
- `SyncReport` observation methods;
- `Version::to_json_string` and `Version::from_json_string`.

MoonBit core candidates to inspect and reuse in the standalone driver:

- `Json` for ITF and fixture parsing;
- `Map` and `Set` for normalized observations;
- `Array` and `Iter` for trace traversal;
- `String` and `Bytes` for wire and canonical-byte observations;
- `Option` and `Result` for explicit parser outcomes;
- `Buffer` or `StringBuilder` only if fixture construction requires incremental
  building.

The only new helper responsibilities permitted are:

- decode the bounded ITF event/observation subset;
- construct the minimal independent schema-2 fixture subset;
- normalize public observations;
- report the first model/implementation divergence.

These helpers remain inside the standalone verification module.
