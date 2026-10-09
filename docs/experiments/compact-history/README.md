# Experimental compact accepted-history archive and direct restore

This draft adds a separate offline archive format and **fresh-document** importer. It does not replace schema 2 sync JSON, discard history, or restore into an existing live document. The format and API are explicitly experimental and should not be the sole durable copy of production data.

## Public API

```moonbit
let source = @text.TextState::new("writer-before")
source.insert(@text.Pos::at(0), "こんにちは 😀")
let archive = source.export_compact_experimental()
let expected_version = source.version().to_json_string()
// Persist these together; keep the expected Version in the application's trusted metadata.
let restored = @text.TextState::restore_compact_direct_experimental(
  archive, "new-unique-writer", expected_version,
)
assert_eq(restored.text(), source.text())
```

The executable version is `examples/compact_history_test.mbt`:

```sh
moon test examples/compact_history_test.mbt --target js
```

Both archive operations raise `TextError`. Unsupported/malformed archives, wrong expected Version and reused archive writer IDs reject before returning a usable document. Error detail strings and internal helper diagnostics are not a stable error-code interface. The writer must be new relative to the archive; globally unique live writer IDs remain the application's responsibility. Positions continue to count Unicode scalars, not UTF-16 code units, bytes or graphemes.

Only `export_compact_experimental` and `restore_compact_direct_experimental` are added to the public TextState façade. Opaque internal proof/graph types do not leak through it. The ordinary-replay comparison helper is test-only.

## What is retained

The archive contains all **accepted** Insert/Delete/Undelete operations, original identities, declared parents, left/right origins, content, and exact sparse Version/frontier. A table deduplicates actor strings; a run record implies subsequent identities and parent/left links only when those operations form the exact canonical insertion chain. General records remain explicit.

Pending/unaccepted packets and local UndoManager stacks, grouping and timestamps are omitted, matching the existing accepted-history scope. Accepted Delete/Undelete operations are retained. Start a new local UndoManager after restore; subsequent local edits, Undo/redo and ordinary peer deltas work. A 100k-character initial insertion already consumes the entire default **accepted-operation** budget: later editing can make export reject even when visible text stays the same size. Export preflights the same bounds and never silently truncates history.

This TextState archive rejects legacy raw-Document empty/multiscalar Insert operations. The existing schema 2 decoder is unchanged.

## Validation and ownership

1. Bound the UTF-8 input/depth and validate every record, actor index, integer, sequence expansion and cumulative resource budget before expanded Op allocation. JSON and compact-record trees are allocated earlier within the bounded input.
2. Reuse StructuralOp checks and canonical identity/dependency ordering. A narrowly proved one-run insertion chain can establish the identical unique order without Kahn sorting; malformed metadata never substitutes for structural validation. Equal and conflicting duplicate identities reject.
3. Own the input operations and prove every declared parent and optional origin resolves to an earlier operation. Origins/targets must name Inserts. Declared parents may name any operation kind and may contain distinct redundant ancestor edges. Origins are readiness dependencies, **not implicit causal parents**. There is no implicit same-writer predecessor or contiguous-sequence requirement.
4. Construct the graph/log once with deterministic destination LVs, parent-derived Lamport ranks, owned parent arrays, children, actor maxima, sparse membership and ascending childless causal frontier. Require exact archive heads and external Version before adoption.
5. Consume the private proof once, perform the existing canonical Fugue projection, derive indexes from that tree and verify final Version/heads/pending0 before publishing the new TextState. No prior live capability, cursor, pending packet or observer exists on the candidate. A fresh planner lifecycle does not simulate obsolete ACK counters.

This separates complete-history proof from the live incremental planner without omitting semantic validation. Internal graph helpers are not wire ingestion APIs. A failure after proof adoption consumes the proof but publishes no document. The index is derived, not a trusted serialized cache.

The existing canonical-operation shortlex comparator, Fugue lexical sibling comparator and delete winner rules remain distinct. Tests pin origins without causal parents, equal/reversed origins, redundant parents, sparse decreasing sequences, multiple same-actor heads and maximum Int sequences.

## Resource and integrity limits

| Resource | Limit |
|---|---:|
| Archive UTF-8 bytes | 16 MiB |
| JSON nesting | 16 |
| Actors / heads | 4096 each |
| Actor UTF-8 bytes total | 1 MiB |
| Version JSON UTF-8 bytes (each embedded/external token) | 512 KiB |
| Version sparse intervals (total across all actors) | 4096 |
| Expanded accepted operations | 100,000 |
| Parents per operation | 256 |
| Expanded dependency edges | 1,000,000 |
| Expanded identity bytes | 64 MiB |
| Inserted UTF-8 bytes | 400,000 |
| Raw sequence | 0 through 2,147,483,647 |

The existing schema-2 Version encoder and decoder enforce both Version limits, so they also apply to compact export and direct restore. The limits are inclusive and count encoded UTF-8 bytes and canonical sparse intervals, respectively. Fragmentation can therefore make export reject well below 100,000 accepted operations: one actor with sequences `0, 2, ..., 8192`, each causally following the previous operation, has only one head but 4097 intervals. Export rejects that history without truncating or mutating the source document; the corresponding 4096-interval history can round-trip when the other bounds are satisfied.

These are bounded input/expansion policies, not a 64 MiB heap ceiling or adversarial wall-time guarantee. The expected Version checks sparse membership and frontier, not payload authenticity. It is not a cryptographic digest/signature; an attacker who rewrites both archive and metadata is outside this integrity check. Applications still own atomic durable storage, authentication and future migration.

## Reproduce tests and benchmark

Use the repository's pinned compiler and normal dependency setup; do not vendor a second EGW copy or bypass verification:

```sh
just ci
moon test --target js -p dowdiness/event-graph-walker/text
moon bench --target js --release text/compact_history_benchmark_wbtest.mbt
```

The benchmark generates varied Markdown and a second history with 5,000 visible scalars and 95,000 accepted operations. Setup occurs outside timed closures. Both lanes consume the same compact archive, codec/order proof and external Version; ordinary apply versus direct assembly is the comparison. Both include first full text and keep that materialized string; unlike the historical Node harness, this runner does not additionally sum every UTF-16 code unit. Run without competing builds or benchmarks. The stock MoonBit benchmark runner is not the historical AB/BA harness and its output should be reported as a separate rerun.

`results/paired-*.json` preserves the five small raw feasibility data sets from the separately frozen Node prototype, including every warmup/sample and both compiled-engine hashes. These are **historical evidence**, not measurements of this adapted repository publication tree. Four AB/BA pairs per case, fresh documents, runtime warmed; module/fixture setup and GC excluded, decode through first full text/checksum included. No samples were dropped. Heap/RSS fields include the whole process and both lanes, not isolated engine peak memory.

| Historical fixture | Ordinary compact restore median | Direct median |
|---|---:|---:|
| 100k varied Markdown operations | 2033.91 ms | 1186.68 ms |
| 95k operations, 5k visible, Delete/Undelete churn | 2477.32 ms | 1461.90 ms |
| 9k operations, 5k visible, edited | 319.94 ms | 216.20 ms |
| Concurrent branches | 179.39 ms | 128.04 ms |
| Sparse actor sequences | 140.19 ms | 109.73 ms |

The old prototype also passed unchanged-peer bidirectional Unicode/Undo/delta checks and a separately extracted no-install Node demo. Those bundled-JS checks are supplementary; this PR's authoritative checks run against its actual source tree. Four pairs do not establish p95/tail behavior or parity with Automerge/Yjs. This remains a draft for review of format, API, proof and resource policy.
