# Text epoch cutover verification

Native-only application protocol prototype built exclusively on the public
`text` and `sync` packages.

## Seams under test

- Public EGW text seam: `TextState`, `Version`, `SyncSession`, and `SyncMessage`.
- Pure protocol seam: epoch, quiescence, submission identity, receipt, and
  cursor decisions.
- In-memory shell seam: ordered application of already validated decisions.
  This shell demonstrates behavior; it is not a production durability adapter.

## Behavioral matrix

| Context | Event | Required result |
|---|---|---|
| Active current epoch | new valid submission | apply once, allocate cursor, retain canonical receipt |
| Current epoch, any phase | same key and canonical bytes | return original receipt without applying |
| Current epoch, any phase | same key and different canonical bytes | reject before mutation |
| Any phase | stale epoch | reject before sync JSON decode or EGW mutation |
| Quiescing | new submission | reject before mutation |
| Active | request tail from current `(epoch, cursor)` | return ordered entries strictly after cursor |
| Any phase | request tail from stale epoch | reject; never reinterpret the cursor |
| Cutover | build baseline | split on Unicode scalar boundaries and emit bounded schema-2 pages |
| Cutover | apply baseline pages | fresh receiver converges to exact visible text and Version |
| Cutover | build failure | old generation remains current |
| Cutover | publish baseline for captured quiesced text | build an independent receiver, then atomically replace the current generation and retain the old generation |
| Cutover | publish unrelated baseline | reject without changing the old generation |
| New generation | old operation | reject as stale; never feed it to EGW |
| Expired/unknown old submission | reconnect | no automatic CRDT replay; report manual conflict path |

## Non-goals

- Production database or filesystem persistence
- P2P inventory reconciliation
- Shallow snapshots or baseline item identities
- Operation translation across epochs
- Presence, cursor, or typing-indicator migration
- Binary transport, compression, Merkle trees, or Negentropy

## Validation

```bash
nu ./run.nu
moon fmt baseline.mbt server.mbt baseline_test.mbt server_test.mbt
moon info
```

`Server` is an in-memory reference shell. Before a submission becomes
observable, it reconstructs a candidate from the committed log and applies the
new message to that disposable candidate. A raised or partial EGW admission can
therefore mutate only the discarded candidate. Baseline reconstruction is also
completed before publication state changes.

This copy-on-write reference strategy establishes protocol atomicity but is not
a production performance design. A production adapter must instead
transactionally commit the EGW mutation, canonical request bytes, cursor, log
entry, and receipt before acknowledging.
