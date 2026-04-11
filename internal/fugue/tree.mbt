///| FugueMax tree implementation
/// Maximal non-interleaving list CRDT
/// https://arxiv.org/abs/2305.00583

///|
/// FugueTree - maintains ordered sequence with CRDT properties
pub struct FugueTree[T] {
  items : Array[Item[T]?] // Dense array indexed by ItemId
  lv_index : Array[ItemId?] // Sparse LV -> ItemId lookup bridge
  mut length : Int // Total items (including deleted)
  mut visible : Int // Visible (non-deleted) item count — kept in sync on every mutation
  root_children : Array[ItemId] // Root's children (root not in items array)
  children : Array[Array[ItemId]] // Children index, dense by ItemId
  jump_ancestors : JumpAncestors // Binary lifting for O(log n) ancestor queries
} derive(Debug)

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
    lv_index: Array::new(capacity=1024),
    length: 0,
    visible: 0,
    root_children: [],
    children: Array::new(capacity=1024),
    jump_ancestors: JumpAncestors::new(),
  }
}

///|
/// Map an external LV to the current dense ItemId slot, if present.
fn[T] FugueTree::lookup_item_id(self : FugueTree[T], lv : Lv) -> ItemId? {
  let idx = lv.0
  if idx >= 0 && idx < self.lv_index.length() {
    self.lv_index[idx]
  } else {
    None
  }
}

///|
/// Resolve a dense ItemId slot back to the item's external LV.
fn[T] FugueTree::lookup_lv(self : FugueTree[T], item_id : ItemId) -> Lv? {
  let idx = item_id.0
  if idx >= 0 && idx < self.items.length() {
    match self.items[idx] {
      Some(item) => Some(item.id)
      None => None
    }
  } else {
    None
  }
}

///|
/// Get children for a node. Handles root (LV=-1) separately.
fn[T] FugueTree::get_children(self : FugueTree[T], id : Lv) -> Array[Lv] {
  let result : Array[Lv] = []
  let child_ids = self.get_children_raw(id)
  for child_id in child_ids {
    match self.lookup_lv(child_id) {
      Some(lv) => result.push(lv)
      None => ()
    }
  }
  result
}

///|
/// Index operator for looking up an item by LV.
/// Returns the item for the given LV, or None if missing.
/// Returns None for `root_lv` — root is a virtual sentinel, not a data node.
///
#alias("_[_]")
pub fn[T] FugueTree::get(self : FugueTree[T], id : Lv) -> Item[T]? {
  match self.lookup_item_id(id) {
    Some(item_id) =>
      if item_id.0 >= 0 && item_id.0 < self.items.length() {
        self.items[item_id.0]
      } else {
        None
      }
    None => None
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
        if !item.deleted {
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
      if item.deleted && !deleted {
        self.visible = self.visible + 1
      } else if !item.deleted && deleted {
        self.visible = self.visible - 1
      }
      item.deleted = deleted
      item.deleted_ts = ts
      item.deleted_agent = agent
      item.deleted_is_undelete = is_undelete
      item.state = if deleted { Deleted } else { Inserted }
      // Reset delete_count to match authoritative state.
      // Retreat dirty-tracking may leave it negative; reconcile here.
      item.delete_count = if deleted { 1 } else { 0 }
    }
    None => raise FugueError::MissingItem(id~)
  }
}

