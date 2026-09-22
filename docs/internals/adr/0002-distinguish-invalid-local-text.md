---
status: accepted
---

# Distinguish invalid local text from sync failures

The local-insert pilot uses a dedicated `TextError::InvalidText(detail~)` category rather than reporting malformed insert input as a synchronization failure. Validation remains fail-fast in the existing order: position, empty-input no-op, then Unicode validity. This keeps the local-edit boundary explicit, preserves actionable diagnostics such as `malformed UTF-16`, avoids scanning text when the position is already invalid, and makes invalid local text a normal, atomic edit error without changing the existing classification of malformed remote synchronization content.
