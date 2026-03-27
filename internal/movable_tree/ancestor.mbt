///| Ancestor detection for the movable tree.
///
/// Provides cycle detection to prevent invalid moves that would create
/// loops in the tree structure.

///|
/// Check if `ancestor` is an ancestor of `descendant` by walking the parent chain.
///
/// A node is NOT considered its own ancestor.
/// Root and trash are ancestors of their respective subtrees.
pub fn MovableTree::is_ancestor_of(
  self : MovableTree,
  ancestor : TreeNodeId,
  descendant : TreeNodeId,
) -> Bool {
  if ancestor == descendant {
    return false
  }
  let mut current = descendant
  // Walk up the parent chain until we hit root, trash, or the ancestor
  for ;; {
    match self.nodes.get(current) {
      None => return false
      Some(node) => {
        let parent = node.parent
        if parent == ancestor {
          return true
        }
        // Reached a sentinel (root or trash) without finding ancestor
        if parent == root_id || parent == trash_id {
          return false
        }
        current = parent
      }
    }
  }
}

///|
/// Check if moving `target` under `new_parent` would create a cycle.
///
/// A cycle occurs when:
/// - `target == new_parent` (node becomes its own parent)
/// - `target` is an ancestor of `new_parent` (would create a loop)
pub fn MovableTree::would_create_cycle(
  self : MovableTree,
  target : TreeNodeId,
  new_parent : TreeNodeId,
) -> Bool {
  if target == new_parent {
    return true
  }
  self.is_ancestor_of(target, new_parent)
}
