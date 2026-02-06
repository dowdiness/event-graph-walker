///| FugueMax tree implementation
/// Maximal non-interleaving list CRDT
/// https://arxiv.org/abs/2305.00583

///|
/// FugueTree - maintains ordered sequence with CRDT properties
pub struct FugueTree[T] {
  mut items : @immut/hashmap.HashMap[Lv, Item[T]] // Map from LV to Item
  mut length : Int // Total items (including deleted)
} derive(Show)

///|
/// Creates a default empty FugueTree with a virtual root node.
///
/// Requires `T : Default` so a dummy content value can be stored in the root.
///
/// Example:
///
/// ```moonbit
/// let tree : FugueTree[String] = FugueTree::new()
/// inspect(tree.visible_count(), content="0")
/// ```
///
pub fn[T : Default] FugueTree::new() -> FugueTree[T] {
  FugueTree::make(T::default())
}

///|
/// Creates an empty FugueTree with a specified root content value.
///
/// This is the more general constructor that doesn't require the Default trait.
pub fn[T] FugueTree::make(root_content : T) -> FugueTree[T] {
  let root_item = Item::new(
    root_lv,
    root_content,
    None,
    Left,
    Timestamp(0),
    ReplicaId("root"),
  )
  let mut items = @immut/hashmap.new()
  items = items.add(root_lv, root_item)
  { items, length: 0 }
}

///|
/// Get item by ID
#alias("_[_]")
pub fn[T] FugueTree::get(self : FugueTree[T], id : Lv) -> Item[T]? {
  self.items.get(id)
}

///|
/// Get all visible (non-deleted) items in tree order
pub fn[T : Eq] FugueTree::get_visible_items(
  self : FugueTree[T],
) -> Array[(Lv, Item[T])] {
  let result = []
  self.traverse_tree(root_lv, result, visible_only=true)
  result
}

///|
/// Get all items (including tombstones) in tree order
pub fn[T : Eq] FugueTree::get_all_items(
  self : FugueTree[T],
) -> Array[(Lv, Item[T])] {
  let result = []
  self.traverse_tree(root_lv, result, visible_only=false)
  result
}

///|
/// Count visible (non-deleted) items
pub fn[T : Eq] FugueTree::visible_count(self : FugueTree[T]) -> Int {
  self.get_visible_items().length()
}

///|
/// Fold over visible items in tree order
pub fn[T : Eq, A] FugueTree::fold(
  self : FugueTree[T],
  init~ : A,
  f : (A, Item[T]) -> A,
) -> A {
  let items = self.get_visible_items()
  items.fold(init~, fn(acc, entry) {
    let (_, item) = entry
    f(acc, item)
  })
}

///|
/// Iterate over visible items in tree order
pub fn[T : Eq] FugueTree::iter(self : FugueTree[T]) -> Iter[(Lv, Item[T])] {
  self.get_visible_items().iter()
}

///|
/// Convert tree to text by folding over visible items.
/// Convenience method for FugueTree[String].
pub fn FugueTree::to_text(self : FugueTree[String]) -> String {
  self
  .fold(init=StringBuilder::new(), fn(sb, item) {
    sb.write_string(item.content)
    sb
  })
  .to_string()
}

///|
/// Insert an item using FugueMax integration algorithm
pub fn[T] FugueTree::insert(self : FugueTree[T], op : InsertOp[T]) -> Unit {
  // Find correct parent and side using FugueMax algorithm
  let (parent, side) = self.find_parent_and_side(
    op.origin_left,
    op.origin_right,
  )

  // Create item with found parent and side
  let item = Item::new(op.id, op.content, parent, side, op.timestamp, op.agent)

  // Add to tree
  self.add_item(item)
}

///|
/// Delete an item (mark as deleted)
pub fn[T] FugueTree::delete(
  self : FugueTree[T],
  id : Lv,
) -> Unit raise FugueError {
  match self[id] {
    Some(item) => {
      let deleted_item = item.mark_deleted()
      self.items = self.items.add(id, deleted_item)
    }
    None => raise FugueError::MissingItem(id~)
  }
}

