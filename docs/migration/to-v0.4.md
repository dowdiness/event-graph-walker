# Migrating to v0.4

v0.4 is intentionally source- and wire-incompatible with v0.3. Upgrade every
peer for a document together. There is no legacy decoder, mixed-version mode,
or payload migration heuristic.

## Replica IDs

`TextState::new`, `TreeState::new`, and `Document::new` now reject an empty
replica ID. Supply a globally unique ID for each running replica instance, not
merely each user. A user opening the same document on two devices or tabs
needs two IDs. Synchronization rejects two different payloads that claim the
same `(replica_id, sequence)` identity.

## Synchronization APIs

Replace raw operation APIs with the façade-owned session:

```moonbit
let message = alice.sync().export_all()
let report = bob.sync().apply(message)

let peer_version = bob.version()
// ...alice changes...
let delta = alice.sync().export_since(peer_version)
bob.sync().apply(delta)
```

Removed APIs include public raw operation arrays, public versioned-operation
structs, internal `RawVersion`/`VersionVector`/`TreeOp` signatures,
`tree.export_ops`, `tree.apply_remote_op`, container
`export_sync_message`/`export_sync_message_since`/
`apply_remote_sync_message`, and `CausalSnapshot::from_graph`.

`text`, `tree`, and `container` each own opaque `Version`, `SyncMessage`,
`SyncSession`, and `SyncReport` types. Tree node IDs are likewise owned by
their façade. Do not exchange an opaque type from one façade with another.

Only pending counts are observable:

```moonbit
let count = doc.sync().pending_sync_count()
doc.sync().clear_pending_sync()
```

Pending payloads are deliberately private.

## JSON and canonical bytes

Transport JSON is a strict schema-1 envelope with a façade-specific format:

- `event-graph-walker/text-sync`
- `event-graph-walker/tree-sync`
- `event-graph-walker/container-sync`

Versions use the matching `*-version` format. v0.3 arrays, unknown schema
versions, unknown fields, negative identifiers, duplicate entries,
dependency cycles, conflicting identities, and invalid content are rejected.
Decode the payload with the same façade that encoded it.

`SyncMessage::to_canonical_bytes()` returns domain-separated deterministic
bytes for hashing and signing. It is not a transport decoder or a second wire
format.

## Resource limits

Default constructors use `Limits::default()`:

| Budget | Default |
| --- | ---: |
| Encoded JSON input | 16 MiB |
| Decoded operations | 100,000 |
| Pending operations | 10,000 |
| Parents per operation | 256 |

Use the validating custom constructor and `new_with_sync_limits` to override
them:

```moonbit
let limits = @sync.Limits(
  max_encoded_bytes=4 * 1024 * 1024,
  max_decoded_operations=20_000,
  max_pending_operations=2_000,
  max_parents_per_operation=128,
)
let doc = @text.TextState::new_with_sync_limits("device-uuid", limits)
```

Messages that exceed a limit or fail validation leave observable document and
pending state unchanged.

## Text behavior

An empty local insert is now a complete no-op: it changes no text, version,
undo state, or exported operation count. An empty insert received from the
v0.4 protocol is invalid.

Public versions are version vectors keyed by replica ID. `export_since`
filters by stable identity membership, so it remains portable even when two
peers assign different local logical-version numbers. `checkout` rejects a
version whose referenced maximum sequence is unavailable locally.
