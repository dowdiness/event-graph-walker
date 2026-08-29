# Same-agent sequence causality and version representation

**Status:** research result for the RawVersion compatibility prototype
**Question:** must `(agent, sequence=n)` causally descend from `(agent, sequence=n-1)`?

## Decision summary

A better design exists than either keeping the current causal-chain restriction or merely replacing the public version vector with sequence ranges.

The recommended model separates two facts that the current `text.Version` conflates:

1. an **exact causal checkpoint**, represented by the event graph's RawVersion frontier; and
2. an **exact knowledge summary**, represented by canonical per-agent sequence ranges.

The core representations should remain distinct. The existing opaque public `Version` may bundle both to preserve the ergonomics of `version()`, `checkout(version)`, and `export_since(version)`:

```text
Version
  frontier: canonical RawVersion antichain
  known:    canonical agent -> disjoint sequence ranges

Invariant: known is exactly the causal closure of frontier.
```

Operation identity remains `(agent, sequence)`. Declared parents/frontier remain the sole authority for causality. The receiver should not invent an implicit predecessor edge or readiness dependency. Local writers should still allocate sequence numbers monotonically and should normally use a fresh agent ID per editing session; that policy keeps the common case linear and compact without rejecting valid external event graphs.

Do **not** remove the ancestry check before the checkpoint and summary representations are migrated. Today that check is required to keep several flat-vector assumptions sound.

## Primary-source findings

### EG-walker assigns identity and causality independently

The official fuzzer keeps one global counter for each agent, chooses a random document for each edit, and then uses that document's current heads as the edit's parents. In particular, `consumeSeqs` advances the global agent counter while `docInsert` and `docDelete` pass `doc.oplog.cg.heads` to the causal graph. A later sequence from agent `c` can therefore be created on a document that has not observed `c`'s previous sequence.

Sources:

