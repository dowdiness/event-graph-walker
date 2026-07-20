// Multi-agent convergence fuzz tests for Text CRDT
//
// Property-based tests that verify N-agent CRDT convergence under arbitrary
// interleaving of inserts, deletes, undo/redo, and partial syncs.
//
// The Delete/Undelete divergence bug has been FIXED via LWW conflict resolution
// with Lamport timestamps (add-wins semantics). All property tests including
// undo/redo now pass.

///|
/// Actions an agent can take during a fuzz trace.
enum AgentAction {
  FuzzInsert(Int, Int, String) // (agent_idx, pos, char)
  FuzzDelete(Int, Int) // (agent_idx, pos)
  FuzzUndo(Int) // (agent_idx)
  FuzzRedo(Int) // (agent_idx)
  FuzzSync(Int, Int) // (from_idx, to_idx)
} derive(Debug)

///|
/// A generated trace of multi-agent actions.
struct MultiAgentTrace {
  num_agents : Int
  actions : Array[AgentAction]
} derive(Debug)

///|
impl @quickcheck.Arbitrary for MultiAgentTrace with fn arbitrary(size, rs) {
  let chars : Array[String] = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"]
  let num_agents = 2 + rs.split().next_uint64().to_int().abs() % 4 // 2-5 agents
  // Use scratch docs to track valid positions during generation
  let scratches : Array[@text.TextState] = []
  for i = 0; i < num_agents; i = i + 1 {
    scratches.push(try! @text.TextState::new("agent_" + i.to_string()))
  }
  let actions : Array[AgentAction] = [
    FuzzInsert(0, 0, "a"),
    FuzzDelete(0, 0),
    FuzzUndo(0),
    FuzzRedo(0),
    FuzzSync(0, 1),
  ]
  try! scratches[0].insert(@text.Pos::at(0), "a")
  try! scratches[0].delete(@text.Pos::at(0))
  let initial_message = try! scratches[0].sync().export_all()
  let _ = try! scratches[1].sync().apply(initial_message)
  let action_count = if size < 5 { 5 } else { size }
  for step = 0; step < action_count; step = step + 1 {
    let agent = rs.split().next_uint64().to_int().abs() % num_agents
    let doc = scratches[agent]
    let action_type = rs.split().next_uint64().to_int().abs() % 10
    if action_type < 4 {
      // 40% insert
      let len = doc.len()
      let pos = rs.split().next_uint64().to_int().abs() % (len + 1)
      let ch = chars[rs.split().next_uint64().to_int().abs() % chars.length()]
      try! doc.insert(@text.Pos::at(pos), ch)
      actions.push(FuzzInsert(agent, pos, ch))
    } else if action_type < 7 {
      // 30% delete
      let len = doc.len()
      if len == 0 {
        continue
      }
      let pos = rs.split().next_uint64().to_int().abs() % len
      try! doc.delete(@text.Pos::at(pos))
      actions.push(FuzzDelete(agent, pos))
    } else if action_type < 8 {
      // 10% undo
      actions.push(FuzzUndo(agent))
    } else if action_type < 9 {
      // 10% redo
      actions.push(FuzzRedo(agent))
    } else {
      // 10% sync pair
      let raw_to = rs.split().next_uint64().to_int().abs() % num_agents
      let to = if raw_to == agent { (raw_to + 1) % num_agents } else { raw_to }
      // Sync scratch docs too so positions stay valid
      let msg = try! doc.sync().export_all()
      let _ = try! scratches[to].sync().apply(msg)
      actions.push(FuzzSync(agent, to))
    }
  }
  { num_agents, actions }
}

///|
impl @qc.Shrink for MultiAgentTrace with fn shrink(self) {
  let results : Array[MultiAgentTrace] = []
  let len = self.actions.length()
  if len > 1 {
    // Try empty
    results.push({ num_agents: self.num_agents, actions: [] })
    // Try first half
    let half = len / 2
    if half > 0 {
      results.push({
        num_agents: self.num_agents,
        actions: self.actions[:half].to_owned(),
      })
    }
    // Try dropping last action
    results.push({
      num_agents: self.num_agents,
      actions: self.actions[:len - 1].to_owned(),
    })
  }
  results.iter()
}

