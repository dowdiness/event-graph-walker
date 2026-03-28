///| Ancestor queries and cycle detection for the movable tree.
///
/// Kleppmann's algorithm relies on cycle detection to decide whether a move op
/// should be applied or skipped: a move of `target` under `new_parent` is safe
/// only if `target` is not already an ancestor of `new_parent`.  If it were,
/// the move would create a cycle (target → … → new_parent → target → …).
///
/// The check is intentionally conservative: `would_create_cycle` is called both
/// for normal moves and for forward-creates (where the target doesn't yet exist).
/// For forward-creates it is still possible to have a cycle if an earlier
/// out-of-order op stored a dangling parent pointer that makes the target appear
/// as an ancestor of the intended new_parent.

///|
/// Return true if `ancestor` is a strict ancestor of `descendant`.
///
/// Walks the parent chain from `descendant` upward.  Returns true as soon as
/// `ancestor` is encountered as a parent.  Returns false if:
/// - `ancestor == descendant` (a node is not its own ancestor)
/// - the chain reaches `root_id` or `trash_id` without passing through `ancestor`
/// - a dangling parent pointer is encountered (node absent from the tree)
///
/// The walk terminates at sentinels rather than looping indefinitely because
/// the algorithm's cycle-skip guarantee ensures no actual cycle exists in a
/// well-formed tree.  The only way a cycle could be present here is in an
/// intermediate undo state, which is handled by the undo phase before any
/// ancestor query is made.
pub fn MovableTree::is_ancestor_of(
  self : MovableTree,
  ancestor : TreeNodeId,
  descendant : TreeNodeId,
) -> Bool {
  if ancestor == descendant {
    return false
  }
  let mut current = descendant
  for ;; {
    match self.nodes.get(current) {
      None => return false
      Some(node) => {
        let parent = node.parent
        if parent == ancestor {
          return true
        }
        // Reached a sentinel (root or trash) without finding ancestor.
        if parent == root_id || parent == trash_id {
          return false
        }
        current = parent
      }
    }
  }
}

///|
/// Return true if moving `target` under `new_parent` would create a cycle.
///
/// A cycle arises in two situations:
/// 1. `target == new_parent` — the node would become its own parent.
/// 2. `target` is already an ancestor of `new_parent` — the move would form a
///    loop: new_parent → … → target → new_parent → …
///
/// Both cases are detected here.  When `would_create_cycle` returns true the
/// caller (`do_op`) records the op as `Skipped`, leaving the tree unchanged.
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
