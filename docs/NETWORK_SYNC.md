# Network Synchronization for CRDT Collaboration

Event Graph Walker supplies strict JSON codecs and synchronization state
machines, but no transport, signaling, authentication, persistence, or key
management. The Canopy parent repository supplies the demo WebRTC integration.
The current text protocol is a breaking schema-2 contract for both SyncMessage
and Version. It intentionally rejects schema 1 rather than guessing sparse
knowledge from a flat maximum. Tree and container retain their own schema-1
contracts; façade payloads are never interchangeable.

This document describes how to use the network synchronization feature for real-time collaborative editing.

## Architecture

The network sync implementation uses:
- **WebSocket** for signaling and peer discovery
- **WebRTC Data Channels** for peer-to-peer operation broadcasting
- **eg-walker CRDT** for conflict-free merging

```
┌─────────────┐     WebSocket      ┌─────────────────┐      WebSocket     ┌─────────────┐
│   Browser   │ ◄─────Signaling───►│ Signaling Server│◄────Signaling─────►│   Browser   │
│   Peer A    │                     └─────────────────┘                    │   Peer B    │
└─────────────┘                                                            └─────────────┘
       │                                                                          │
       └────────────────────────WebRTC Data Channel───────────────────────────────┘
                            (Direct peer-to-peer CRDT operations)
```

## Quick Start

> **Note:** `event-graph-walker` is a submodule of the parent **canopy** repo. The web UI, signaling server, and build wiring live in the parent repo at `examples/web/`. The commands below assume you are in the canopy parent repo (one level above this submodule).

### 1. Start the Signaling Server

The signaling server coordinates peer discovery and WebRTC setup:

```bash
# From the canopy parent repo
cd examples/web
node signaling-server.js
```

The server will start on `ws://localhost:8080` by default.

### 2. Build and Start the Web Interface

```bash
# Build event-graph-walker for JavaScript (from the submodule)
cd event-graph-walker
moon build --target js

# Install and start the web dev server (from the parent canopy repo)
cd ../examples/web
npm install  # first time only
npm run dev
```

### 3. Open Multiple Browser Windows

1. Open `http://localhost:5173` in multiple browser windows/tabs
2. Click "Connect to Network" in each window
3. Start typing in one window - changes appear in all connected windows!

## How It Works

### Operation Broadcasting

When you type in the editor:

1. **Local Edit** - Text is inserted/deleted locally
2. **CRDT Operation** - MoonBit creates a CRDT operation with causal metadata
3. **Broadcast** - Operation is serialized to JSON and sent to all peers via WebRTC
4. **Remote Merge** - Each peer receives the operation and calls `doc.sync().apply(msg)`
5. **Convergence** - The eg-walker ensures all peers converge to the same state

### Conflict Resolution

The CRDT automatically resolves conflicts:

```
Peer A types "Hello" at position 0
Peer B types "World" at position 0 (concurrently)

Result: Both peers converge to either "HelloWorld" or "WorldHello"
(Deterministic ordering based on stable agent ID and per-agent sequence)
```

### Network Messages

```typescript
interface SyncMessage {
  type: 'sync';
  facade: 'text' | 'tree' | 'container';
  sender: string;              // globally unique replica-instance ID
  payload: string;             // exact façade SyncMessage JSON envelope
}
```

Do not parse or rewrite `payload` in the transport. Decode it with the matching
MoonBit façade. Text SyncMessage and Version envelopes use schema 2 and strict
exact-field validation. Text Version carries an exact RawVersion frontier and
canonical per-agent half-open sequence ranges. Tree and container envelopes
remain schema 1. Unknown fields and every unsupported schema are rejected.

## API Reference

The previous TypeScript `LambdaEditor` and `NetworkSync` wrapper classes have
been removed. Network sync is now driven directly through the MoonBit public
API (exposed via WASM FFI):

- **Serialize**: `SyncMessage::to_json_string`
- **Deserialize**: `SyncMessage::from_json_string`
- **Apply remote message** (text-only): `TextState::sync().apply(msg)`
- **Apply remote message**: `state.sync().apply(msg) -> SyncReport`
- **Export since a known version**: `state.sync().export_since(ver)`
- **Export full state**: `state.sync().export_all()`
- **Version tracking**: `Version::to_json_string` / `Version::from_json_string`

The façades expose parallel operations, but their opaque messages and versions
are not interchangeable. The text schema-2 contract does not change tree or
container version semantics.

For text, the causal graph owns two facts exposed behind one opaque `Version`:
its frontier names the exact checkout checkpoint, while its range summary names
the operations known in that frontier's causal closure. The graph keeps this
summary cold until first observation and then advances it with identity
admission. `export_since` uses the summary for exact set difference. `checkout`
resolves a maximal frontier and validates that the resident closure equals the
supplied summary before returning a view.
Declared operation parents, not adjacent sequence numbers, define text
causality.

Text Version decoding has a fixed wire boundary: at most 512 KiB encoded, 4,096
frontier identities, 4,096 agent entries, and 4,096 total sequence ranges.
Excess input fails with `LimitExceeded`: `EncodedBytes` classifies the byte
boundary and the existing `DecodedOperations` kind classifies every decoded
Version cardinality boundary. There is no
truncation or schema fallback. A local history whose sparse Version exceeds the
boundary requires full-resync or operational remediation; it must not publish a
partial knowledge claim.

