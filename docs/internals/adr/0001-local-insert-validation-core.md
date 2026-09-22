---
status: accepted
---

# Keep local insert planning lightweight

For the `TextState::insert`, `TextState::replace_range`, and their undo-recording wrappers, the functional core will validate the complete edit request and produce a compact insert plan, while the imperative shell retains cursor and position-cache lookups, causal/LV allocation, CRDT commit, and undo recording. The implementation uses the two-pass validation approach (A): validate before commit, then let the existing shell iterate the original text. This preserves the existing per-codepoint CRDT semantics without copying the document or adding rollback state; normal user-facing edit errors are atomic, while internal invariant failures are outside the recoverable edit contract. A separate release-mode comparison found no consistent advantage for materialized codepoints, so A remains the default.
