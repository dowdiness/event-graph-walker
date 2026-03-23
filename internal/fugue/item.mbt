///| Item structure for FugueMax tree

///|
/// Logical Version (local sequence number)
pub(all) struct Lv(Int) derive(Show, Eq, Compare, Default, Hash)

///|
/// Lamport Timestamp for causal ordering
pub(all) struct Timestamp(Int) derive(Show, Eq, Compare, Default)

///|
/// Replica identifier
pub(all) struct ReplicaId(String) derive(Show, Eq, Compare)

///|
/// The root node's logical version sentinel
pub let root_lv : Lv = Lv(-1)

///|
/// Side of parent node where item is attached
pub enum Side {
  Left
  Right
} derive(Show, Eq)

///|
/// A node in the FugueMax tree, representing one unit of content (e.g. a character).
///
/// Items are never removed — deleted content becomes a **tombstone** (`deleted = true`)
/// so that concurrent operations that reference it can still resolve correctly.
pub(all) struct Item[T] {
  /// Local version of this item. Unique within the tree.
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
  /// Lamport timestamp used as the primary sort key when ordering siblings
  /// that share the same parent and side.
  timestamp : Timestamp
  /// Replica that created this item. Used as a deterministic tiebreaker when
  /// two siblings have equal Lamport timestamps.
  agent : ReplicaId
} derive(Show, Eq)

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
impl[T : Eq] Compare for Item[T] with compare(self, other) -> Int {
  // First compare by Lamport timestamp for causal ordering
  let ts_cmp = self.timestamp.compare(other.timestamp)
  if ts_cmp != 0 {
    return ts_cmp
  }

  // If timestamps equal, compare by agent for deterministic tiebreaking
  let agent_cmp = self.agent.compare(other.agent)
  if agent_cmp != 0 {
    return agent_cmp
  }

  // If agents equal, compare by ID
  self.id.compare(other.id)
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
} derive(Show)

///|
/// Create a new item
fn[T] Item::new(
  id : Lv,
  content : T,
  parent : Lv?,
  side : Side,
  timestamp : Timestamp,
  agent : ReplicaId,
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
    timestamp,
    agent,
  }
}

///|
/// Check if item is visible (not deleted)
fn[T] Item::is_visible(self : Item[T]) -> Bool {
  not(self.deleted)
}
