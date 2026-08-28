# PROTOTYPE: EG-walker reference compatibility Gate 0

This prototype asks whether the repository's public `text.TextState` façade can
produce the same visible text as the executable EG-walker reference
implementation.

It tests two distinct boundaries:

1. hand-written distributed command traces with unchanged replica identities;
2. the official diamond-types conformance corpus with its exact original
   identities, delivered both as a full batch and one operation at a time in
   reverse order with each delivery duplicated.

## Verdict

**GO for RawVersion sibling ordering.** The experimental MoonBit ordering change
from `(Lamport timestamp, MoonBit String order, destination-local LV)` to stable
`(agent, sequence)` RawVersion order makes all 15 hand-written traces match
`reference-frh@1.0.0` exactly.

**GO for Gate V0 delivery validation.** All 1,000 official corpus runs pass
with direct original identities in both full-batch and reverse/duplicate
single-operation delivery modes.

## Hand-written public-API traces

Run:

```sh
./tools/verification/text_reference/run.sh
```

Both drivers replay the same commands:

```text
replica NAME
insert NAME POSITION ASCII_SCALAR
delete NAME POSITION
sync FROM TO
sync-duplicate FROM TO
expect-converged NAME NAME...
```

The reference driver uses `reference-frh`. The MoonBit driver uses only:

- `TextState::new`;
- `TextState::insert` / `TextState::delete`;
- `TextState::sync().export_all()`; and
- `SyncSession::apply`.

Current result:

```text
RESULT: 15 matched, 0 diverged
GO: reference-frh and MoonBit text states matched
```

Trace 02 isolates JavaScript lexical agent ordering from MoonBit's default
shortlex `String::compare`. Trace 14 uses same-length agent IDs but different
causal depths, isolating RawVersion ordering from Lamport-first ordering. Trace
15 distinguishes UTF-16 code-unit order from Unicode scalar order with non-BMP
replica IDs.

## Official conformance corpus

Run:

```sh
./tools/verification/text_reference/run_corpus.sh
```

The runner pins:

- `josephg/egwalker-paper` commit
  `4d9bef55e4f2e3b3b8b0efe8f91cd35d34ed35a8`;
- `eg-walker-reference/testdata/conformance.json` SHA-256
  `95bdb544deca513441a50ea26a1c3ecbad116061c1d0fd6dde3175ea1e0bffd7`;
- `reference-frh@1.0.0` through `package-lock.json`;
- the installed `ListFugueSimple` JavaScript SHA-256
  `debf503de64aa1307fe93bb9a30c7d4f5d34257c5d11f65b5856f14443d9c4b1`.

The npm release records git head
`a58466d2b823e4474c7fbfd7b7828209d94c20c2`. Its
`test/list-fugue-simple.ts` is byte-identical to the source at the pinned paper
revision; `run_corpus.sh` additionally hashes the installed compiled oracle.

The corpus contains 1,000 runs and 45,294 insert/delete events.

`corpus_translate.mjs` uses the `ListFugueSimple` implementation shipped in the
pinned npm package to translate each positional event into stable Fugue origins.
It checks that replaying the translated reference primitives produces each
corpus run's independently supplied `endContent`, then emits the repository's
public v1 text-sync JSON. The same `ListFugueSimple` code derives and replays
origins, so this check establishes terminal text, not independent proof that
every translated origin is uniquely faithful.
MoonBit decodes that JSON with `SyncMessage::from_json_string` and applies it to
a fresh public `TextState`.

The runner performs two checks using the exact original `(agent, sequence)`
identities:

1. **Full-batch delivery.** Each translated graph is applied as one public
   `SyncMessage`.
2. **Delivery validation.** Every graph is replayed in reverse operation order,
   one operation per `SyncMessage`; each message is sent twice before the next
   operation. Final heads are preserved on the final wire message, but current
   admission authority is derived from operations, so this is not a separate
   head-integrity check. Both modes require zero pending operations, the
   corpus's terminal expected text, idempotent duplicate admission, Version
   JSON round-trip, and exact checkout text.

