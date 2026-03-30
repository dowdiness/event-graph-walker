///| Quickcheck convergence properties for the MovableTree CRDT.
///
/// Verifies that Kleppmann's undo-do-redo algorithm produces identical
/// tree states regardless of the order in which operations arrive,
/// and that no cycles are introduced.

///|
/// A single tree action: create a node, move it, or delete it.
enum TreeAction {
  Create(Int)
  Move(Int, Int)
  Delete(Int)
} derive(Show)

///|
/// A scenario consisting of a sequence of tree actions for property testing.
struct TreeScenario {
  actions : Array[TreeAction]
} derive(Show)

///|
/// Arbitrary instance for TreeScenario.
/// Generates 2-6 actions that form a valid sequence:
/// nodes are always created before being moved or deleted.
impl @quickcheck.Arbitrary for TreeScenario with arbitrary(size, rs) {
  let num_actions = rs.split().next_uint64().to_int().abs() % 5 + 2
  let _ = size
  let actions : Array[TreeAction] = []
  let mut created_count = 0
  for i = 0; i < num_actions; i = i + 1 {
    let _ = i
    if created_count < 2 {
      // Must create enough nodes before moving/deleting
      actions.push(Create(created_count))
      created_count = created_count + 1
    } else {
      let choice = rs.split().next_uint64() % 3
      if choice == 0 {
        // Create a new node
        actions.push(Create(created_count))
        created_count = created_count + 1
      } else if choice == 1 {
        // Move: pick source and destination among created nodes
        let src = rs.split().next_uint64().to_int().abs() % created_count
        let dst = rs.split().next_uint64().to_int().abs() % (created_count + 1)
        // dst == created_count means "move under root"
        actions.push(Move(src, dst))
      } else {
        // Delete: pick a node among created nodes
        let target = rs.split().next_uint64().to_int().abs() % created_count
        actions.push(Delete(target))
      }
    }
  }
  { actions, }
}

///|
/// Shrink instance for TreeScenario — try smaller prefixes.
impl @qc.Shrink for TreeScenario with shrink(self) {
  let results : Array[TreeScenario] = []
  let len = self.actions.length()
  if len > 0 {
    results.push({ actions: [] })
    let half = len / 2
    if half > 0 {
      results.push({ actions: self.actions[:half].to_array() })
    }
    if len > 1 {
      results.push({ actions: self.actions[:len - 1].to_array() })
    }
  }
  results.iter()
}

///|
/// Build TreeMoveOps from a list of TreeActions.
/// Each action gets a unique ascending timestamp.
/// Returns the ops and the list of node ids that were created.
fn build_ops(
  actions : Array[TreeAction],
) -> (Array[@movable_tree.TreeMoveOp], Array[@movable_tree.TreeNodeId]) {
  let ops : Array[@movable_tree.TreeMoveOp] = []
  let node_ids : Array[@movable_tree.TreeNodeId] = []
  let mut next_pos = 100
  for i = 0; i < actions.length(); i = i + 1 {
    let timestamp = i + 1
    let pos = @fi.FractionalIndex::new([next_pos])
    next_pos = next_pos + 100
    match actions[i] {
      Create(idx) => {
        let id : @movable_tree.TreeNodeId = { agent: "qc", counter: idx }
        // Ensure node_ids has this entry
        while node_ids.length() <= idx {
          node_ids.push({ agent: "qc", counter: node_ids.length() })
        }
        ops.push({
          timestamp,
          target: id,
          new_parent: @movable_tree.root_id,
          position: pos,
          agent: "qc",
        })
      }
      Move(src, dst) =>
        if src < node_ids.length() {
          let target = node_ids[src]
          let new_parent = if dst < node_ids.length() {
            node_ids[dst]
          } else {
            @movable_tree.root_id
          }
          ops.push({ timestamp, target, new_parent, position: pos, agent: "qc" })
        }
      Delete(idx) =>
        if idx < node_ids.length() {
          let target = node_ids[idx]
          ops.push({
            timestamp,
            target,
            new_parent: @movable_tree.trash_id,
            position: pos,
            agent: "qc",
          })
        }
    }
  }
  (ops, node_ids)
}

///|
/// Apply ops in a given index order and return a snapshot of the tree state.
/// The snapshot is a sorted array of "nodeId -> parentId" strings.
fn apply_in_order(
  ops : Array[@movable_tree.TreeMoveOp],
  order : Array[Int],
  node_ids : Array[@movable_tree.TreeNodeId],
) -> Array[String] {
  let tree = @movable_tree.MovableTree::new()
  let log = @movable_tree.TreeOpLog::new()
  for i = 0; i < order.length(); i = i + 1 {
    let idx = order[i]
    if idx >= 0 && idx < ops.length() {
      log.apply(tree, ops[idx])
    }
  }
  tree_snapshot(tree, node_ids)
}

///|
/// Property: Forward, reverse, and interleaved operation orderings all
/// converge to the same tree state, and the resulting tree has no cycles.
test "property: all orderings converge and produce acyclic trees" {
  @qc.quick_check_fn(fn(scenario : TreeScenario) -> Bool {
    let (ops, node_ids) = build_ops(scenario.actions)
    if ops.length() == 0 {
      return true
    }
    // Forward order: 0, 1, 2, ...
    let forward : Array[Int] = []
    for i = 0; i < ops.length(); i = i + 1 {
      forward.push(i)
    }
    // Reverse order: n-1, n-2, ..., 0
    let reverse : Array[Int] = []
    for i = ops.length() - 1; i >= 0; i = i - 1 {
      reverse.push(i)
    }
    // Interleaved: evens first, then odds
    let interleaved : Array[Int] = []
    for i = 0; i < ops.length(); i = i + 2 {
      interleaved.push(i)
    }
    for i = 1; i < ops.length(); i = i + 2 {
      interleaved.push(i)
    }
    let snap_forward = apply_in_order(ops, forward, node_ids)
    let snap_reverse = apply_in_order(ops, reverse, node_ids)
    let snap_interleaved = apply_in_order(ops, interleaved, node_ids)
    // All orderings must produce the same snapshot
    if snap_forward != snap_reverse {
      return false
    }
    if snap_forward != snap_interleaved {
      return false
    }
    // No cycles: apply in reverse and verify every parent chain reaches a sentinel
    let tree = @movable_tree.MovableTree::new()
    let log = @movable_tree.TreeOpLog::new()
    for i = ops.length() - 1; i >= 0; i = i - 1 {
      log.apply(tree, ops[i])
    }
    let max_steps = node_ids.length() + 2
    for i = 0; i < node_ids.length(); i = i + 1 {
      let id = node_ids[i]
      if tree.contains(id) {
        let mut current = id
        let mut steps = 0
        let mut reached_sentinel = false
        while steps < max_steps {
          match tree.parent(current) {
            None => {
              reached_sentinel = true
              break
            }
            Some(p) => {
              if p == @movable_tree.root_id || p == @movable_tree.trash_id {
                reached_sentinel = true
                break
              }
              current = p
              steps = steps + 1
            }
          }
        }
        if !reached_sentinel {
          return false
        }
      }
    }
    true
  })
}