`to_canonical_bytes()` produces deterministic schema-2 bytes under the
`event-graph-walker:text-sync:v2` domain for hashing or signing after
validation. It is not a binary transport decoder.

### Peer-sync policy companion

Use `peer_sync` when a runtime needs shared decisions for one remote peer's
bootstrap, incremental exchange, dependency recovery, and terminal failure.
Its opaque `State` accepts semantic events and returns fresh
`Array[Decision]` values. It does not store peer identity, versions, payloads,
retry counters, timers, or document state.

The `peer_sync/text` and `peer_sync/container` adapters normalize façade
`SyncReport` and error values into the shared policy dispositions.

The caller retains the original report or error for diagnostics and owns peer
routing, retry budgets, connectivity, scheduling, and transport envelopes.
Causal pending operations remain inside the text or container façade.

For package responsibilities and worked examples, see the
[peer synchronization companion overview](../README.md#peer-synchronization-companion)
and [sync examples](EXAMPLES.md). Transport wiring (WebRTC + signaling) lives
in the canopy parent repo at `examples/web/`.

## Signaling Server API

The signaling server accepts WebSocket connections and handles these message types:

### Client → Server

```json
// Join the network
{
  "type": "join",
  "agentId": "user-123..."
}

// WebRTC offer
{
  "type": "offer",
  "to": "peer-id",
  "from": "my-id",
  "offer": { /* RTCSessionDescription */ }
}

// WebRTC answer
{
  "type": "answer",
  "to": "peer-id",
  "from": "my-id",
  "answer": { /* RTCSessionDescription */ }
}

// ICE candidate
{
  "type": "ice_candidate",
  "to": "peer-id",
  "from": "my-id",
  "candidate": { /* RTCIceCandidate */ }
}
```

### Server → Client

```json
// New peer joined
{
  "type": "peer_joined",
  "peerId": "new-peer-id"
}

// Current peer list
{
  "type": "peer_list",
  "peers": ["peer-1", "peer-2", ...]
}

// Peer left
{
  "type": "peer_left",
  "peerId": "departed-peer-id"
}
```

## Deployment

### Production Signaling Server

For production use, deploy the signaling server with:

```bash
# Set custom port (from canopy/examples/web/)
PORT=3000 node signaling-server.js

# Or use a process manager
pm2 start signaling-server.js --name canopy-signaling
```

### Environment Variables

- `PORT` - WebSocket server port (default: 8080)

### Security Considerations

⚠️ **Important**: This implementation is for development/demo purposes. For production:

1. **Add Authentication** - Verify peer identities
2. **Use WSS** - Encrypt WebSocket connections with TLS
3. **Rate Limiting** - Prevent abuse of signaling server
4. **TURN Server** - Add TURN server for NAT traversal
5. **Access Control** - Implement room/document-level permissions

## Troubleshooting

### "Connection failed" Error

- Ensure signaling server is running: `cd examples/web && node signaling-server.js` (from canopy parent repo)
- Check console for WebSocket connection errors
- Verify port 8080 is not blocked by firewall

### Peers Not Connecting

- Check browser console for WebRTC errors
- Ensure both peers are connected to signaling server
- Try refreshing both browser windows
- Check NAT/firewall settings (may need TURN server)

### Changes Not Syncing

- Verify both peers show "Connected (1 peer)" status
- Check browser console for merge errors
- Ensure operations are being broadcast (check Network tab)

### Performance Issues

- Reduce broadcast frequency (increase debounce timeout)
- Use delta encoding for large documents
- Text uses exact frontiers plus per-agent sequence ranges; flat version vectors
  remain limited to chain-preserving package contracts

## Advanced: Custom Network Layer

You can implement your own network layer using the `sync()` API on `TextState`:

1. Export operations with `doc.sync().export_all()` or `export_since(ver)`
2. Encode the opaque message with `to_json_string()`
3. Broadcast that string via your transport
4. Decode received strings with `SyncMessage::from_json_string`
5. Apply only the validated message with `doc.sync().apply(msg)`

Example:

```typescript
// Send all operations as the exact schema-2 string.
const payload = doc.sync().export_all().to_json_string();
myTransport.send(payload);

// Or send only operations absent from the peer's Version.
const deltaPayload = doc
  .sync()
  .export_since(peerVersion)
  .to_json_string();
myTransport.send(deltaPayload);

// Decode at the façade seam before applying.
myTransport.onMessage((payload) => {
  const message = SyncMessage.from_json_string(payload);
  doc.sync().apply(message);
  updateUI();
});
```

## References

- [eg-walker Paper](https://arxiv.org/abs/2409.14252) - The CRDT algorithm
- [WebRTC Data Channels](https://developer.mozilla.org/en-US/docs/Web/API/WebRTC_API/Using_data_channels)
- [CRDT Implementation Guide](./EG_WALKER_IMPLEMENTATION.md)
- [Branch System Documentation](./WALKER_USAGE.md)

## Future Improvements

- [ ] Persistent storage with operation log replay
- [x] Exact text frontier plus sparse sequence-range delta summary (prototype)
- [x] Reject text schema 1 at the breaking schema-2 boundary
- [ ] Delta encoding for reduced bandwidth
- [ ] Document rooms/channels
- [ ] Presence awareness (cursor positions, user names)
- [ ] Operation compression (gzip, brotli)
- [ ] Reconnection handling with state sync
- [ ] Offline support with eventual consistency
