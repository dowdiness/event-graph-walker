///| Convergence tests for Kleppmann's undo-do-redo conflict resolution.
///
/// Verifies that concurrent tree operations converge to the same state
/// regardless of the order in which they are received by different peers.

///|
/// Helper: snapshot both parent linkage and sibling order for every node.
///
/// Returns a sorted array of strings of the form:
///   "(agent:counter)@{sibling_index} -> parent(agent:counter)"
///
/// Including the sibling index ensures that two replicas with the same
/// parent-child relationships but different fractional-index orderings
/// produce different snapshots and fail the convergence check.
fn tree_snapshot(
  tree : @movable_tree.MovableTree,
  ids : Array[@movable_tree.TreeNodeId],
) -> Array[String] {
  let result : Array[String] = []
  for i = 0; i < ids.length(); i = i + 1 {
    let id = ids[i]
    if tree.contains(id) {
      match tree.parent(id) {
        Some(p) => {
          let siblings = tree.children(p)
          let mut sibling_idx = -1
          for j = 0; j < siblings.length(); j = j + 1 {
            if siblings[j] == id {
              sibling_idx = j
              break
            }
          }
          result.push(
            id.agent +
            ":" +
            id.counter.to_string() +
            "@" +
            sibling_idx.to_string() +
            " -> " +
            p.agent +
            ":" +
            p.counter.to_string(),
          )
        }
        None => ()
      }
    }
  }
  result.sort()
  result
}

///|
/// Test 1: Basic convergence — two peers, same ops in different order, same result.
test "convergence: two peers same ops different order" {
  let pos1 = @fi.FractionalIndex::new([100])
  let pos2 = @fi.FractionalIndex::new([200])
  let a : @movable_tree.TreeNodeId = { agent: "alice", counter: 0 }
  let b : @movable_tree.TreeNodeId = { agent: "bob", counter: 0 }
  let op1 : @movable_tree.TreeMoveOp = {
    timestamp: 1,
    target: a,
    new_parent: @movable_tree.root_id,
    position: pos1,
    agent: "alice",
  }
  let op2 : @movable_tree.TreeMoveOp = {
    timestamp: 2,
    target: b,
    new_parent: @movable_tree.root_id,
    position: pos2,
    agent: "bob",
  }
  let op3 : @movable_tree.TreeMoveOp = {
    timestamp: 3,
    target: b,
    new_parent: a,
    position: pos1,
    agent: "alice",
  }
  // Peer 1: receives in order 1, 2, 3
  let tree1 = @movable_tree.MovableTree::new()
  let log1 = @movable_tree.TreeOpLog::new()
  log1.apply(tree1, op1)
  log1.apply(tree1, op2)
  log1.apply(tree1, op3)
  // Peer 2: receives in order 2, 3, 1
  let tree2 = @movable_tree.MovableTree::new()
  let log2 = @movable_tree.TreeOpLog::new()
  log2.apply(tree2, op2)
  log2.apply(tree2, op3)
  log2.apply(tree2, op1)
  // Both should converge
  let ids = [a, b]
  let snap1 = tree_snapshot(tree1, ids)
  let snap2 = tree_snapshot(tree2, ids)
  inspect(snap1, content=snap2.to_string())
  // Verify the actual structure: A under root, B under A
  @debug.debug_inspect(
    tree1.parent(a),
    content=(
      #|Some({ agent: "__ROOT__", counter: -1 })
    ),
  )
  @debug.debug_inspect(
    tree1.parent(b),
    content=(
      #|Some({ agent: "alice", counter: 0 })
    ),
  )
}

