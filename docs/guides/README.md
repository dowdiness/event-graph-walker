# Guides and Worked Examples

Practical how-to guides and integration patterns for building collaborative applications with `event-graph-walker`.

---

## Guide Index

| Guide | Description | Target Audience |
| :--- | :--- | :--- |
| **[Worked Examples](examples.md)** | Step-by-step code walkthroughs for text/tree sync, undo/redo, error handling, and historical checkout. | All users |
| **[Network Synchronization](network-sync.md)** | Architectural patterns for integrating CRDT sync with WebSocket, WebRTC, and transport layers. | Application architects & networking engineers |
| **[Walker Usage](walker-usage.md)** | Lower-level APIs for causal DAG traversal, branch manipulation, and oplog queries. | Advanced users & custom CRDT integrators |

---

## Suggested Learning Path

1. Start with **[Worked Examples](examples.md)** to understand how replicas create and exchange mutations.
2. If building a client-server or peer-to-peer app, read **[Network Synchronization](network-sync.md)** for transport-agnostic message wiring.
3. Consult **[Walker Usage](walker-usage.md)** only if you need lower-level control over the causal graph beneath the public facade APIs.
