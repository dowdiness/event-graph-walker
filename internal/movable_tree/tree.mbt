///| MovableTree — a tree of nodes with parent pointers, fractional-index
/// ordering, and a property map per node.
///
/// Supports create, move, delete (move-to-trash), and undo-of-create (remove).

///|
/// A single node in the movable tree.
pub(all) struct TreeNode {
  id : TreeNodeId
  mut parent : TreeNodeId
  mut position : @fi.FractionalIndex
  properties : Map[String, String]
}

///|
/// The movable tree structure.
///
/// `nodes` maps each node id to its `TreeNode`.
/// `children_cache` maps each parent id to an array of child ids
/// (kept in fractional-index order by `children()`).
pub struct MovableTree {
  priv nodes : Map[TreeNodeId, TreeNode]
  priv children_cache : Map[TreeNodeId, Array[TreeNodeId]]
}

///|
/// Return a copy of `children` with every occurrence of `exclude` removed.
fn without_child(
  children : Array[TreeNodeId],
  exclude : TreeNodeId,
) -> Array[TreeNodeId] {
  let result : Array[TreeNodeId] = []
  for i = 0; i < children.length(); i = i + 1 {
    if children[i] != exclude {
      result.push(children[i])
    }
  }
  result
}

///|
/// Create a new empty MovableTree with root and trash caches initialized.
pub fn MovableTree::new() -> MovableTree {
  let children_cache : Map[TreeNodeId, Array[TreeNodeId]] = Map::new()
  children_cache.set(root_id, [])
  children_cache.set(trash_id, [])
  { nodes: Map::new(), children_cache }
}

///|
/// Add a new node to the tree under the given parent at the given position.
///
/// If the node already exists, this is a no-op.
pub fn MovableTree::apply_create(
  self : MovableTree,
  id : TreeNodeId,
  parent : TreeNodeId,
  position : @fi.FractionalIndex,
) -> Unit {
  if not(self.nodes.get(id) is None) {
    return
  }
  let node : TreeNode = { id, parent, position, properties: Map::new() }
  self.nodes.set(id, node)
  // Update children cache
  match self.children_cache.get(parent) {
    Some(children) => children.push(id)
    None => self.children_cache.set(parent, [id])
  }
  // Initialize this node's children cache
  if self.children_cache.get(id) is None {
    self.children_cache.set(id, [])
  }
}

///|
/// Remove a node entirely from the tree (for undo of create, NOT for delete).
///
/// This removes the node from its parent's children cache and from the nodes map.
pub fn MovableTree::remove_node(self : MovableTree, id : TreeNodeId) -> Unit {
  match self.nodes.get(id) {
    None => ()
    Some(node) => {
      // Remove from parent's children cache
      let parent = node.parent
      match self.children_cache.get(parent) {
        Some(children) =>
          self.children_cache.set(parent, without_child(children, id))
        None => ()
      }
      // Remove node's own children cache entry
      self.children_cache.remove(id)
      // Remove from nodes map
      self.nodes.remove(id)
    }
  }
}

///|
/// Move an existing node to a new parent at a new position.
///
/// If the node does not exist, this is a no-op.
pub fn MovableTree::apply_move(
  self : MovableTree,
  target : TreeNodeId,
  new_parent : TreeNodeId,
  position : @fi.FractionalIndex,
) -> Unit {
  match self.nodes.get(target) {
    None => ()
    Some(node) => {
      let old_parent = node.parent
      // Remove from old parent's children cache
      match self.children_cache.get(old_parent) {
        Some(children) =>
          self.children_cache.set(old_parent, without_child(children, target))
        None => ()
      }
      // Update node
      node.parent = new_parent
      node.position = position
      // Add to new parent's children cache
      match self.children_cache.get(new_parent) {
        Some(children) => children.push(target)
        None => self.children_cache.set(new_parent, [target])
      }
    }
  }
}

///|
/// Get the parent of a node, or None if the node doesn't exist.
pub fn MovableTree::parent(self : MovableTree, id : TreeNodeId) -> TreeNodeId? {
  match self.nodes.get(id) {
    Some(node) => Some(node.parent)
    None => None
  }
}

///|
/// Get the fractional index position of a node, or None if the node doesn't exist.
pub fn MovableTree::get_position(
  self : MovableTree,
  id : TreeNodeId,
) -> @fi.FractionalIndex? {
  match self.nodes.get(id) {
    Some(node) => Some(node.position)
    None => None
  }
}

///|
/// Get the children of a parent, sorted by fractional index.
pub fn MovableTree::children(
  self : MovableTree,
  parent : TreeNodeId,
) -> Array[TreeNodeId] {
  match self.children_cache.get(parent) {
    None => []
    Some(child_ids) => {
      // Sort by position first, then by node id as a deterministic tie-breaker.
      let pairs : Array[(@fi.FractionalIndex, TreeNodeId)] = []
      for i = 0; i < child_ids.length(); i = i + 1 {
        let child_id = child_ids[i]
        match self.nodes.get(child_id) {
          Some(node) => pairs.push((node.position, child_id))
          None => ()
        }
      }
      pairs.sort_by(fn(a, b) {
        let pos_cmp = a.0.compare(b.0)
        if pos_cmp != 0 {
          pos_cmp
        } else {
          a.1.compare(b.1)
        }
      })
      let result : Array[TreeNodeId] = []
      for i = 0; i < pairs.length(); i = i + 1 {
        result.push(pairs[i].1)
      }
      result
    }
  }
}

///|
/// Check if a node is alive (exists and its parent is not trash).
pub fn MovableTree::is_alive(self : MovableTree, id : TreeNodeId) -> Bool {
  match self.nodes.get(id) {
    Some(node) => node.parent != trash_id
    None => false
  }
}

///|
/// Check if the tree contains a node with the given id.
pub fn MovableTree::contains(self : MovableTree, id : TreeNodeId) -> Bool {
  not(self.nodes.get(id) is None)
}

///|
/// Set a property on a node. No-op if the node doesn't exist.
pub fn MovableTree::set_property(
  self : MovableTree,
  id : TreeNodeId,
  key : String,
  value : String,
) -> Unit {
  match self.nodes.get(id) {
    Some(node) => node.properties.set(key, value)
    None => ()
  }
}

///|
/// Get a property from a node. Returns None if the node doesn't exist
/// or the property is not set.
pub fn MovableTree::get_property(
  self : MovableTree,
  id : TreeNodeId,
  key : String,
) -> String? {
  match self.nodes.get(id) {
    Some(node) => node.properties.get(key)
    None => None
  }
}
