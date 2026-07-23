# Migrating to v0.5

v0.5 is a source-breaking, wire-compatible release. Existing v0.4 wire
envelopes interoperate with v0.5 peers without data migration or codec
changes. v0.3 remains incompatible with both v0.4 and v0.5.

## Source compatibility scope

The public source break affects `text.Range` construction and inspection. Its
constructors use the new `TextError::InvalidRange` case. Other synchronization
wire envelopes and façade method signatures are unchanged from v0.4.

## `text.Range`

`Range` fields are now opaque. The previous public field access `.start` and
`.end` are replaced by methods:

```moonbit
// v0.4
let r = @text.Range::from_ints(0, 5)
let s = r.start
let e = r.end

// v0.5
let r = @text.Range::from_ints(0, 5) catch {
  @text.TextError::InvalidRange(start~, end~) => {
    // start > end
    return
  }
  error => raise error
}
let s = r.start()
let e = r.end()
```

Constructors `Range::new` and `Range::from_ints` now raise
`TextError::InvalidRange` when `start` > `end`. Code that exhaustively matches
`TextError` must add this case.

Every constructed range satisfies `start <= end`; no constructor silently
normalizes its input. The document-dependent bound check
`end <= current_length` remains in `TextState` mutation methods and raises
`TextError::InvalidPosition`.

## No data migration

v0.4 and v0.5 share the same schema-1 wire envelopes for `text`, `tree`,
and `container` synchronization. A v0.4 peer and a v0.5 peer can exchange
sync messages for the same document. No payload migration, re-encoding, or
version negotiation is required.

v0.3 arrays and mixed v0.3/v0.4 or v0.3/v0.5 synchronization remain
unsupported. Upgrade every v0.3 peer to at least v0.4 before adopting v0.5.

## Additive `peer_sync` packages

v0.5 adds three new public packages:

- `peer_sync` — peer-free synchronization policy core. Opaque `State`
  accepts semantic events and returns transport-neutral `Array[Decision]`
  values for bootstrap, incremental exchange, dependency recovery, and
  terminal escalation.
- `peer_sync/text` — text façade adapter. Maps `SyncReport` and sync errors
  into shared policy dispositions.
- `peer_sync/container` — container façade adapter. Same role for the
  container `Document`.

These packages do not store peer identity, versions, payloads, retry counters,
timers, or document state. The caller owns peer routing, retry budgets,
connectivity, scheduling, and transport, while causal pending operations remain
inside the text or container façade.

Adopt `peer_sync` when a runtime needs shared decisions for one remote
peer's synchronization lifecycle without coupling to a specific transport.

## Internal contributor note

The unused `Op::FromJson` implementation was removed from `internal/core`.
This package is not importable from downstream consumers, so there is no public
API impact. `Op::ToJson`, trusted constructors, and existing JSON wire shapes
remain available.

`RawVersion` and `OpRun` JSON decoding now validates non-empty agent identities
and non-negative sequences with sequence-range overflow protection.
