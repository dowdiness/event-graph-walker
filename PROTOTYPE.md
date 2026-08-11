# PROTOTYPE — serialized checkpoint/restore gate

## Question

Does a serialized materialized state plus a tail remain materially faster on the
JavaScript target than full replay after including checkpoint capture/encode,
decode, and causal/log reconstruction?

This is throwaway prototype code. It does not change the public text facade,
`SyncMessage`, or a production persistence format.

## Run

The existing optimistic in-memory `Branch` benchmark is preserved:

```bash
NEW_MOON_MOD=0 moon bench --package internal/document --release
```

The serialized-state experiment is a one-command JS benchmark:

```bash
moon run --release --target js prototype/checkpoint_restore_js
```

It performs two warmups and then seven timed samples. Each sample reports its
full-replay time and all three checkpoint stages; summaries are median, mean,
minimum, and maximum in microseconds.

## Existing in-memory control

The prior wasm-gc control remains in `internal/document/checkpoint_prototype_benchmark.mbt`:

| Scenario | Mean | History shape |
|---|---:|---|
| Full `Branch::checkout` replay | 1.62 ms | 4,301 operations |
| 19-cycle materialized state + 1-cycle tail | 244.59 us | 214-operation tail |
| 10-cycle materialized state + 10-cycle tail | 1.45 ms | large tail |

That control is intentionally optimistic because it reuses an in-memory
`Branch`. The serialized experiment below is the follow-up that charges the
omitted capture, codec, and causal/log reconstruction costs.

## Checkpoint model

The checkpoint is deliberately explicit rather than Markdown-only or text-only.
For the causal cut it serializes:

- every admitted operation record, including local LV, stable agent/sequence
  identity, complete parent identities, content, and both Fugue origins;
- the causal-cut frontier; and
- every materialized Fugue item, including parent/side tree placement,
  content, tombstone bit, delete-winner timestamp/agent/type, item state, and
  delete-count tracker.

Decode rebuilds a fresh `OpLog` and causal graph by admitting every serialized
operation, then uses the prototype-only internal Fugue restore seam to rebuild
tree indexes from the complete item records. The tail is admitted and projected
through `Branch::merge_remote_ops`. The run checks operation-record identity,
final text, operation count, and complete materialized item/tombstone state
against full replay.

## JS result

The fair comparison first stores an encoded full-history string outside the
sample, then measures JSON decode, operation decode, causal/log reconstruction,
and full `Branch::checkout`. The checkpoint reopen path measures checkpoint JSON
decode, causal/log reconstruction, direct Fugue-tree restore, and tail apply.
Thus neither side includes disk I/O, while both sides pay their restore codec
and causal-state costs.

Five release-mode `moon run` launches were used, with seven samples per launch;
the table reports the median of the five run medians. Environment: Node
24.14.1, Moon 0.1.20260713 / moonc v0.10.4+2cc641edf.

| Fixture | Value |
|---|---:|
| Target operations | 4,301 |
| Checkpoint operations | 4,087 |
| Tail operations | 214 |
| Full-history UTF-8 JSON bytes | 904,002 |
| Checkpoint UTF-8 JSON bytes | 1,330,602 |
| Checkpoint tombstones | 2,023 |
| Final tombstones | 2,130 |

| Stage | Median |
|---|---:|
| Full replay from encoded history | 55.64 ms |
| Checkpoint capture + encode (write-time) | 35.79 ms |
| Checkpoint decode + restore | 62.99 ms |
| Tail apply | 1.90 ms |
| Checkpoint decode + restore + tail (reopen) | 64.76 ms |
| Checkpoint capture + reopen path | 102.05 ms |

All equivalence checks were true. On reopen, the serialized checkpoint path was
approximately **1.16x slower** than fair full replay. Including write-time
capture and encoding, it was approximately **1.83x** the full replay cost.

The tail itself is cheap; causal/log reconstruction is the dominant checkpoint
cost. The naive JSON representation therefore does **not** justify a durable
checkpoint API. A future design would need a cheaper causal-graph/OpLog restore
(or a compact indexed representation) while retaining complete history,
identity, and tombstone semantics.

## Excluded costs and limitations

- No disk, IndexedDB, network, compression, checksum, encryption, or browser
  scheduling cost is measured.
- The tail is already an in-memory array; tail transport/decode is excluded.
- Fixture construction and the full-replay expected-state setup are outside the
  timed samples.
- The JSON shape is prototype-only and is not `SyncMessage` or a compatibility
  promise. It has only minimal schema checks and no production resource limits.
- The restore helper is an internal, clearly marked throwaway seam. It is not a
  stable API and must not be copied into the public text facade.
- This is one deterministic single-replica history. It verifies retained
  tombstones and delete winners but is not a broad multi-replica convergence
  study.