///|
/// Adjust the merge-time delete-count tracker for an item.
///
/// This is used by branch retreat logic to account for removed Delete/Undelete
/// operations without reaching into Fugue item internals directly.
pub fn[T] FugueTree::adjust_delete_count(
  self : FugueTree[T],
  id : Lv,
  delta : Int,
) -> Unit raise FugueError {
  if id == root_lv {
    return
  }
  match self[id] {
    Some(item) => item.delete_count = item.delete_count + delta
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
      if !item.deleted {
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
/// **Complexity**: O(log depth) — dominated by jump pointer computation.
fn[T] FugueTree::add_item(self : FugueTree[T], item : Item[T]) -> Unit {
  let lv = item.id.0
  let item_id = ItemId(self.items.length())
  self.items.push(Some(item))
  while self.lv_index.length() <= lv {
    self.lv_index.push(None)
  }
  self.lv_index[lv] = Some(item_id)
  self.length = self.length + 1
  self.visible = self.visible + 1
  // Register as child of parent
  match item.parent {
    Some(parent_lv) =>
      if parent_lv == root_lv {
        self.root_children.push(item_id)
      } else {
        match self.lookup_item_id(parent_lv) {
          Some(parent_id) => self.children[parent_id.0].push(item_id)
          None => ()
        }
      }
    None => ()
  }
  // Grow children array and initialize empty entry for the new item
  self.children.push([])
  // Register jump pointers for the new item (O(log depth), permanent)
  match item.parent {
    Some(p) =>
      if p == root_lv {
        self.jump_ancestors.add_item_id(item_id, None)
      } else {
        match self.lookup_item_id(p) {
          Some(parent_id) =>
            self.jump_ancestors.add_item_id(item_id, Some(parent_id))
          None => ()
        }
      }
    None => () // No parent — skip jump pointer setup
  }
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
fn[T : Eq] compare_children(
  a : (ItemId, Item[T]),
  b : (ItemId, Item[T]),
) -> Int {
  let (_, item_a) = a
  let (_, item_b) = b
  item_a.compare(item_b)
}

///|
/// Check whether `ancestor_id` is an ancestor of `descendant_id`.
/// Uses binary lifting jump pointers for O(log depth) queries.
pub fn[T] FugueTree::is_ancestor(
  self : FugueTree[T],
  ancestor_id : Lv,
  descendant_id : Lv,
) -> Bool {
  if ancestor_id == descendant_id {
    return true
  }
  if ancestor_id == root_lv {
    return true
  }
  if descendant_id == root_lv {
    return false
  }
  match (self.lookup_item_id(ancestor_id), self.lookup_item_id(descendant_id)) {
    (Some(ancestor_item_id), Some(descendant_item_id)) =>
      self.jump_ancestors.is_ancestor_item_id(
        ancestor_item_id, descendant_item_id,
      )
    _ => false
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
/// Determine the parent and side for a new node in the FugueMax tree.
///
/// Implements Algorithm 1, lines 25-28 of the Fugue paper:
///   Weidner & Kleppmann, "The Art of the Fugue: Minimizing Interleaving
///   in Collaborative Text Editing", 2023. arXiv:2305.00583.
///
/// ## Algorithm (paper lines 25-28)
///
/// Given `origin_left` (the item immediately to the left of the insertion
/// position) and `origin_right` (the item immediately to the right):
///
///   let left = origin_left ?? root
///   if origin_right is None:
///     → right child of left                          (line 26)
///   else if left is an ancestor of origin_right:
///     → left child of origin_right                   (line 28)
///   else:
///     → right child of left                          (line 26)
///
/// ## Why `is_ancestor` is the correct check
///
/// The paper distinguishes two cases based on whether `leftOrigin` has
/// right children in the Fugue tree:
///
/// - **No right children** (line 26): The new node becomes leftOrigin's
///   right child, placing it immediately after leftOrigin in document order.
///
/// - **Has right children** (line 28): The new node becomes a left child
///   of rightOrigin, placing it immediately before rightOrigin in document
///   order. This avoids interleaving with the existing right subtree.
///
/// The condition "leftOrigin has right children that lead to rightOrigin"
/// is equivalent to `is_ancestor(leftOrigin, rightOrigin)` in the tree,
/// because the in-order traversal path from leftOrigin to rightOrigin
/// must pass through leftOrigin's right subtree.
///
/// ## Why the old `(None, _) → (root, Right)` was wrong
///
/// The previous implementation had a special case:
///
///   match (origin_left, origin_right) {
///     (None, _) => (root, Right)     // WRONG: ignores origin_right
///     ...
///   }
///
/// When `origin_left = None`, the effective left origin is root. Root is
/// an ancestor of every node, so `is_ancestor(root, origin_right)` is
/// always true. The correct result is `(origin_right, Left)`, placing
/// the new node at the document start. The old code placed it as a right
/// child of root, which puts it at the document END.
///
/// ## Position round-trip property (Law L5.8)
///
/// This function is guarded by the property test `prop_insert_position_roundtrip`:
///   For all positions p in [0, len(doc)], after insert(p, c): text()[p] == c
/// See `text/position_roundtrip_properties_test.mbt`.
///
/// **Complexity**: O(log d) where d = tree depth (dominated by `is_ancestor`
/// which uses binary lifting jump pointers).
///
/// Returns `(parent_id, side)` where side indicates Left or Right child placement.
fn[T] FugueTree::find_parent_and_side(
  self : FugueTree[T],
  origin_left : Lv?,
  origin_right : Lv?,
) -> (Lv?, Side) {
  // Fugue paper Algorithm 1, lines 25-28 (Weidner & Kleppmann, 2023):
  //
  // leftOrigin = origin_left (or root if None)
  // rightOrigin = origin_right (or end if None)
  //
  // If leftOrigin has NO right children → right child of leftOrigin
  // Else → left child of rightOrigin
  //
  // Equivalently via ancestor check: if leftOrigin IS an ancestor of
  // rightOrigin in the tree, leftOrigin has right children (the path
  // to rightOrigin goes through them), so → left child of rightOrigin.
  // Otherwise → right child of leftOrigin.
  let left = match origin_left {
    Some(l) => l
    None => root_lv
  }
  match origin_right {
    None =>
      // No right constraint: right child of leftOrigin (line 26)
      (Some(left), Right)
    Some(right) =>
      if self.is_ancestor(left, right) {
        // leftOrigin is ancestor of rightOrigin: left child of rightOrigin (line 28)
        (Some(right), Left)
      } else {
        // Not ancestor: right child of leftOrigin (line 26)
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
) -> Array[ItemId] {
  if parent_id == root_lv {
    self.root_children
  } else {
    match self.lookup_item_id(parent_id) {
      Some(item_id) =>
        if item_id.0 >= 0 && item_id.0 < self.children.length() {
          self.children[item_id.0]
        } else {
          []
        }
      None => []
    }
  }
}

///|
/// Partition children into left and right sides
fn[T] partition_children(
  children : Array[(ItemId, Item[T])],
) -> (Array[(ItemId, Item[T])], Array[(ItemId, Item[T])]) {
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
  let stack : Array[
    (Lv, Int, Array[(ItemId, Item[T])], Array[(ItemId, Item[T])]),
  ] = []
  stack.push((start_id, 0, [], []))
  while stack.length() > 0 {
    let top = stack.length() - 1
    let (node_id, phase, sorted_left, sorted_right) = stack[top]
    if phase == 0 {
      // Phase 0: first visit — compute children and push left subtrees
      let child_lvs = self.get_children_raw(node_id)
      let children_with_items : Array[(ItemId, Item[T])] = []
      for child_id in child_lvs {
        if child_id.0 < self.items.length() {
          match self.items[child_id.0] {
            Some(item) => children_with_items.push((child_id, item))
            None => ()
          }
        } else {
          ()
        }
      }
      let (left, right) = partition_children(children_with_items)
      left.sort_by(compare_children)
      right.sort_by(compare_children)
      // Advance to phase 1 and store sorted children
      stack[top] = (node_id, 1, left, right)
      // Push left children in reverse order so first child is processed first
      for i = left.length() - 1; i >= 0; i = i - 1 {
        let (child_item_id, _) = left[i]
        match self.lookup_lv(child_item_id) {
          Some(child_lv) if child_lv != node_id =>
            stack.push((child_lv, 0, [], []))
          _ => ()
        }
      }
    } else if phase == 1 {
      // Phase 1: left subtrees done — emit current node, push right subtrees
      if node_id != root_lv {
        match self[node_id] {
          Some(item) =>
            if !visible_only || item.is_visible() {
              result.push((node_id, item))
            }
          None => ()
        }
      }
      // Advance to phase 2
      stack[top] = (node_id, 2, sorted_left, sorted_right)
      // Push right children in reverse order
      for i = sorted_right.length() - 1; i >= 0; i = i - 1 {
        let (child_item_id, _) = sorted_right[i]
        match self.lookup_lv(child_item_id) {
          Some(child_lv) if child_lv != node_id =>
            stack.push((child_lv, 0, [], []))
          _ => ()
        }
      }
    } else {
      // Phase 2: all done — pop this frame
      let _ = stack.pop()
    }
  }
}
