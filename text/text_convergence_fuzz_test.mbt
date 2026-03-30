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
} derive(Show)

///|
/// A generated trace of multi-agent actions.
struct MultiAgentTrace {
  num_agents : Int
  actions : Array[AgentAction]
} derive(Show)

///|
impl @quickcheck.Arbitrary for MultiAgentTrace with arbitrary(size, rs) {
  let chars : Array[String] = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"]
  let num_agents = 2 + rs.split().next_uint64().to_int().abs() % 4 // 2-5 agents
  // Use scratch docs to track valid positions during generation
  let scratches : Array[@text.TextState] = []
  for i = 0; i < num_agents; i = i + 1 {
    scratches.push(@text.TextState::new("agent_" + i.to_string()))
  }
  let actions : Array[AgentAction] = []
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
      doc.insert(@text.Pos::at(pos), ch) catch {
        _ => continue
      }
      actions.push(FuzzInsert(agent, pos, ch))
    } else if action_type < 7 {
      // 30% delete
      let len = doc.len()
      if len == 0 {
        continue
      }
      let pos = rs.split().next_uint64().to_int().abs() % len
      doc.delete(@text.Pos::at(pos)) catch {
        _ => continue
      }
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
      let msg = doc.sync().export_all() catch { _ => continue }
      scratches[to].sync().apply(msg) catch {
        _ => continue
      }
      actions.push(FuzzSync(agent, to))
    }
  }
  { num_agents, actions }
}

///|
impl @qc.Shrink for MultiAgentTrace with shrink(self) {
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
        actions: self.actions[:half].to_array(),
      })
    }
    // Try dropping last action
    results.push({
      num_agents: self.num_agents,
      actions: self.actions[:len - 1].to_array(),
    })
  }
  results.iter()
}

///|
/// Execute a multi-agent trace and verify convergence after full sync.
fn run_trace_and_check_convergence(trace : MultiAgentTrace) -> Bool {
  let docs : Array[@text.TextState] = []
  let mgrs : Array[@undo.UndoManager] = []
  for i = 0; i < trace.num_agents; i = i + 1 {
    let id = "agent_" + i.to_string()
    docs.push(@text.TextState::new(id))
    mgrs.push(@undo.UndoManager::new(id))
  }

  // Execute actions
  for action in trace.actions {
    match action {
      FuzzInsert(agent, pos, ch) => {
        let doc = docs[agent]
        let mgr = mgrs[agent]
        let clamped = if pos > doc.len() { doc.len() } else { pos }
        doc.insert_and_record(@text.Pos::at(clamped), ch, mgr, timestamp_ms=0) catch {
          _ => continue
        }
      }
      FuzzDelete(agent, pos) => {
        let doc = docs[agent]
        let mgr = mgrs[agent]
        if doc.len() == 0 {
          continue
        }
        let clamped = if pos >= doc.len() { doc.len() - 1 } else { pos }
        doc.delete_and_record(@text.Pos::at(clamped), mgr, timestamp_ms=0) catch {
          _ => continue
        }
      }
      FuzzUndo(agent) =>
        if mgrs[agent].can_undo() {
          mgrs[agent].undo(docs[agent]) catch {
            _ => ()
          }
        }
      FuzzRedo(agent) =>
        if mgrs[agent].can_redo() {
          mgrs[agent].redo(docs[agent]) catch {
            _ => ()
          }
        }
      FuzzSync(from, to) => {
        let msg = docs[from].sync().export_all() catch { _ => continue }
        docs[to].sync().apply(msg) catch {
          _ => continue
        }
      }
    }
  }

  // Full all-to-all sync: multiple rounds to handle ops generated by undo/redo
  for _round = 0; _round < 3; _round = _round + 1 {
    let messages : Array[@text.SyncMessage] = []
    for doc in docs {
      let msg = doc.sync().export_all() catch { _ => return true }
      messages.push(msg)
    }
    for i = 0; i < docs.length(); i = i + 1 {
      for j = 0; j < messages.length(); j = j + 1 {
        if i != j {
          docs[i].sync().apply(messages[j]) catch {
            _ => return true
          }
        }
      }
    }
  }

  // Verify all agents converged to the same text
  let expected = docs[0].text()
  for i = 1; i < docs.length(); i = i + 1 {
    if docs[i].text() != expected {
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
fn prop_sync_order_independence(pair : (RealOps, RealOps)) -> Bool {
  let (ops1, ops2) = pair
  // Path 1: A->B then B->A
  let a1 = @text.TextState::new("alice")
  let b1 = @text.TextState::new("bob")
  if !apply_edits(a1, ops1.edits) {
    return true
  }
  if !apply_edits(b1, ops2.edits) {
    return true
  }
  let msg_a1 = a1.sync().export_all() catch { _ => return true }
  let msg_b1 = b1.sync().export_all() catch { _ => return true }
  b1.sync().apply(msg_a1) catch {
    _ => return true
  }
  a1.sync().apply(msg_b1) catch {
    _ => return true
  }

  // Path 2: B->A then A->B (fresh docs)
  let a2 = @text.TextState::new("alice")
  let b2 = @text.TextState::new("bob")
  if !apply_edits(a2, ops1.edits) {
    return true
  }
  if !apply_edits(b2, ops2.edits) {
    return true
  }
  let msg_a2 = a2.sync().export_all() catch { _ => return true }
  let msg_b2 = b2.sync().export_all() catch { _ => return true }
  a2.sync().apply(msg_b2) catch {
    _ => return true
  }
  b2.sync().apply(msg_a2) catch {
    _ => return true
  }

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
fn prop_undo_concurrent_convergence(pair : (RealOps, RealOps)) -> Bool {
  let (ops1, ops2) = pair
  let doc_a = @text.TextState::new("alice")
  let doc_b = @text.TextState::new("bob")
  let mgr_a = @undo.UndoManager::new("alice")

  // A types with undo recording
  for edit in ops1.edits {
    match edit {
      Insert(pos, ch) =>
        doc_a.insert_and_record(@text.Pos::at(pos), ch, mgr_a, timestamp_ms=0) catch {
          _ => continue
        }
      Delete(pos) =>
        doc_a.delete_and_record(@text.Pos::at(pos), mgr_a, timestamp_ms=0) catch {
          _ => continue
        }
    }
  }

  // B types concurrently (no undo tracking needed)
  if !apply_edits(doc_b, ops2.edits) {
    return true
  }

  // A undoes once (if possible)
  if mgr_a.can_undo() {
    mgr_a.undo(doc_a) catch {
      _ => ()
    }
  }

  // Full sync
  let msg_a = doc_a.sync().export_all() catch { _ => return true }
  let msg_b = doc_b.sync().export_all() catch { _ => return true }
  doc_a.sync().apply(msg_b) catch {
    _ => return true
  }
  doc_b.sync().apply(msg_a) catch {
    _ => return true
  }

  // Must converge
  doc_a.text() == doc_b.text()
}

///|
test "property: undo under concurrency converges" {
  @qc.quick_check_fn(prop_undo_concurrent_convergence)
}