///|
/// Undelete an item (revive tombstone). Idempotent for already-visible items.
pub fn[T] FugueTree::undelete(
  self : FugueTree[T],
  id : Lv,
) -> Unit raise FugueError {
  match self[id] {
    Some(item) =>
      if item.deleted {
        let visible_item = item.mark_visible()
        self.items = self.items.add(id, visible_item)
      }
    None => raise FugueError::MissingItem(id~)
  }
}

///|
/// Find visible position of an item by LV.
/// Returns None if deleted or missing.
pub fn[T : Eq] FugueTree::lv_to_position(self : FugueTree[T], id : Lv) -> Int? {
  let visible = self.get_visible_items()
  for i = 0; i < visible.length(); i = i + 1 {
    let (lv, _) = visible[i]
    if lv == id {
      return Some(i)
    }
  }
  None
}

///|
/// Add item to the tree's internal map.
///
/// **Invariant**: The item's `id` must be unique within the tree. Duplicate IDs
/// will overwrite existing items, which violates CRDT convergence guarantees.
///
/// **Complexity**: O(log n) for immutable hashmap insertion.
fn[T] FugueTree::add_item(self : FugueTree[T], item : Item[T]) -> Unit {
  self.items = self.items.add(item.id, item)
  self.length = self.length + 1
}

///|
/// Compare children for sibling ordering in the Fugue tree.
///
/// Uses Lamport timestamp as primary sort key, with agent ID as tiebreaker.
/// This deterministic ordering ensures all peers converge to the same tree
/// structure regardless of operation arrival order.
///
/// **Complexity**: O(1) for numeric comparison, O(k) for string tiebreaker
/// where k = agent ID length.
fn[T : Eq] compare_children(a : (Lv, Item[T]), b : (Lv, Item[T])) -> Int {
  let (_, item_a) = a
  let (_, item_b) = b
  item_a.compare(item_b)
}

///|
/// Check whether `ancestor_id` is an ancestor of `descendant_id`.
pub fn[T] FugueTree::is_ancestor(
  self : FugueTree[T],
  ancestor_id : Lv,
  descendant_id : Lv,
) -> Bool {
  if ancestor_id == descendant_id {
    return true
  }
  loop self[descendant_id] {
    Some(item) =>
      match item.parent {
        Some(parent_lv) => {
          if parent_lv == ancestor_id {
            return true
          }
          continue self[parent_lv]
        }
        None => break false // Reached root without finding ancestor
      }
    None => break false
  }
}

///|
test "ancestor check correctness" {
  let tree : FugueTree[String] = FugueTree::new()

  // Build chain: root → A(0) → B(1) → C(2)
  tree.insert({
    id: Lv(0),
    content: "A",
    origin_left: None,
    origin_right: None,
    timestamp: Timestamp(0),
    agent: ReplicaId("agent0"),
  })
  tree.insert({
    id: Lv(1),
    content: "B",
    origin_left: Some(Lv(0)),
    origin_right: None,
    timestamp: Timestamp(1),
    agent: ReplicaId("agent0"),
  })
  tree.insert({
    id: Lv(2),
    content: "C",
    origin_left: Some(Lv(1)),
    origin_right: None,
    timestamp: Timestamp(2),
    agent: ReplicaId("agent0"),
  })

  // Test ancestor relationships
  inspect(tree.is_ancestor(Lv(0), Lv(0)), content="true") // Self is ancestor
  inspect(tree.is_ancestor(Lv(0), Lv(1)), content="true") // A is ancestor of B
  inspect(tree.is_ancestor(Lv(0), Lv(2)), content="true") // A is ancestor of C
  inspect(tree.is_ancestor(Lv(1), Lv(2)), content="true") // B is ancestor of C
  inspect(tree.is_ancestor(Lv(1), Lv(0)), content="false") // B is NOT ancestor of A
  inspect(tree.is_ancestor(Lv(2), Lv(0)), content="false") // C is NOT ancestor of A
}

