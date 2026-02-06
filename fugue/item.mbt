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
/// Item in the sequence - represents a character or text chunk
pub(all) struct Item[T] {
  id : Lv // LV that created this item
  content : T // The content (genericized)
  parent : Lv? // Parent item ID in tree (None for root)
  side : Side // Which side of parent (Left or Right)
  deleted : Bool // Is this item deleted (tombstone)
  timestamp : Timestamp // Lamport timestamp for tie-breaking
  agent : ReplicaId // Agent that created this item (for deterministic tiebreaking)
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
  { id, content, parent, side, deleted: false, timestamp, agent }
}

///|
/// Mark item as deleted
fn[T] Item::mark_deleted(self : Item[T]) -> Item[T] {
  { ..self, deleted: true }
}

///|
/// Mark item as visible (revive tombstone)
fn[T] Item::mark_visible(self : Item[T]) -> Item[T] {
  { ..self, deleted: false }
}

///|
/// Check if item is visible (not deleted)
fn[T] Item::is_visible(self : Item[T]) -> Bool {
  not(self.deleted)
}