- [`test/fuzzer.ts`, agent counters and random document selection](https://github.com/josephg/eg-walker-reference/blob/7287f4bc2c054984838b3582a27b4fea8f6d8161/test/fuzzer.ts#L86-L133)
- [`test/fuzzer.ts`, explicit current-head parents](https://github.com/josephg/eg-walker-reference/blob/7287f4bc2c054984838b3582a27b4fea8f6d8161/test/fuzzer.ts#L26-L59)
- [`src/causal-graph.ts`, RawVersion, heads, entries, and per-agent mappings are separate](https://github.com/josephg/eg-walker-reference/blob/7287f4bc2c054984838b3582a27b4fea8f6d8161/src/causal-graph.ts#L14-L52)

The reference's full summary is not one maximum per agent. It stores a list of `[start, end)` ranges for each agent and derives those ranges from the actual per-agent mapping.

- [`VersionSummary`](https://github.com/josephg/eg-walker-reference/blob/7287f4bc2c054984838b3582a27b4fea8f6d8161/src/causal-graph.ts#L14-L19)
- [`summarizeVersion`](https://github.com/josephg/eg-walker-reference/blob/7287f4bc2c054984838b3582a27b4fea8f6d8161/src/causal-graph.ts#L356-L370)

This is direct evidence that EG-walker's agent sequence is stable identity/allocation order, not a causal proof.

### Diamond Types already implements the needed dual representation

Diamond Types distinguishes:

- `Frontier`: the exact antichain naming a causal point;
- `VersionSummary`: per-agent ranges of known sequences, used for synchronization; and
- `VersionSummaryFlat`: one next sequence per agent, valid only when agent sequence order and causal order coincide.

Its source explicitly says the flat representation is invalid when one agent submits changes on multiple branches.

- [`VersionSummary` and `VersionSummaryFlat` contract](https://github.com/josephg/diamond-types/blob/e143890a596aafdd7ba3e7ae25f9f3749f45acff/src/causalgraph/summary.rs#L16-L32)
- [Agent assignment owns full-summary construction](https://github.com/josephg/diamond-types/blob/e143890a596aafdd7ba3e7ae25f9f3749f45acff/src/causalgraph/summary.rs#L124-L137)
- [Full-summary intersection and missing-range handling](https://github.com/josephg/diamond-types/blob/e143890a596aafdd7ba3e7ae25f9f3749f45acff/src/causalgraph/summary.rs#L138-L239)
- [Causal graph entries retain explicit parent frontiers](https://github.com/josephg/diamond-types/blob/e143890a596aafdd7ba3e7ae25f9f3749f45acff/src/causalgraph/graph/mod.rs#L22-L52)

Diamond Types also recommends generating a new agent ID for every editing session. That is an allocation and collision-avoidance recommendation, not a receiver-side restriction on valid causal graphs.

- [ID uniqueness and fresh-session-agent recommendation](https://github.com/josephg/diamond-types/blob/e143890a596aafdd7ba3e7ae25f9f3749f45acff/src/lib.rs#L77-L126)
- [Parents define the version before an edit](https://github.com/josephg/diamond-types/blob/e143890a596aafdd7ba3e7ae25f9f3749f45acff/src/lib.rs#L129-L178)

The most useful conclusion is not simply “use ranges.” It is “use a frontier for causal state and ranges for peer knowledge.”

### Automerge and Yjs show the legitimate alternative design family

Automerge deliberately chooses a stricter actor model: its public documentation states that changes under one actor must be sequential. Local changes normally add the actor's previous change hash to dependencies. When editing a historical branch would violate that rule, current Automerge derives a concurrency-specific actor ID instead of reusing the base actor unchanged.

- [Sequential actor contract](https://github.com/automerge/automerge/blob/47908d6c04a0ce3fea0fa1d6b7f5ce6ba3e5792e/rust/automerge/src/lib.rs#L77-L86)
- [Previous actor change added to dependencies](https://github.com/automerge/automerge/blob/47908d6c04a0ce3fea0fa1d6b7f5ce6ba3e5792e/rust/automerge/src/automerge.rs#L436-L466)
- [Historical-branch actor isolation](https://github.com/automerge/automerge/blob/47908d6c04a0ce3fea0fa1d6b7f5ce6ba3e5792e/rust/automerge/src/automerge.rs#L1149-L1181)

Yjs similarly uses a client clock prefix. Its state vector records the next expected clock. Current Yjs can retain explicit `Skip` intervals, reports the first skip as the state-vector boundary, and rotates its local client ID if a remote transaction reveals that another client is using it.

- [Struct continuity, skips, and next expected clock](https://github.com/yjs/yjs/blob/567af9b41fe5e1290e0cfe7fcc025a9f98c514a0/src/utils/StructStore.js#L27-L113)
- [State vector stops at the first skip](https://github.com/yjs/yjs/blob/567af9b41fe5e1290e0cfe7fcc025a9f98c514a0/src/utils/StructStore.js#L116-L134)
- [Client-ID collision rotation](https://github.com/yjs/yjs/blob/567af9b41fe5e1290e0cfe7fcc025a9f98c514a0/src/utils/Transaction.js#L306-L315)

Thus there are two coherent families:

| Family | Identity policy | Causal checkpoint | Sync summary |
|---|---|---|---|
| Automerge/Yjs style | one linear writer per actor/client; rotate identity on branch/collision | hashes/heads or integrated struct state | compact actor/client prefix |
| EG-walker/Diamond style | agent sequence allocates unique IDs and may span branches | explicit frontier | per-agent sequence ranges |

The current MoonBit implementation combines the EG-walker wire identity and explicit parents with the stricter Automerge/Yjs actor-chain policy. That hybrid is the source of the incompatibility.

## Repository impact

### What already supports the general model

The MoonBit `CausalGraph` already stores explicit parents, an exact frontier, and a `RawVersion -> LV` map. `add_version_with_seq` accepts an explicit sequence independently of parents. `OpRun` only merges ranges after proving actual parent/origin continuity, so its RLE optimization does not require every adjacent same-agent sequence globally to form a chain.

Relevant sources:

- `internal/causal_graph/graph.mbt`: `entries`, `version_map`, `frontier`, `add_version_with_seq`
- `internal/core/op_run.mbt`: `can_merge` checks the actual predecessor parent and origin
- `internal/oplog/oplog.mbt`: local edits use the current graph frontier
- `internal/oplog/oplog.mbt`: `get_frontier_raw` already exposes stable frontier identities

The general EG-walker graph is therefore already present. The incompatibility is concentrated in validation and flattened version representations.

### What currently relies on the strict chain

1. `internal/oplog/remote_admission_planner.mbt` treats `(agent, seq-1)` as an implicit applicability dependency and requires it to be reachable from declared parents.
2. `text/types.mbt` stores one maximum sequence per replica; `Version::includes` interprets every lower sequence as present.
3. `text/sync.mbt::export_since` filters deltas using that flat inclusion test.
4. `text/text_doc.mbt::checkout` reconstructs a causal frontier using only each replica's maximum operation.
5. `internal/causal_graph/version_vector.mbt::from_frontier/to_frontier` collapses and reconstructs using maxima; a same-agent fork cannot round-trip.
6. `internal/branch/branch.mbt` exposes that version-vector conversion for checkout and advance.
7. Container has its own predecessor ordering, ancestry, and Lamport assumptions in `container/sync_protocol.mbt`; changing text/core does not automatically make container correct.
8. `CausalGraph::add_version_inner` currently inserts into `version_map` without independently rejecting a duplicate RawVersion. The façade and OpLog conflict checks protect current normal paths, but a generalized core must enforce identity uniqueness at its own boundary.

## Alternatives considered

### Keep the strict chain

This remains a valid product choice if the repository explicitly adopts the Automerge/Yjs model and rotates agent IDs whenever a branch is created. It gives the smallest summaries and simplest checkout. It fails the stated EG-walker/diamond exact-compatibility goal and rejects the official corpus.

### Rotate or virtualize agent IDs on forks

This is an excellent **local producer policy** and should be retained as a recommendation. It is not a compatible receiver policy: rewriting incoming identities changes RawVersion equality, visible sibling ordering, origin references, persisted history, and official corpus identities. A separate internal “writer lane” would merely recreate frontier/range bookkeeping under another name.

### Require the predecessor to be known but not causal

This avoids claiming an ancestor edge, but invents a delivery dependency absent from the event graph. A valid operation can remain pending forever because of an unrelated missing predecessor. It also does not fix checkout: the maximum same-agent operation still does not dominate the other branch.

### Ranges only

Ranges accurately describe which operations are known but do not identify the exact causal antichain for a historical checkout. Two different frontiers can have the same operation inventory only if the entire graph state is treated as the checkpoint; arbitrary historical points still require heads.

### Frontier only

A frontier exactly identifies a causal point when the graph is available. It is insufficient for efficient unknown-peer delta negotiation: a sender that does not know one of the peer's heads cannot infer the peer's complete known set.

### Frontier plus contiguous prefixes

This is safe as a conservative transition: advertise only the longest known prefix and resend sparse operations above it. Duplicate admission is idempotent. Permanent holes can cause unbounded repeated retransmission, and a flat prefix loses the precise intersection/remainder behavior already implemented upstream by Diamond Types.

### Dotted vectors, vectors with exceptions, interval tree clocks, or hashes

These structures solve related causal-context problems, but the upstream-compatible range summary is simpler and already matches RawVersion allocation. Content hashes would replace the identity and ordering contract; interval-tree identities or dotted vectors would add a second identity algebra without removing the need for explicit EG-walker parents. They are not better for this repository.

## Recommended design

### Functional core

Maintain two deterministic values:

```text
CausalCheckpoint = canonical RawVersion frontier
HaveSummary      = canonical agent -> disjoint, non-adjacent sequence ranges
```

Rules:

- operation causality comes only from declared parents;
- readiness depends only on declared parents and semantic targets such as Fugue origins;
- RawVersion uniqueness is checked before graph mutation;
- same RawVersion plus equal payload is an idempotent retransmission;
- same RawVersion plus different payload is a terminal identity conflict;
- Lamport timestamps are derived from declared parents, not an implicit sequence predecessor;
- `HaveSummary` is exactly the operation set in the checkpoint's transitive closure;
- uncertain or malformed peer knowledge causes extra export, never omission.

### Imperative shell and public façade

Keep the internal types separate. For compatibility and usability, the opaque public `text.Version` may contain both. Then:

- `TextState::version()` captures current raw frontier plus its closure summary;
- `checkout(version)` resolves and uses only the exact frontier, while validating availability;
- `export_since(version)` uses the exact range summary for set difference;
- sync messages continue to carry explicit operation parents and heads;
- local sessions allocate monotonically and preferably use fresh session agent IDs, preserving one-range common cases;
- pending operations are excluded until admitted into the authoritative graph.

No per-operation vector clock is added. Linear histories remain one range and continue to RLE-compress. Extra cost is proportional to actual holes/branches, which is the information that a flat maximum currently discards.

## Throwaway feasibility probe

A detached worktree at `f9a724c` removed only three pieces of implicit-predecessor behavior:

- predecessor injection in text batch ordering;
- predecessor injection in core admission readiness; and
- the check that declared parents transitively reach the predecessor.

No identity, parent, origin, projection, Fugue, or corpus translation was changed. Replaying the official corpus with its **exact original identities** then produced:

```text
PASS: 1000 official conformance runs matched
```

This is stronger than the earlier order-embedding result: after RawVersion sibling ordering is fixed, the predecessor restriction is the only blocker observed by full-batch terminal-text replay across all 1,000 runs. It does not validate `Version`, `export_since`, checkout, partial delivery, or persistence.

The existing text suite then passed 139 of 142 tests. The three failures all encode old strict-chain consequences: direct fork rejection, discarding a formerly malformed pending root, and pending-limit accounting after that discard. They identify contracts that must be replaced deliberately; they are not unrelated projection regressions.

The first run also shows why deleting the check without migrating `Version` is unsafe. It contains root operation `c:4` with no parents after `c:0..3` were allocated elsewhere. A receiver may validly know `c:4` without knowing `c:0..3`; the current flat `c:4` maximum would falsely report all lower sequences as present and would reconstruct the wrong checkout frontier.

## Safe migration sequence

1. **Characterize before changing behavior.** Add red tests for same-agent independent branches, sparse delivery, reordered/duplicate delivery, exact checkout, delta completeness, and conflicting duplicate identities. Replay the official corpus with exact identities.
2. **Add the representation behind internal APIs.** Implement canonical sequence ranges and checkpoint/frontier conversion using existing `CausalGraph::get_frontier`, `lv_to_raw`, `raw_to_lv`, and graph traversal. Keep v1 behavior unchanged initially.
3. **Harden the core identity boundary.** Reject duplicate RawVersions in `CausalGraph` rather than relying only on façades. Preserve `OpRun::can_merge`'s actual-chain predicate.
4. **Prototype text v2.** Remove implicit predecessor readiness/ancestry only for the new text contract; derive Lamport time from declared parents; make checkout and export consume the new checkpoint/summary. Do not silently change container semantics.
5. **Run exact conformance and migration evidence.** Require all hand-written traces and all 1,000 official runs without identity embedding, plus saved-version/canonical-byte fixtures and partial-sync tests. Benchmark one-range, many-agent, and pathological sparse-range cases.
6. **Choose the compatibility boundary explicitly.** Either version the text-version/sync schema or document a deliberate breaking release. Only after that decision should the old flat `Version`, sequence-fork rejection tests, and strict-chain documentation be removed.

## Gate V0 validation update

The prototype now implements the recommended representation at the causal
authority. `CausalGraph` owns the exact frontier, RawVersion index, and a
cold-to-hot canonical per-agent range summary. The opaque text `Version` is only
a façade over a defensive graph snapshot. Schema 2 carries that snapshot;
schema 1 is rejected because a flat maximum cannot represent sparse knowledge.
Checkout asks the graph to resolve a maximal frontier and prove summary equality
against its resident closure; `export_since` uses exact range membership.

This placement was selected only after comparing four alternatives: reorganize
the text-owned cache, feed a text reducer with new Document receipts, split
checkpoint and peer knowledge into public types, or move summary ownership to
the graph. The graph-owned design is the only one that removes both duplicated
range algorithms and mutation-path cache hooks. It also matches Diamond Types'
placement of `VersionSummary` under causal-graph agent assignment rather than a
text façade.

Validation on this branch establishes:

- 15/15 hand-written public traces match `reference-frh`;
- 1,000/1,000 official runs pass with original identities as full batches;
- 1,000/1,000 pass as reverse-order, one-operation messages with each delivery
  duplicated;
- both corpus modes round-trip Version schema 2 and checkout the expected
  terminal text;
- 40 seeded sparse same-agent disconnect/reconnect schedules converge through
  exact `export_since`;
- insert/delete/undelete versions round-trip, checkout, and export exact deltas;
  and
- text, causal-graph, OpLog, document, branch, and container targeted native
  suites pass.

The initial implementation rebuilt Version after every local insert and caused
a measured regression. A text-owned incremental cache repaired that cost but
left duplicate authority. The graph-owned cache now stays cold until first
observation, then advances at graph admission. A 1,000-character append is
5.97 ms native/7.61 ms JS while cold and 6.10 ms/7.46 ms after heating
(baselines 5.39 ms/7.72 ms). Cold 1,000-operation reconstruction is
82.79 µs native and 58.22 µs JS, versus 384.50 µs and 204.30 µs in the
text-owned sparse prototype. Warm one-range snapshots are sub-microsecond; a
32-agent × 32-range fragmented snapshot is 55.38 µs native and 49.69 µs JS.
These figures characterize the prototype; they are not production optimization
claims.

Persistence, container causality, arbitrary mixed-operation partition
schedules, and symbolic proof remain outside Gate V0. Text schema 1/2
interoperability is deliberately excluded by the breaking schema-2 contract.

## Final recommendation

Adopt **frontier plus sparse sequence ranges**, with fresh per-session agent IDs as a producer optimization rather than a receiver validity rule. This is stronger than the earlier “range-based Version” proposal: it preserves exact causal checkout, exact delta knowledge, official EG-walker identities, and compact linear histories without conflating sequence allocation with causality.
