# Migration Guides

This directory contains migration guides for breaking API changes, protocol schema transitions, and major version upgrades.

---

## Guide Index

| Target Upgrade | Type | Guide | Summary |
| :--- | :--- | :--- | :--- |
| **Text Schema 2** | Protocol / Wire | [Text Schema 2 Migration](text-schema-2.md) | Coordinated breaking upgrade for text peers and persisted `Version` checkpoints. |
| **v0.5.0** | Source API | [Migrating to v0.5](to-v0.5.md) | Opaque `text.Range` fields with validated constructors raising `TextError::InvalidRange`. |
| **v0.4.0** | Source & Wire | [Migrating to v0.4](to-v0.4.md) | Breaking protocol changes and source updates from v0.3. |
| **Undo API** | Source API | [Migrating the Undoable API](undo-api.md) | Transitioning custom Undoable adapters to `Applied` and `Stale` result handling. |

---

## Upgrade Recommendations

1. **Upgrading within the v0.5.x - v0.8.x series:**
   - Releases between v0.5.0 and v0.8.0 are backwards-compatible over the network (wire-compatible). Existing peers and serialized checkpoints do not require data migration.
   - Text synchronization protocols use `schema: 2` across this series.
   - Review [CHANGELOG.md](../../CHANGELOG.md) for incremental feature additions and bug fixes.
2. **Upgrading from v0.4 to v0.5:**
   - Refer to [Migrating to v0.5](to-v0.5.md). Wire format remains compatible.
3. **Upgrading from v0.3 or earlier:**
   - Refer to [Migrating to v0.4](to-v0.4.md) followed by subsequent release notes.
