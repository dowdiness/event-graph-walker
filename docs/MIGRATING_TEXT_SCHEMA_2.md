# Migrating to text schema 2

Text schema 2 is a breaking protocol boundary. Upgrade every text peer that can
exchange operations or versions for one document before reconnecting them.
There is no schema-1 decoder, downgrade encoder, capability negotiation, or
mixed-peer mode.

Tree and container payloads are unaffected.

## What changed

Both text envelopes now use `schema: 2`:

- `event-graph-walker/text-sync`
- `event-graph-walker/text-version`

Canonical text SyncMessage bytes use the domain separator
`event-graph-walker:text-sync:v2`. Existing hashes and signatures over v1
canonical bytes are not reusable.

Text operation IDs remain `(replica_id, sequence)`, but sequence adjacency no
longer implies causality. Declared `parents` define the causal graph. A text
Version contains:

- `frontier`: the exact maximal RawVersion identities of the causal cut;
- `ranges`: canonical per-replica half-open sequence ranges naming every known
  identity in that frontier's closure.

A flat per-replica maximum cannot represent holes or same-replica branches and
is not accepted.

## Required migration

1. Stop text synchronization for the document.
2. Upgrade every process that encodes or decodes text SyncMessage or Version.
3. Discard persisted schema-1 text Versions. Recreate checkpoints by loading the
   owning document under the new implementation and calling `version()`.
4. Resume synchronization only after all text peers emit schema 2.

Persisted operation archives need application-specific migration. If an archive
stores complete operations with IDs, declared parents, content, origins, and
targets, decode it with its historical reader and replay the operations into a
new document before producing schema-2 checkpoints. Do not translate a flat
schema-1 Version into synthetic ranges.

## Failure behavior

`SyncMessage::from_json_string` and `Version::from_json_string` reject schema 1
as malformed text payloads. This fail-fast behavior prevents silent delta
omission and incorrect checkout.

## Verification checklist

- all connected text peers emit schema 2;
- canonical-byte hashes or signatures are regenerated under the v2 domain;
- saved schema-1 Versions are removed or deliberately invalidated;
- a current Version round-trips through JSON;
- `checkout(version())` reproduces current text;
- `export_since(peer.version())` converges after reordered and duplicate
  delivery;
- tree and container peers continue using their existing façade contracts.