Current result:

```text
PASS: 1000 official conformance runs matched (full batch)
PASS: 1000 official conformance runs matched (reversed duplicate delivery)
```

The order-preserving identity embedding remains available to
`corpus_translate.mjs --order-embedding` as a diagnostic, but is not part of
canonical execution.

## Experimental MoonBit change

This branch is a prototype, not a production migration. It experimentally:

- carries each insert's stable per-replica sequence into `FugueTree`;
- compares same-side siblings by `agent.lexical_compare`, then sequence;
- uses the same comparator in `LvLocator`, preventing the indexed projection
  from drifting from Fugue tree order;
- threads `Op::seq()` through local and remote text projection; and
- keeps Lamport timestamp metadata for delete/undelete conflict handling;
- treats declared parents and origins, not the same-agent predecessor, as text
  admission dependencies;
- makes the causal graph the single authority for exact frontier and canonical
  per-agent sequence ranges, with opaque text `Version` as a façade;
- keeps sparse knowledge cold until first observation, then advances it at the
  same graph admission point as RawVersion identity;
- uses the frontier for checkout and exact range membership for
  `export_since`; and
- emits text Version schema 2 while retaining schema 1 decoding as a legacy
  contiguous-prefix contract.

Public text method signatures and the v1 sync-message JSON shape remain
unchanged. The serialized text Version shape is intentionally experimental and
changes to schema 2. The internal Fugue `insert` API requires an explicit
`sequence` argument, preventing projection adapters from silently substituting
a local LV for a stable event sequence.

A production change would still require an explicit compatibility decision,
persisted-state/mixed-version analysis, schema migration policy, and downstream
Canopy API validation. Container sequence semantics are unchanged.

## Gate V0 performance evidence

The first cache prototype rebuilt Version history after every local insert and
regressed the existing 1,000-character append benchmark to 211.91 ms native and
114.54 ms JS. A later text-owned incremental cache fixed the hot path but kept
causal authority and summary maintenance in separate modules.

Gate V0 now places a cold-to-hot summary in the causal graph. Before first
Version observation, admission pays no summary cost. Once observed, the same
graph admission that records RawVersion identity advances the hot summary.

| 1,000-character append | native | JS |
|---|---:|---:|
| pre-Gate baseline | 5.39 ms | 7.72 ms |
| graph summary still cold | 5.97 ms | 7.61 ms |
| graph summary heated first | 6.10 ms | 7.46 ms |

A cold 1,000-operation reconstruction is 82.79 µs native and 58.22 µs JS,
down from 384.50 µs and 204.30 µs in the text-owned sparse prototype. A warm
snapshot is 190 ns native and 84 ns JS for one contiguous agent. A deliberately
fragmented 32-agent × 32-range snapshot costs 55.38 µs native and 49.69 µs JS.
These are prototype measurements, not production performance claims.

## Guarantee boundary

This prototype establishes:

- exact visible-text agreement for 15 public distributed traces;
- duplicate sync idempotence and zero pending operations in those traces;
- exact expected-text agreement for all 1,000 official runs with direct,
  original identities, in both full-batch and reverse/duplicate delivery; and
- Version schema-2 round-trip and exact terminal checkout for every corpus run
  in both delivery modes; and
- bounded seeded sparse same-agent disconnect/reconnect convergence in the text
  package property suite (40 generated schedules); and
- insert/delete/undelete Version round-trip, exact checkout, and delta export.

It does not establish:

- arbitrary mixed-operation network partitions or random transport schedules;
- persistence behavior;
- full wire migration compatibility;
- compatibility between mixed old/new MoonBit replicas; or
- a migration policy for persisted operation logs.

Generated outputs and downloaded corpus data are ignored under `.out/` and
`.cache/`.
