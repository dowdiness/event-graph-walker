///| Item structure for FugueMax tree
///
/// ## Fugue Tree Model
///
/// The FugueMax tree (Weidner & Kleppmann 2023, "The Art of the Fugue",
/// arXiv:2305.00583, Section 4) is a rooted ordered tree that represents a
/// collaborative text sequence. Key properties:
///
/// - **Virtual root**: The tree has a sentinel root node (LV = -1) that is
///   never part of the visible document. All content nodes descend from it.
///
/// - **Parent and side**: Each non-root node has a parent and a side (Left
///   or Right). The side determines the node's position relative to its
///   parent in document order.
///
/// - **Document order**: The visible text is produced by in-order traversal
///   of the tree: left children (sorted), then the node itself, then right
///   children (sorted). Left children appear *before* the parent in the
///   document; right children appear *after*.
///
/// - **Sibling ordering**: Children on the same side of the same parent are
///   sorted by stable RawVersion identity: agent ID in lexical UTF-16 order,
///   then per-replica sequence. This matches the EG-walker reference ordering
///   regardless of destination-local operation arrival order.
///
/// - **Tombstones**: Deleted nodes are never removed from the tree. They
///   become tombstones (`deleted = true`) so that concurrent operations
///   referencing them can still resolve correctly. Tombstones are skipped
///   during visible-text traversal but participate in tree structure.

///|
/// Logical Version (local sequence number)
pub(all) struct Lv(Int) derive(Debug, Eq, Compare, Default, Hash)

///|
pub impl Show for Lv with fn output(self, logger) {
  logger.write_string(@debug.to_string(self))
}
/// Replica-local causal-graph handle for an operation.
///
/// Historically Fugue used this same integer as both the causal version handle
/// and the tree item identity. The container text-sync refactor splits those
/// concepts, but `Lv` remains the causal-graph-side handle.

///|
/// Per-tree item identity used by Fugue storage.
///
/// Existing code still uses `Lv` at most call sites. Later refactor slices will
/// migrate storage and merge logic to use `ItemId` where block-local sequence
/// identity is the real concern.
pub(all) struct ItemId(Int) derive(Debug, Eq, Compare, Default, Hash)

///|
pub impl Show for ItemId with fn output(self, logger) {
  logger.write_string(@debug.to_string(self))
}

///|
/// Lamport Timestamp for causal ordering
pub(all) struct Timestamp(Int) derive(Debug, Eq, Compare, Default)

///|
/// Replica identifier
pub(all) struct ReplicaId(String) derive(Debug, Eq, Compare)

///|
/// The root node's logical version sentinel
pub let root_lv : Lv = Lv(-1)

///|
/// Side of parent node where item is attached
pub enum Side {
  Left
  Right
} derive(Debug, Eq)

///|
pub impl Show for Side with fn output(self, logger) {
  logger.write_string(@debug.to_string(self))
}

///|
/// A node in the FugueMax tree, representing one unit of content (e.g. a character).
///
/// Items are never removed — deleted content becomes a **tombstone** (`deleted = true`)
/// so that concurrent operations that reference it can still resolve correctly.
pub(all) struct Item[T] {
  /// Current item identity.
  ///
  /// Today this is still an `Lv`, but the identity-splitting refactor is
  /// moving toward a separate `ItemId` so per-block storage no longer depends
  /// on global causal version numbering.
  id : Lv
  /// The content value (e.g. a `String` character).
  content : T
  /// Parent item in the Fugue tree. `None` means the parent is the virtual root (`root_lv`).
  parent : Lv?
  /// Which subtree of the parent this item belongs to.
  /// `Left` subtree items appear *before* the parent in document order;
  /// `Right` subtree items appear *after* the parent.
  side : Side
  /// `true` if the item has been deleted (tombstone). Tombstones remain in the
  /// tree so concurrent operations that reference this item remain valid.
  mut deleted : Bool
  /// Lamport timestamp of the winning Delete/Undelete op (0 = initial/no winner).
  mut deleted_ts : Int
  /// Agent ID of the winning Delete/Undelete op ("" = initial/no winner).
  mut deleted_agent : String
  /// `true` if the winner was an Undelete op, `false` if Delete or initial.
  mut deleted_is_undelete : Bool
  /// Explicit state for two-count merge tracking. Mirrors `deleted` for now;
  /// will replace it in Phase 2b.
  mut state : ItemState
  /// Number of active delete operations targeting this item (two-count merge).
  /// Managed exclusively by the merge code — FugueTree mutation methods do not touch it.
  mut delete_count : Int
  /// Lamport timestamp retained for causal metadata and diagnostics.
  timestamp : Timestamp
  /// Replica that created this item. Same-side siblings are ordered by this
  /// stable identity using lexical UTF-16 code-unit order.
  agent : ReplicaId
  /// Per-replica operation sequence. Together with `agent`, this is the
  /// stable event identity used by the EG-walker reference implementation.
  sequence : Int
} derive(Debug, Eq)

///|
pub impl[T : Debug] Show for Item[T] with fn output(self, logger) {
  logger.write_string(@debug.to_string(self))
}

///|
/// Compares two items to establish their order in the FugueMax sequence.
///
/// Parameters:
///
/// * `self` : The first item to compare.
/// * `other` : The second item to compare against.
///
/// Returns an integer indicating the relative order: negative if `self` comes
/// before `other`, zero if they are equal, positive if `self` comes after
/// `other`.
impl[T : Eq] Compare for Item[T] with fn compare(self, other) -> Int {
  let agent_cmp = self.agent.0.lexical_compare(other.agent.0)
  if agent_cmp != 0 {
    return agent_cmp
  }
  Compare::compare(self.sequence, other.sequence)
}

///|
/// Insert operation descriptor
pub(all) struct InsertOp[T] {
  id : Lv
  content : T
  origin_left : Lv? // None = document start
  origin_right : Lv? // None = no right constraint
  timestamp : Timestamp
  agent : ReplicaId
} derive(Debug)

///|
/// Create a new item
fn[T] Item::new(
  id : Lv,
  content : T,
  parent : Lv?,
  side : Side,
  timestamp : Timestamp,
  agent : ReplicaId,
  sequence : Int,
) -> Item[T] {
  {
    id,
    content,
    parent,
    side,
    deleted: false,
    deleted_ts: 0,
    deleted_agent: "",
    deleted_is_undelete: false,
    state: Inserted,
    delete_count: 0,
    timestamp,
    agent,
    sequence,
  }
}

///|
/// Check if item is visible (not deleted)
fn[T] Item::is_visible(self : Item[T]) -> Bool {
  self.state.is_visible(delete_count=self.delete_count)
}