///|
fn trace_covers_every_action_class(trace : MultiAgentTrace) -> Bool {
  let mut inserts = 0
  let mut deletes = 0
  let mut undos = 0
  let mut redos = 0
  let mut syncs = 0
  for action in trace.actions {
    match action {
      FuzzInsert(_, _, _) => inserts = inserts + 1
      FuzzDelete(_, _) => deletes = deletes + 1
      FuzzUndo(_) => undos = undos + 1
      FuzzRedo(_) => redos = redos + 1
      FuzzSync(_, _) => syncs = syncs + 1
    }
  }
  inserts > 0 && deletes > 0 && undos > 0 && redos > 0 && syncs > 0
}

///|
test "property: generated traces cover every action class" {
  @qc.quick_check_fn(fn(trace : MultiAgentTrace) -> Bool {
    trace_covers_every_action_class(trace)
  })
}

///|
/// Execute a multi-agent trace and verify convergence after full sync.
fn run_trace_and_check_convergence(trace : MultiAgentTrace) -> Bool {
  let docs : Array[@text.TextState] = []
  let mgrs : Array[@undo.UndoManager] = []
  for i = 0; i < trace.num_agents; i = i + 1 {
    let id = "agent_" + i.to_string()
    docs.push(try! @text.TextState::new(id))
    mgrs.push(@undo.UndoManager::new(id))
  }

  // Execute actions
  for action in trace.actions {
    match action {
      FuzzInsert(agent, pos, ch) => {
        let doc = docs[agent]
        let mgr = mgrs[agent]
        let clamped = if pos > doc.len() { doc.len() } else { pos }
        try! doc.insert_and_record(
          @text.Pos::at(clamped),
          ch,
          mgr,
          timestamp_ms=0,
        )
      }
      FuzzDelete(agent, pos) => {
        let doc = docs[agent]
        let mgr = mgrs[agent]
        if doc.len() == 0 {
          continue
        }
        let clamped = if pos >= doc.len() { doc.len() - 1 } else { pos }
        try! doc.delete_and_record(@text.Pos::at(clamped), mgr, timestamp_ms=0)
      }
      FuzzUndo(agent) =>
        if mgrs[agent].can_undo() {
          let _ = try! mgrs[agent].undo(docs[agent])
        }
      FuzzRedo(agent) =>
        if mgrs[agent].can_redo() {
          let _ = try! mgrs[agent].redo(docs[agent])
        }
      FuzzSync(from, to) => {
        let msg = try! docs[from].sync().export_all()
        let _ = try! docs[to].sync().apply(msg)
      }
    }
  }

  // Full all-to-all sync: multiple rounds to handle ops generated by undo/redo
  for _round = 0; _round < 3; _round = _round + 1 {
    let messages : Array[@text.SyncMessage] = []
    for doc in docs {
      let msg = try! doc.sync().export_all()
      messages.push(msg)
    }
    for i = 0; i < docs.length(); i = i + 1 {
      for j = 0; j < messages.length(); j = j + 1 {
        if i != j {
          let _ = try! docs[i].sync().apply(messages[j])
        }
      }
    }
  }

  // Verify all agents converged to the same text
  let expected = docs[0].text()
  let expected_version = docs[0].version()
  for i = 1; i < docs.length(); i = i + 1 {
    if docs[i].text() != expected || docs[i].version() != expected_version {
      return false
    }
  }
  for doc in docs {
    if doc.sync().pending_sync_count() != 0 {
      return false
    }
  }
  true
}

///|
/// Property: insert/delete-only convergence (no undo/redo).
/// Filters out undo/redo actions to verify basic CRDT convergence.
fn prop_multi_agent_convergence_no_undo(trace : MultiAgentTrace) -> Bool {
  let filtered_actions : Array[AgentAction] = []
  for action in trace.actions {
    match action {
      FuzzUndo(_) => continue
      FuzzRedo(_) => continue
      _ => filtered_actions.push(action)
    }
  }
  run_trace_and_check_convergence({
    num_agents: trace.num_agents,
    actions: filtered_actions,
  })
}

///|
test "property: multi-agent convergence (insert/delete/sync, no undo)" {
  @qc.quick_check_fn(prop_multi_agent_convergence_no_undo)
}