///|
/// Test 2: Concurrent cycle resolution.
/// Create A (ts 1), Create B (ts 2), Move A→B (ts 3), Move B→A (ts 4).
/// Timestamp order: ts 3 (A under B) applied first, then ts 4 (B→A) would cycle → SKIPPED.
/// Expected: A under B, B under root.
test "convergence: concurrent cycle — later move skipped" {
  let pos = @fi.FractionalIndex::new([100])
  let a : @movable_tree.TreeNodeId = { agent: "alice", counter: 0 }
  let b : @movable_tree.TreeNodeId = { agent: "bob", counter: 0 }
  // Create A under root (ts 1)
  let create_a : @movable_tree.TreeMoveOp = {
    timestamp: 1,
    target: a,
    new_parent: @movable_tree.root_id,
    position: pos,
    agent: "alice",
  }
  // Create B under root (ts 2)
  let create_b : @movable_tree.TreeMoveOp = {
    timestamp: 2,
    target: b,
    new_parent: @movable_tree.root_id,
    position: pos,
    agent: "bob",
  }
  // Move A under B (ts 3, by alice)
  let move_a_under_b : @movable_tree.TreeMoveOp = {
    timestamp: 3,
    target: a,
    new_parent: b,
    position: pos,
    agent: "alice",
  }
  // Move B under A (ts 4, by bob) — will be skipped because A is now under B
  let move_b_under_a : @movable_tree.TreeMoveOp = {
    timestamp: 4,
    target: b,
    new_parent: a,
    position: pos,
    agent: "bob",
  }
  // Apply in timestamp order
  let tree1 = @movable_tree.MovableTree::new()
  let log1 = @movable_tree.TreeOpLog::new()
  log1.apply(tree1, create_a)
  log1.apply(tree1, create_b)
  log1.apply(tree1, move_a_under_b)
  log1.apply(tree1, move_b_under_a)
  // Expected: A under B, B under root (move_b_under_a was skipped)
  @debug.debug_inspect(
    tree1.parent(a),
    content=(
      #|Some({ agent: "bob", counter: 0 })
    ),
  )
  @debug.debug_inspect(
    tree1.parent(b),
    content=(
      #|Some({ agent: "__ROOT__", counter: -1 })
    ),
  )
  // Also verify with reversed arrival order
  let tree2 = @movable_tree.MovableTree::new()
  let log2 = @movable_tree.TreeOpLog::new()
  log2.apply(tree2, move_b_under_a)
  log2.apply(tree2, move_a_under_b)
  log2.apply(tree2, create_b)
  log2.apply(tree2, create_a)
  // Should converge to same result
  @debug.debug_inspect(
    tree2.parent(a),
    content=(
      #|Some({ agent: "bob", counter: 0 })
    ),
  )
  @debug.debug_inspect(
    tree2.parent(b),
    content=(
      #|Some({ agent: "__ROOT__", counter: -1 })
    ),
  )
}

///|
/// Test 3: Duplicate ops are idempotent.
test "convergence: duplicate ops idempotent" {
  let pos = @fi.FractionalIndex::new([100])
  let a : @movable_tree.TreeNodeId = { agent: "alice", counter: 0 }
  let op : @movable_tree.TreeMoveOp = {
    timestamp: 1,
    target: a,
    new_parent: @movable_tree.root_id,
    position: pos,
    agent: "alice",
  }
  let tree = @movable_tree.MovableTree::new()
  let log = @movable_tree.TreeOpLog::new()
  log.apply(tree, op)
  inspect(tree.contains(a), content="true")
  @debug.debug_inspect(
    tree.parent(a),
    content=(
      #|Some({ agent: "__ROOT__", counter: -1 })
    ),
  )
  // Apply the same op again — should be a no-op
  log.apply(tree, op)
  inspect(tree.contains(a), content="true")
  @debug.debug_inspect(
    tree.parent(a),
    content=(
      #|Some({ agent: "__ROOT__", counter: -1 })
    ),
  )
  // Only one entry in the log
  inspect(log.all_ops().length(), content="1")
}

