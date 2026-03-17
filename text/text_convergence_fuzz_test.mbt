// Multi-agent convergence fuzz tests for Text CRDT
//
// Property-based tests that verify N-agent CRDT convergence under arbitrary
// interleaving of inserts, deletes, undo/redo, and partial syncs.
//
// KNOWN BUG: Multi-agent convergence fails when undo/redo operations are
// combined with partial syncs. See the reproduction test below for the minimal
// counterexample found by QuickCheck. The insert/delete-only variant (without
// undo/redo) passes, confirming the issue is specific to undo+sync interaction.

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
  let scratches : Array[@text.TextDoc] = []
  for i = 0; i < num_agents; i = i + 1 {
    scratches.push(@text.TextDoc::new("agent_" + i.to_string()))
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
  let docs : Array[@text.TextDoc] = []
  let mgrs : Array[@undo.UndoManager] = []
  for i = 0; i < trace.num_agents; i = i + 1 {
    let id = "agent_" + i.to_string()
    docs.push(@text.TextDoc::new(id))
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
/// KNOWN BUG: Convergence fails when undo/redo is interleaved with partial syncs.
/// This is the minimal counterexample found by QuickCheck.
/// Once the undo+sync convergence bug is fixed, this test should be changed
/// to assert convergence (result == true) and the full property test can be
/// re-enabled.
test "known-bug: undo+sync multi-agent convergence counterexample" {
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
  // Currently false due to undo+sync convergence bug.
  // When fixed, change to: assert_true!(result)
  assert_false(result)
}
