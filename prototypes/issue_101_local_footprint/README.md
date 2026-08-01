# PROTOTYPE — Issue #101 local mutation footprint evidence

This throwaway logic prototype asks one question:

> Can an exact-head-bound same-writer candidate provide non-mutating local
> footprint evidence and safe continuation, and can a conservative encoded-byte
> upper bound be proven from the current public EGW API?

It compares two in-memory commit lifecycles:

1. replace the active `Document` with the fully restored candidate;
2. apply the candidate's exact delta back to the unchanged source.

The exact head combines `Version` with the full canonical bytes. The prototype
also reproduces stale-head rejection, four-operation deltas, subsequent writer
continuation, fresh-replica encoding differences, non-rollback transaction
behavior, body-encoding growth, and 0/100/499-record reconstruction timing.

Run from the repository root:

```sh
just prototype-issue-101
```

Enter one action key and Return. State is in memory and the screen is fully
redrawn after every action. Nothing is persisted.

The canonical interactive command is sufficient to inspect every logic case.
For cross-backend reconstruction timing, run the optional batch mode with
`just prototype-issue-101-batch <native|js|wasm-gc|wasm>`.

## Result

PROTOTYPE COMPLETE.

At the public sync seam, complete replay into a fresh in-memory `Document`
carrying the same authority writer identity empirically produced an
observationally exact CRDT successor while leaving the source unchanged. One
node plus three properties emitted four operations. A fence combining `Version`
and full canonical bytes rejected a candidate after the source advanced. These
are executable oracle observations, not a formal proof of a production commit
protocol.

Both experimental commit lifecycles reproduced the candidate's exact canonical
successor and then continued the same writer without node-identity or operation
loss:

- replacing the active `Document` with the candidate;
- applying the candidate delta back to the unchanged source.

Neither lifecycle is a production-ready generic commit boundary. Candidate
replacement observably loses prior local undo availability because full sync
replay does not restore local history. Delta-back preserves the source's prior
`can_undo` availability, while an empty-history replay probe confirms that the
candidate command is not recorded as a local undo group. The candidate gate now
requires zero source pending operations in addition to the exact head. The
prototype still assumes process-local exclusive writer ownership and an atomic
external head/persistence fence. A serializable `SyncMessage` is evidence, not
writer authority.

A different replica produced the same operation count but different canonical
bytes, and a raised `Document::transaction` retained its generated operation.
Neither is a valid exact preflight substitute.

The conservative-bound branch remains unavailable from the current public API.
Exact body and command inputs are known, but generated counters, timestamps,
causal parents, and fractional positions are private, and exact bytes become
public only after mutating a candidate. The ASCII/escaped/Unicode scenarios are
useful oracle fixtures, not a no-underestimation proof.

### Reconstruction measurements

The optional batch command reports the median of five release-profile samples
inside one process. For this recorded table, that command was invoked manually
in five isolated processes per backend, and the table reports the median of the
five process medians. Each sample performs complete JSON replay into the same
writer identity, appends one node plus three properties, and exports canonical
full-sync bytes. Values are microseconds. Reproduce the process matrix by
running `just prototype-issue-101-batch <target>` five times for each target.

Environment: Moon `0.1.20260713`, moonc `v0.10.4+2cc641edf`, Node `v24.14.1`,
Linux x86_64 WSL2.

| Existing records | Operations after command | Canonical bytes | Native | JS | wasm-gc | wasm |
|---:|---:|---:|---:|---:|---:|---:|
| 0 | 6 | 903 | 117 | 2,128 | 454 | 1,156 |
| 100 | 406 | 64,329 | 15,829 | 42,171 | 29,399 | 47,590 |
| 499 | 2,002 | 320,782 | 142,752 | 299,768 | 195,437 | 366,038 |

At the 499-record boundary, complete reconstruction costs roughly 143–366 ms
at the median depending on backend. It remains a slow correctness oracle or an
exceptional candidate-swap mechanism, not the normal per-command path.

## Non-goals

- no production API;
- no persistence CAS, process lease, or crash recovery;
- no application schema or budget values;
- no claim that `Document::transaction` is rollback;
- no promotion of a serializable `SyncMessage` into writer authority.
