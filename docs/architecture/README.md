# Architecture and Algorithm Design

In-depth conceptual guides and design specifications for the core algorithms powering `event-graph-walker`.

---

## Document Index

| Document | Topic | Description | Status |
| :--- | :--- | :--- | :--- |
| **[eg-walker Implementation](eg-walker.md)** | Core Algorithm | Implementation mechanics of the event-graph-walker CRDT algorithm and FugueMax integration. | Active |
| **[Undo Manager Design](undo-manager.md)** | Selective Undo | Design rationale for distributed undo/redo, stale operation handling, and compensating edits. | Active |
| **[Formal Specification](formal-specification.md)** | Invariants & Laws | Mathematical models, algebraic laws, and formal invariants of the sequence and tree CRDTs. | Active / Reference |
| **[RLE Design Plan](rle-design.md)** | Data Compression | Planned design for Run-Length Encoded oplog compression. | Deferred / Planned |

---

## Related Reading

- [Original eg-walker paper](https://arxiv.org/abs/2409.14252)
- [Original Fugue paper](https://arxiv.org/abs/2305.00583)
- [Architecture Decision Records (ADRs)](../internals/adr/)