///|
/// Test 4: Move-before-create — receive move op before create op.
/// After all ops applied, tree is correct because undo-do-redo replays in timestamp order.
test "convergence: move before create" {
  let pos = @fi.FractionalIndex::new([100])
  let pos2 = @fi.FractionalIndex::new([200])
  let a : @movable_tree.TreeNodeId = { agent: "alice", counter: 0 }
  let b : @movable_tree.TreeNodeId = { agent: "bob", counter: 0 }
  // Create A (ts 1)
  let create_a : @movable_tree.TreeMoveOp = {
    timestamp: 1,
    target: a,
    new_parent: @movable_tree.root_id,
    position: pos,
    agent: "alice",
  }
  // Create B (ts 2)
  let create_b : @movable_tree.TreeMoveOp = {
    timestamp: 2,
    target: b,
    new_parent: @movable_tree.root_id,
    position: pos2,
    agent: "bob",
  }
  // Move B under A (ts 3)
  let move_b : @movable_tree.TreeMoveOp = {
    timestamp: 3,
    target: b,
    new_parent: a,
    position: pos,
    agent: "alice",
  }
  // Peer receives: move_b first, then create_a, then create_b
  let tree = @movable_tree.MovableTree::new()
  let log = @movable_tree.TreeOpLog::new()
  log.apply(tree, move_b) // move arrives before creates
  log.apply(tree, create_a)
  log.apply(tree, create_b)
  // After undo-do-redo, should be: A under root, B under A
  @debug.debug_inspect(
    tree.parent(a),
    content=(
      #|Some({ agent: "__ROOT__", counter: -1 })
    ),
  )
  @debug.debug_inspect(
    tree.parent(b),
    content=(
      #|Some({ agent: "alice", counter: 0 })
    ),
  )
}

///|
/// Test 5: Out-of-order replay must not materialize a transient cycle for
/// create-like replays of missing targets.
test "convergence: missing-target replay still checks cycles" {
  let pos = @fi.FractionalIndex::new([100])
  let a : @movable_tree.TreeNodeId = { agent: "alice", counter: 0 }
  let b : @movable_tree.TreeNodeId = { agent: "bob", counter: 0 }
  let c : @movable_tree.TreeNodeId = { agent: "carol", counter: 0 }
  let create_c : @movable_tree.TreeMoveOp = {
    timestamp: 0,
    target: c,
    new_parent: @movable_tree.root_id,
    position: pos,
    agent: "carol",
  }
  let create_a_under_b : @movable_tree.TreeMoveOp = {
    timestamp: 2,
    target: a,
    new_parent: b,
    position: pos,
    agent: "alice",
  }
  let move_b_under_a : @movable_tree.TreeMoveOp = {
    timestamp: 3,
    target: b,
    new_parent: a,
    position: pos,
    agent: "bob",
  }
  let move_c_under_a : @movable_tree.TreeMoveOp = {
    timestamp: 4,
    target: c,
    new_parent: a,
    position: pos,
    agent: "carol",
  }
  let tree = @movable_tree.MovableTree::new()
  let log = @movable_tree.TreeOpLog::new()
  log.apply(tree, create_c)
  log.apply(tree, move_b_under_a)
  log.apply(tree, create_a_under_b)
  // This used to hang because the prior two ops could leave A <-> B.
  log.apply(tree, move_c_under_a)
  @debug.debug_inspect(
    tree.parent(c),
    content=(
      #|Some({ agent: "alice", counter: 0 })
    ),
  )
  inspect(tree.would_create_cycle(b, a), content="true")
}

