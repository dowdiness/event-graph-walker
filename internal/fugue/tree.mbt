///| FugueMax tree implementation
/// Maximal non-interleaving list CRDT
/// https://arxiv.org/abs/2305.00583

///|
/// FugueTree - maintains ordered sequence with CRDT properties
pub struct FugueTree[T] {
  items : Array[Item[T]?] // Sparse array indexed by LV (item LV = index)
  mut length : Int // Total items (including deleted)
  mut visible : Int // Visible (non-deleted) item count — kept in sync on every mutation
  root_children : Array[Lv] // Root's children (root not in items array)
  children : Array[Array[Lv]] // Children index, sparse array indexed by LV
  mut lca_index : LcaIndex? // Euler Tour + Sparse Table for O(1) ancestor queries
  mut batch_inserting : Bool // True during batch operations (use naive walk instead of LCA)
} derive(Show)

///|
/// Creates a default empty FugueTree with a virtual root node.
///
/// Requires `T : Default` so a dummy content value can be stored in the root.
///
/// Example:
///
/// ```moonbit nocheck
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
pub fn[T] FugueTree::make(_root_content : T) -> FugueTree[T] {
  {
    items: Array::new(capacity=1024),
    length: 0,
    visible: 0,
    root_children: [],
    children: Array::new(capacity=1024),
    lca_index: None,
    batch_inserting: false,
  }
}

///|
/// Get children for a node. Handles root (LV=-1) separately.
fn[T] FugueTree::get_children(self : FugueTree[T], id : Lv) -> Array[Lv] {
  if id == root_lv {
    self.root_children
  } else if id.0 >= 0 && id.0 < self.children.length() {
    self.children[id.0]
  } else {
    []
  }
}

