# PROTOTYPE: EG-walker reference compatibility Gate 0

This prototype asks whether the repository's public `text.TextState` façade can
produce the same visible text as the executable EG-walker reference
implementation.

It tests two distinct boundaries:

1. hand-written distributed command traces with unchanged replica identities;
2. the official diamond-types conformance corpus after an order-preserving
   identity embedding that isolates Fugue ordering from MoonBit's stricter
   admission policy.

## Verdict

**GO for RawVersion sibling ordering.** The experimental MoonBit ordering change
from `(Lamport timestamp, MoonBit String order, destination-local LV)` to stable
`(agent, sequence)` RawVersion order makes all 15 hand-written traces match
`reference-frh@1.0.0` exactly.

**Not yet GO for full diamond-types compatibility.** The first official corpus
run contains a later operation from replica `c` that branches without causally
descending from `c`'s previous sequence. `reference-frh` accepts this event
graph; MoonBit's public sync admission rejects it with:

```text
operation does not causally descend from its replica predecessor
```

This is the first observed protocol/admission blocker. Because admission stops
there, the exact-identity check does not establish that it is the only remaining
incompatibility.

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

The runner performs two checks:

1. **Exact identity characterization.** It preserves original `(agent,
   sequence)` identities and confirms that the first reported rejection is
   MoonBit's linear per-replica predecessor rule.
2. **Ordering isolation.** It maps every original event ID to a unique synthetic
   replica ID. The mapping is order-isomorphic to JavaScript's UTF-16 lexical
   `(agent, sequence)` order. Parents, origins, operation kinds, content,
   delivery order, and expected text are unchanged.

Current result:

```text
EXPECTED BLOCKER: exact corpus identities violate MoonBit's linear per-replica admission rule
PASS: 1000 official conformance runs matched
```

The second result establishes terminal visible-text compatibility of the
experimental Fugue ordering and projection for these translated runs. It does
**not** prove exact wire/event-history compatibility, faithful origins by an
independent oracle, or partial-delivery behavior because the identity embedding
deliberately bypasses one admission rule and each graph is applied as one batch.

## Experimental MoonBit change

This branch is a prototype, not a production migration. It experimentally:

- carries each insert's stable per-replica sequence into `FugueTree`;
- compares same-side siblings by `agent.lexical_compare`, then sequence;
- uses the same comparator in `LvLocator`, preventing the indexed projection
  from drifting from Fugue tree order;
- threads `Op::seq()` through local and remote text projection; and
- keeps Lamport timestamp metadata for delete/undelete conflict handling.

No external `text` API or v1 sync JSON shape changes. The internal Fugue
`insert` API now requires an explicit `sequence` argument, preventing projection
adapters from silently substituting a local LV for a stable event sequence.

A production change would still require an explicit compatibility decision,
persisted-state/mixed-version analysis, documentation updates, and review of
the linear per-replica admission rule.

## Guarantee boundary

This prototype establishes:

- exact visible-text agreement for 15 public distributed traces;
- duplicate sync idempotence and zero pending operations in those traces;
- exact expected-text agreement for all 1,000 official runs after the stated
  order-preserving identity embedding; and
- a deterministic counterexample to exact corpus admission.

It does not establish:

- full diamond-types wire compatibility;
- acceptance of arbitrary branching histories from one replica ID;
- compatibility between mixed old/new MoonBit replicas; or
- a migration policy for persisted operation logs.

Generated outputs and downloaded corpus data are ignored under `.out/` and
`.cache/`.