///|
/// Test 5: Six orderings of 5 ops all produce same tree.
test "convergence: six orderings all converge" {
  let pos = @fi.FractionalIndex::new([100])
  let pos2 = @fi.FractionalIndex::new([200])
  let pos3 = @fi.FractionalIndex::new([300])
  let a : @movable_tree.TreeNodeId = { agent: "alice", counter: 0 }
  let b : @movable_tree.TreeNodeId = { agent: "bob", counter: 0 }
  let c : @movable_tree.TreeNodeId = { agent: "carol", counter: 0 }
  let ops : Array[@movable_tree.TreeMoveOp] = [
    // Create A (ts 1)
    {
      timestamp: 1,
      target: a,
      new_parent: @movable_tree.root_id,
      position: pos,
      agent: "alice",
    },
    // Create B (ts 2)
    {
      timestamp: 2,
      target: b,
      new_parent: @movable_tree.root_id,
      position: pos2,
      agent: "bob",
    },
    // Create C (ts 3)
    {
      timestamp: 3,
      target: c,
      new_parent: @movable_tree.root_id,
      position: pos3,
      agent: "carol",
    },
    // Move B under A (ts 4)
    { timestamp: 4, target: b, new_parent: a, position: pos, agent: "alice" },
    // Move C under B (ts 5)
    { timestamp: 5, target: c, new_parent: b, position: pos, agent: "bob" },
  ]
  // Six different orderings (permutations)
  let orderings : Array[Array[Int]] = [
    [0, 1, 2, 3, 4],
    [4, 3, 2, 1, 0],
    [2, 0, 4, 1, 3],
    [3, 4, 0, 1, 2],
    [1, 3, 0, 4, 2],
    [4, 0, 2, 3, 1],
  ]
  let ids = [a, b, c]
  // Compute reference snapshot from first ordering
  let ref_tree = @movable_tree.MovableTree::new()
  let ref_log = @movable_tree.TreeOpLog::new()
  for i = 0; i < orderings[0].length(); i = i + 1 {
    ref_log.apply(ref_tree, ops[orderings[0][i]])
  }
  let ref_snap = tree_snapshot(ref_tree, ids)
  // Verify all other orderings produce the same snapshot
  for o = 1; o < orderings.length(); o = o + 1 {
    let tree = @movable_tree.MovableTree::new()
    let log = @movable_tree.TreeOpLog::new()
    for i = 0; i < orderings[o].length(); i = i + 1 {
      log.apply(tree, ops[orderings[o][i]])
    }
    let snap = tree_snapshot(tree, ids)
    inspect(snap, content=ref_snap.to_string())
  }
  // Verify the actual structure: A under root, B under A, C under B
  @debug.debug_inspect(
    ref_tree.parent(a),
    content=(
      #|Some({ agent: "__ROOT__", counter: -1 })
    ),
  )
  @debug.debug_inspect(
    ref_tree.parent(b),
    content=(
      #|Some({ agent: "alice", counter: 0 })
    ),
  )
  @debug.debug_inspect(
    ref_tree.parent(c),
    content=(
      #|Some({ agent: "bob", counter: 0 })
    ),
  )
}

///|
/// Test 6: No cycles after convergence — walk parent chain from every node.
test "convergence: no cycles after convergence" {
  let pos = @fi.FractionalIndex::new([100])
  let a : @movable_tree.TreeNodeId = { agent: "alice", counter: 0 }
  let b : @movable_tree.TreeNodeId = { agent: "bob", counter: 0 }
  let c : @movable_tree.TreeNodeId = { agent: "carol", counter: 0 }
  // Create nodes, then do concurrent conflicting moves
  let ops : Array[@movable_tree.TreeMoveOp] = [
    // Create A, B, C under root
    {
      timestamp: 1,
      target: a,
      new_parent: @movable_tree.root_id,
      position: pos,
      agent: "alice",
    },
    {
      timestamp: 2,
      target: b,
      new_parent: @movable_tree.root_id,
      position: pos,
      agent: "bob",
    },
    {
      timestamp: 3,
      target: c,
      new_parent: @movable_tree.root_id,
      position: pos,
      agent: "carol",
    },
    // Concurrent: A under B, B under C, C under A (triangle cycle attempt)
    { timestamp: 4, target: a, new_parent: b, position: pos, agent: "alice" },
    { timestamp: 5, target: b, new_parent: c, position: pos, agent: "bob" },
    { timestamp: 6, target: c, new_parent: a, position: pos, agent: "carol" },
  ]
  // Apply in reverse order (worst case for undo-do-redo)
  let tree = @movable_tree.MovableTree::new()
  let log = @movable_tree.TreeOpLog::new()
  for i = ops.length() - 1; i >= 0; i = i - 1 {
    log.apply(tree, ops[i])
  }
  // Verify no cycles: for each node, walking parent chain reaches root or trash
  let ids = [a, b, c]
  for i = 0; i < ids.length(); i = i + 1 {
    let id = ids[i]
    let mut current = id
    let mut steps = 0
    let max_steps = 10 // More than enough for 3 nodes
    let mut reached_sentinel = false
    while steps < max_steps {
      match tree.parent(current) {
        None => {
          // Node not in tree (shouldn't happen here)
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
    inspect(reached_sentinel, content="true")
  }
}