///|
/// Index operator for looking up an item by LV.
/// Returns the item for the given LV, or None if missing.
/// Returns None for `root_lv` — root is a virtual sentinel, not a data node.
///
#alias("_[_]")
pub fn[T] FugueTree::get(self : FugueTree[T], id : Lv) -> Item[T]? {
  let lv = id.0
  if lv >= 0 && lv < self.items.length() {
    self.items[lv]
  } else {
    None
  }
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
/// Count visible (non-deleted) items.
/// O(1) — returns the cached counter maintained by `add_item`, `delete`, and `undelete`.
pub fn[T] FugueTree::visible_count(self : FugueTree[T]) -> Int {
  self.visible
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
/// LWW comparison for Delete/Undelete conflict resolution.
/// Returns true if the new op wins over the current winner.
///
/// Rule: higher timestamp wins. Same timestamp: Undelete beats Delete (add-wins).
/// Same timestamp and type: higher agent ID wins.
pub fn should_win_delete(
  new_ts : Int,
  new_agent : String,
  new_is_undelete : Bool,
  cur_ts : Int,
  cur_agent : String,
  cur_is_undelete : Bool,
) -> Bool {
  if cur_ts == 0 && cur_agent == "" {
    return true // No previous winner, always apply
  }
  if new_ts != cur_ts {
    return new_ts > cur_ts
  }
  // Same timestamp: Undelete beats Delete (add-wins)
  if new_is_undelete != cur_is_undelete {
    return new_is_undelete
  }
  // Same timestamp, same type: agent tiebreaker
  new_agent > cur_agent
}

///|
/// Convergent delete: only applies if this op wins the LWW comparison.
pub fn[T] FugueTree::delete_with_ts(
  self : FugueTree[T],
  id : Lv,
  ts : Int,
  agent : String,
) -> Unit raise FugueError {
  if id == root_lv {
    return
  }
  match self[id] {
    Some(item) =>
      if should_win_delete(
          ts,
          agent,
          false,
          item.deleted_ts,
          item.deleted_agent,
          item.deleted_is_undelete,
        ) {
        if not(item.deleted) {
          self.visible = self.visible - 1
        }
        item.deleted = true
        item.deleted_ts = ts
        item.deleted_agent = agent
        item.deleted_is_undelete = false
        item.state = Deleted
      }
    None => raise FugueError::MissingItem(id~)
  }
}

///|
/// Convergent undelete: only applies if this op wins the LWW comparison.
pub fn[T] FugueTree::undelete_with_ts(
  self : FugueTree[T],
  id : Lv,
  ts : Int,
  agent : String,
) -> Unit raise FugueError {
  if id == root_lv {
    return
  }
  match self[id] {
    Some(item) =>
      if should_win_delete(
          ts,
          agent,
          true,
          item.deleted_ts,
          item.deleted_agent,
          item.deleted_is_undelete,
        ) {
        if item.deleted {
          self.visible = self.visible + 1
        }
        item.deleted = false
        item.deleted_ts = ts
        item.deleted_agent = agent
        item.deleted_is_undelete = true
        item.state = Inserted
      }
    None => raise FugueError::MissingItem(id~)
  }
}

///|
/// Force-set the delete winner state. Used by retreat to restore a recomputed winner.
/// No LWW comparison -- directly sets the state.
pub fn[T] FugueTree::set_delete_winner(
  self : FugueTree[T],
  id : Lv,
  deleted : Bool,
  ts : Int,
  agent : String,
  is_undelete : Bool,
) -> Unit raise FugueError {
  if id == root_lv {
    return
  }
  match self[id] {
    Some(item) => {
      if item.deleted && not(deleted) {
        self.visible = self.visible + 1
      } else if not(item.deleted) && deleted {
        self.visible = self.visible - 1
      }
      item.deleted = deleted
      item.deleted_ts = ts
      item.deleted_agent = agent
      item.deleted_is_undelete = is_undelete
      item.state = if deleted { Deleted } else { Inserted }
    }
    None => raise FugueError::MissingItem(id~)
  }
}

///|
/// Delete an item (mark as deleted).
/// Force-delete: always applies. Updates winner record to zero state.
/// Used for retreat of Insert ops and local edits.
pub fn[T] FugueTree::delete(
  self : FugueTree[T],
  id : Lv,
) -> Unit raise FugueError {
  // root_lv is the virtual sentinel and is never part of the visible sequence.
  // Tombstoning it would corrupt the visible counter on a subsequent undelete(root_lv),
  // so treat delete(root_lv) as a full no-op.
  if id == root_lv {
    return
  }
  match self[id] {
    Some(item) => {
      if not(item.deleted) {
        self.visible = self.visible - 1
      }
      item.deleted = true
      item.deleted_ts = 0
      item.deleted_agent = ""
      item.deleted_is_undelete = false
      item.state = Retreated
      item.delete_count = 0
    }
    None => raise FugueError::MissingItem(id~)
  }
}

///|
/// Undelete an item (revive tombstone). Idempotent for already-visible items.
/// Force-undelete: always applies when item is deleted. Updates winner record to zero state.
pub fn[T] FugueTree::undelete(
  self : FugueTree[T],
  id : Lv,
) -> Unit raise FugueError {
  if id == root_lv {
    return
  }
  match self[id] {
    Some(item) =>
      if item.deleted {
        self.visible = self.visible + 1
        item.deleted = false
        item.deleted_ts = 0
        item.deleted_agent = ""
        item.deleted_is_undelete = true
        item.state = Inserted
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
/// **Complexity**: O(1) amortized for array append.
fn[T] FugueTree::add_item(self : FugueTree[T], item : Item[T]) -> Unit {
  let lv = item.id.0
  // Grow items array and store item at its LV index
  while self.items.length() <= lv {
    self.items.push(None)
  }
  self.items[lv] = Some(item)
  self.length = self.length + 1
  self.visible = self.visible + 1
  // Register as child of parent
  match item.parent {
    Some(parent_lv) => self.get_children(parent_lv).push(item.id)
    None => ()
  }
  // Grow children array and initialize empty entry for the new item
  while self.children.length() <= lv {
    self.children.push([])
  }
  // Invalidate LCA index — tree structure has changed
  self.lca_index = None
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
/// Build or rebuild the LCA index from the current tree state.
pub fn[T] FugueTree::build_lca_index(self : FugueTree[T]) -> Unit {
  self.lca_index = Some(LcaIndex::build(self))
}

///|
/// Set/clear the batch-inserting flag.
/// When cleared, the stale LCA index is discarded so the next
/// `is_ancestor` call will lazily rebuild it.
pub fn[T] FugueTree::set_batch_inserting(
  self : FugueTree[T],
  value : Bool,
) -> Unit {
  self.batch_inserting = value
  if not(value) {
    self.lca_index = None // Clear stale index when batch ends
  }
}

///|
/// Naive parent-walk ancestor check. O(tree height).
pub fn[T] FugueTree::is_ancestor_naive(
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
/// Check whether `ancestor_id` is an ancestor of `descendant_id`.
/// Uses LCA index for O(1) when available, falls back to naive walk during batch inserts.
pub fn[T] FugueTree::is_ancestor(
  self : FugueTree[T],
  ancestor_id : Lv,
  descendant_id : Lv,
) -> Bool {
  if ancestor_id == descendant_id {
    return true
  }
  if self.batch_inserting {
    return self.is_ancestor_naive(ancestor_id, descendant_id)
  }
  match self.lca_index {
    Some(idx) => idx.is_ancestor(ancestor_id, descendant_id)
    None => {
      self.build_lca_index()
      match self.lca_index {
        Some(idx) => idx.is_ancestor(ancestor_id, descendant_id)
        None => self.is_ancestor_naive(ancestor_id, descendant_id)
      }
    }
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
/// Get children LVs for a node using the children index (O(1) lookup).
/// Returns a copy of the array to prevent mutation by callers.
pub fn[T] FugueTree::get_children_index(
  self : FugueTree[T],
  parent_id : Lv,
) -> Array[Lv] {
  self.get_children(parent_id).copy()
}

///|
/// Get children LVs without copying. Internal use only — callers must not mutate.
fn[T] FugueTree::get_children_raw(
  self : FugueTree[T],
  parent_id : Lv,
) -> Array[Lv] {
  self.get_children(parent_id)
}

///|
/// Partition children into left and right sides
fn[T] partition_children(
  children : Array[(Lv, Item[T])],
) -> (Array[(Lv, Item[T])], Array[(Lv, Item[T])]) {
  let left = []
  let right = []
  for child in children {
    let (_, item) = child
    match item.side {
      Left => left.push(child)
      Right => right.push(child)
    }
  }
  (left, right)
}

///|
/// In-order tree traversal: Left children → Node → Right children
/// For nodes with same parent and side, sort by timestamp then ID.
/// Uses an explicit stack to avoid call-stack overflow on deep trees (500+ nodes).
///
/// Stack frame phases:
///   0 = first visit: compute sorted left/right children, push left children
///   1 = left children done: emit current node, push right children
///   2 = right children done: pop frame
fn[T : Eq] FugueTree::traverse_tree(
  self : FugueTree[T],
  start_id : Lv,
  result : Array[(Lv, Item[T])],
  visible_only~ : Bool,
) -> Unit {
  // Stack entries: (node_id, phase, sorted_left, sorted_right)
  // We store the sorted children arrays to avoid recomputing them between phases.
  let stack : Array[(Lv, Int, Array[(Lv, Item[T])], Array[(Lv, Item[T])])] = []
  stack.push((start_id, 0, [], []))
  while stack.length() > 0 {
    let top = stack.length() - 1
    let (node_id, phase, sorted_left, sorted_right) = stack[top]
    if phase == 0 {
      // Phase 0: first visit — compute children and push left subtrees
      let child_lvs = self.get_children_raw(node_id)
      let children_with_items : Array[(Lv, Item[T])] = []
      for lv in child_lvs {
        match self[lv] {
          Some(item) => children_with_items.push((lv, item))
          None => ()
        }
      }
      let (left, right) = partition_children(children_with_items)
      left.sort_by(compare_children)
      right.sort_by(compare_children)
      // Advance to phase 1 and store sorted children
      stack[top] = (node_id, 1, left, right)
      // Push left children in reverse order so first child is processed first
      for i = left.length() - 1; i >= 0; i = i - 1 {
        let (child_id, _) = left[i]
        if child_id != node_id {
          stack.push((child_id, 0, [], []))
        }
      }
    } else if phase == 1 {
      // Phase 1: left subtrees done — emit current node, push right subtrees
      if node_id != root_lv {
        match self[node_id] {
          Some(item) =>
            if not(visible_only) || item.is_visible() {
              result.push((node_id, item))
            }
          None => ()
        }
      }
      // Advance to phase 2
      stack[top] = (node_id, 2, sorted_left, sorted_right)
      // Push right children in reverse order
      for i = sorted_right.length() - 1; i >= 0; i = i - 1 {
        let (child_id, _) = sorted_right[i]
        if child_id != node_id {
          stack.push((child_id, 0, [], []))
        }
      }
    } else {
      // Phase 2: all done — pop this frame
      let _ = stack.pop()
    }
  }
}