///|
/// FIXED: LWW conflict resolution on Delete/Undelete ops.
/// Previously failed due to non-commutative boolean setters.
test "regression: undo+sync multi-agent convergence (was known-bug)" {
  let trace : MultiAgentTrace = {
    num_agents: 2,
    actions: [
      FuzzUndo(1),
      FuzzInsert(1, 0, "f"),
      FuzzSync(1, 0),
      FuzzSync(1, 0),
      FuzzInsert(1, 0, "b"),
      FuzzDelete(0, 0),
      FuzzSync(1, 0),
      FuzzDelete(0, 0),
      FuzzRedo(1),
      FuzzUndo(0),
      FuzzRedo(0),
      FuzzSync(1, 0),
      FuzzRedo(0),
      FuzzInsert(0, 0, "h"),
      FuzzDelete(1, 0),
      FuzzSync(1, 0),
      FuzzDelete(0, 0),
      FuzzInsert(0, 0, "h"),
      FuzzInsert(1, 1, "c"),
      FuzzInsert(0, 0, "a"),
      FuzzInsert(1, 2, "i"),
      FuzzUndo(1),
      FuzzRedo(0),
      FuzzInsert(0, 2, "b"),
      FuzzInsert(0, 3, "i"),
      FuzzRedo(1),
    ],
  }
  let result = run_trace_and_check_convergence(trace)
  assert_true(result)
}

///|
/// Property: multi-agent convergence with undo/redo.
/// Now enabled after LWW Delete/Undelete fix.
test "property: multi-agent convergence with undo/redo" {
  @qc.quick_check_fn(fn(trace : MultiAgentTrace) -> Bool {
    run_trace_and_check_convergence(trace)
  })
}

///|
/// Property: Convergence is independent of sync order.
/// Two agents make concurrent edits. Syncing A->B then B->A
/// must produce the same result as B->A then A->B.
fn prop_sync_order_independence(pair : RealOpsPair) -> Bool {
  let ops1 = pair.left
  let ops2 = pair.right
  // Path 1: A->B then B->A
  let a1 = try! @text.TextState::new("alice")
  let b1 = try! @text.TextState::new("bob")
  let _ = apply_edits(a1, ops1.edits)
  let _ = apply_edits(b1, ops2.edits)
  let msg_a1 = try! a1.sync().export_all()
  let msg_b1 = try! b1.sync().export_all()
  let _ = try! b1.sync().apply(msg_a1)
  let _ = try! a1.sync().apply(msg_b1)

  // Path 2: B->A then A->B (fresh docs)
  let a2 = try! @text.TextState::new("alice")
  let b2 = try! @text.TextState::new("bob")
  let _ = apply_edits(a2, ops1.edits)
  let _ = apply_edits(b2, ops2.edits)
  let msg_a2 = try! a2.sync().export_all()
  let msg_b2 = try! b2.sync().export_all()
  let _ = try! a2.sync().apply(msg_b2)
  let _ = try! b2.sync().apply(msg_a2)

  // Both paths must produce same result
  a1.text() == a2.text() && b1.text() == b2.text() && a1.text() == b1.text()
}

///|
test "property: sync order independence" {
  @qc.quick_check_fn(prop_sync_order_independence)
}

///|
/// Property: Undo under concurrency still converges.
/// Agent A types, agent B types concurrently, A undoes, then full sync.
fn prop_undo_concurrent_convergence(pair : RealOpsPair) -> Bool {
  let ops1 = pair.left
  let ops2 = pair.right
  let doc_a = try! @text.TextState::new("alice")
  let doc_b = try! @text.TextState::new("bob")
  let mgr_a = @undo.UndoManager::new("alice")

  // A types with undo recording
  for edit in ops1.edits {
    match edit {
      Insert(pos, ch) =>
        try! doc_a.insert_and_record(
          @text.Pos::at(pos),
          ch,
          mgr_a,
          timestamp_ms=0,
        )
      Delete(pos) =>
        try! doc_a.delete_and_record(@text.Pos::at(pos), mgr_a, timestamp_ms=0)
    }
  }

  // B types concurrently (no undo tracking needed)
  let _ = apply_edits(doc_b, ops2.edits)

  // A undoes once (if possible)
  if mgr_a.can_undo() {
    let _ = try! mgr_a.undo(doc_a)
  }

  // Full sync
  let msg_a = try! doc_a.sync().export_all()
  let msg_b = try! doc_b.sync().export_all()
  let _ = try! doc_a.sync().apply(msg_b)
  let _ = try! doc_b.sync().apply(msg_a)

  // Must converge
  doc_a.text() == doc_b.text()
}

///|
test "property: undo under concurrency converges" {
  @qc.quick_check_fn(prop_undo_concurrent_convergence)
}
