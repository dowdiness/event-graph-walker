# PROTOTYPE — checkpoint/restore gate

## Question

Can a materialized CRDT state at a causal cut plus a small tail avoid the
prefix replay cost observed during Loomark archive reopen?

This experiment uses the existing internal `Branch` state as an optimistic
in-memory checkpoint. It deliberately excludes checkpoint serialization,
decode, and capture cost. A favorable result is only evidence to design a
real durable checkpoint; it is not a production API or format.

## Run

From this worktree:

```bash
NEW_MOON_MOD=0 moon bench --package internal/document --release
```

The prototype is throwaway and must not be merged into `main`. Keep only the
measured verdict and validated invariants in the implementation issue.

## Result

Run on wasm-gc at EGW commit `29f10ec`:

| Scenario | Mean | History shape |
|---|---:|---|
| Full `Branch::checkout` replay | 1.62 ms | 4,301 operations |
| 19-cycle materialized state + 1-cycle tail | 244.59 us | 215-operation tail |
| 10-cycle materialized state + 10-cycle tail | 1.45 ms | large tail |

The small-tail path is approximately **6.6x faster** than full replay. A large
tail removes most of the benefit. This is an optimistic upper bound: it reuses
an in-memory `Branch` and excludes checkpoint capture, serialization,
deserialization, validation, and the public `TextState` restore path.

**Verdict:** direct materialized state plus a bounded tail is worth prototyping,
but this is not yet evidence for a durable public API. The next experiment must
measure checkpoint capture/restore cost and verify public `export_all`, identity,
tombstone, and convergence semantics.
