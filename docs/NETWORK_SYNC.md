# Network Synchronization for CRDT Collaboration

> **📚 HISTORICAL RECORD — does not match the current integration.** This document describes a pre-restructure design with TypeScript classes (`LambdaEditor`, `NetworkSync`) that no longer exist in `examples/web/src/`. The current network integration uses the MoonBit `text/` and `container/` sync APIs (`SyncMessage::to_json_string` / `from_json_string`, `apply_remote_sync_message`) exposed through the generated WASM FFI; wiring lives in the canopy parent repo at `examples/web/`. The architecture diagram and protocol notes below remain conceptually relevant; the API reference section does not.

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
(Deterministic ordering based on agent IDs and Lamport timestamps)
```

### Network Messages

```typescript
interface SyncMessage {
  type: 'ops' | 'version_vector' | 'request_sync';
  sender: string;              // Agent ID
  ops?: string;                // JSON-encoded operations
  version_vector?: string;     // JSON-encoded version vector
}
```

## API Reference

The previous TypeScript `LambdaEditor` and `NetworkSync` wrapper classes have
been removed. Network sync is now driven directly through the MoonBit public
API (exposed via WASM FFI):

- **Serialize**: `SyncMessage::to_json_string`
- **Deserialize**: `SyncMessage::from_json_string`
- **Apply remote message** (text-only): `TextState::sync().apply(msg)`
- **Apply remote message** (full document): `Document::apply_remote_sync_message(msg) -> SyncReport`
- **Export since a known version**: `TextState::sync().export_since(ver)` / `Document::export_sync_message_since(ver)`
- **Export full state**: `TextState::sync().export_all()` / `Document::export_sync_message()`
- **Version tracking**: `Version::to_json_string` / `Version::from_json_string`

See `docs/EXAMPLES.md` for worked sync, undo, and checkout examples. Transport
wiring (WebRTC + signaling) lives in the canopy parent repo at `examples/web/`.

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
- Version vectors are used for efficient frontier tracking (already implemented)

## Advanced: Custom Network Layer

You can implement your own network layer using the `sync()` API on `TextState`:

1. Export all operations: `doc.sync().export_all()`
2. Export operations since a known version: `doc.sync().export_since(ver)`
3. Broadcasting via your transport (WebSocket, HTTP, etc.)
4. Receiving operations and calling: `doc.sync().apply(msg)`

Example:

```typescript
// Send all operations
const msg = doc.sync().export_all();
myTransport.send(msg);

// Or send only new operations since the peer's last known version
const msg = doc.sync().export_since(peerVersion);
myTransport.send(msg);

// Receive operations
myTransport.onMessage((data) => {
  doc.sync().apply(data);
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
- [x] Version vectors for efficient frontier compression (implemented)
- [ ] Delta encoding for reduced bandwidth
- [ ] Document rooms/channels
- [ ] Presence awareness (cursor positions, user names)
- [ ] Operation compression (gzip, brotli)
- [ ] Reconnection handling with state sync
- [ ] Offline support with eventual consistency