///|
/// Find the correct parent and side for a new item using FugueMax algorithm.
///
/// Given the left and right origin constraints from an insert operation,
/// determines where in the tree the new item should be placed. This implements
/// the core conflict resolution logic that ensures convergence.
///
/// **Algorithm**:
/// - If `origin_left == None`: Insert at document start (parent = root, side = Right)
/// - If `origin_right == None`: Insert after origin_left (parent = origin_left, side = Right)
/// - Otherwise: Navigate the tree to find the correct position between origins
///
/// **Complexity**: O(d) where d = tree depth (typically O(log n) for balanced trees).
///
/// Returns `(parent_id, side)` where side indicates Left or Right child placement.
fn[T] FugueTree::find_parent_and_side(
  self : FugueTree[T],
  origin_left : Lv?,
  origin_right : Lv?,
) -> (Lv?, Side) {
  match (origin_left, origin_right) {
    // If inserting at start, parent is root, side is Right
    (None, _) => (Some(root_lv), Right)
    // If no right constraint, parent is origin_left, side is Right
    (Some(left), None) => (Some(left), Right)
    // FugueMax algorithm:
    // If origin_left IS an ancestor of origin_right → Left child of origin_right
    // If origin_left is NOT an ancestor of origin_right → Right child of origin_left
    (Some(left), Some(right)) =>
      if self.is_ancestor(left, right) {
        (Some(right), Left)
      } else {
        (Some(left), Right)
      }
  }
}

///|
test "find parent and side at start" {
  let tree : FugueTree[String] = FugueTree::new()
  let (parent, side) = tree.find_parent_and_side(None, None)
  inspect(parent, content="Some(Lv(-1))")
  inspect(side, content="Right")
}

///|
test "find parent and side with origin_left" {
  let tree : FugueTree[String] = FugueTree::new()
  tree.insert({
    id: Lv(0),
    content: "A",
    origin_left: None,
    origin_right: None,
    timestamp: Timestamp(0),
    agent: ReplicaId("agent0"),
  })
  let (parent, side) = tree.find_parent_and_side(Some(Lv(0)), None)
  inspect(parent, content="Some(Lv(0))")
  inspect(side, content="Right")
}

///|
/// Get all children of a node (excluding cycles)
fn[T] FugueTree::get_children(
  self : FugueTree[T],
  parent_id : Lv,
) -> @immut/hashmap.HashMap[Lv, Item[T]] {
  self.items.filter(fn(id, item) {
    item.parent == Some(parent_id) && id != parent_id
  })
}

///|
/// Partition children into left and right sides
fn[T] partition_children(
  children : @immut/hashmap.HashMap[Lv, Item[T]],
) -> (Array[(Lv, Item[T])], Array[(Lv, Item[T])]) {
  let left = []
  let right = []
  children.each((id, item) => match item.side {
    Left => left.push((id, item))
    Right => right.push((id, item))
  })
  (left, right)
}

///|
/// In-order tree traversal: Left children → Node → Right children
/// For nodes with same parent and side, sort by timestamp then ID
fn[T : Eq] FugueTree::traverse_tree(
  self : FugueTree[T],
  node_id : Lv,
  result : Array[(Lv, Item[T])],
  visible_only~ : Bool,
) -> Unit {
  // Get children of current node (excluding the node itself to prevent cycles)
  let children = self.get_children(node_id)

  // Split into left and right children
  let (left_children, right_children) = partition_children(children)

  // Traverse left children (sorted by timestamp, then ID)
  let sorted_left = left_children
  sorted_left.sort_by(compare_children)
  sorted_left
  .iter()
  .each(fn(child) {
    let (child_id, _) = child
    // Don't traverse back to parent (prevents cycles)
    if child_id != node_id {
      self.traverse_tree(child_id, result, visible_only~)
    }
  })

  // Visit current node (if not root)
  if node_id != root_lv {
    match self[node_id] {
      Some(item) =>
        if not(visible_only) || item.is_visible() {
          result.push((node_id, item))
        }
      None => ()
    }
  }

  // Traverse right children (sorted by timestamp, then ID)
  let sorted_right = right_children
  sorted_right.sort_by(compare_children)
  sorted_right
  .iter()
  .each(child => {
    let (child_id, _) = child
    // Don't traverse back to parent (prevents cycles)
    if child_id != node_id {
      self.traverse_tree(child_id, result, visible_only~)
    }
  })
}
