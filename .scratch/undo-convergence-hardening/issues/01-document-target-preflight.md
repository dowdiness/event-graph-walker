# 01 — Prevent poisoned causal state on target preflight failure

**What to build:** Ensure an unknown or structurally invalid undo target is rejected before the Document advances causal state, so a later normal edit remains exportable and peers still converge.

**Blocked by:** None — can start immediately.

**Status:** done

- [x] Target and causal/raw-version references are validated before local causal allocation.
- [x] Preflight failure leaves the Document version and exportable operation state unchanged.
- [x] A normal edit after the failure can be synchronized to a second peer.
- [x] Both peers converge after synchronization.
