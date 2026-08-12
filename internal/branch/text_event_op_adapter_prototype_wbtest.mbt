///| Differential adapter from paper-style document events to the existing OpLog.
/// Test-only: the canonical TextEvent remains position-based; Fugue origins are
/// derived only while constructing the transient compatibility projection.

///|
test "adapter: local text events match existing Branch checkout" {
  let source = TextEventLog::new("adapter-local")
  ignore(try! source.append_insert(0, "a"))
  ignore(try! source.append_insert(1, "b"))
  ignore(try! source.append_insert(2, "c"))
  ignore(try! source.append_delete(1))

  let adapted = try! source.to_existing_oplog()
  let branch = try! Branch::checkout(adapted, adapted.get_frontier())
  assert_eq(branch.to_text(), source.checkout_current())
}

///|
test "adapter: concurrent position events match Fugue ordering" {
  let left = TextEventLog::new("adapter-left")
  let right = TextEventLog::new("adapter-right")
  ignore(try! left.append_insert(0, "A"))
  ignore(try! right.append_insert(0, "B"))
  assert_true(left.merge_from(right))

  let adapted = try! left.to_existing_oplog()
  let branch = try! Branch::checkout(adapted, adapted.get_frontier())
  assert_eq(branch.to_text(), left.checkout_current())
}

///|
test "adapter: tombstone anchors and later deletes preserve text" {
  let source = TextEventLog::new("adapter-tombstone")
  ignore(try! source.append_insert(0, "a"))
  ignore(try! source.append_insert(1, "b"))
  ignore(try! source.append_insert(2, "c"))
  ignore(try! source.append_delete(1))
  ignore(try! source.append_insert(1, "x"))
  ignore(try! source.append_delete(1))

  let adapted = try! source.to_existing_oplog()
  let branch = try! Branch::checkout(adapted, adapted.get_frontier())
  assert_eq(branch.to_text(), source.checkout_current())
}

///|
test "adapter: pending admission is preserved before conversion" {
  let source = TextEventLog::new("adapter-pending-source")
  let parent = try! source.append_insert(0, "p")
  let child = try! source.append_insert(1, "c")
  let target = TextEventLog::new("adapter-pending-target")
  assert_true(target.merge_event(child))
  assert_eq(target.checkout_current(), "")
  assert_true(target.merge_event(parent))

  let adapted = try! target.to_existing_oplog()
  let branch = try! Branch::checkout(adapted, adapted.get_frontier())
  assert_eq(branch.to_text(), target.checkout_current())
}

///|
fn TextEventLog::to_existing_oplog(
  self : TextEventLog,
) -> @oplog.OpLog raise @oplog.OpLogError {
  let destination = @oplog.OpLog::new("text-event-adapter")
  let frontier = self.graph.get_frontier()
  let trace = self.checkout_trace(frontier)
  for lv in self.graph.walk_from_frontier(frontier).iter_units() {
    let event = self.events[lv]
    let op = match event.edit {
      TextInsert(_, text) =>
        @core.Op::new_insert(
          -1,
          event.parents.copy(),
          event.id.agent,
          event.id.seq,
          text,
          text_event_origin_raw(self.graph, trace.insert_left_parents[lv]),
          text_event_origin_raw(self.graph, trace.insert_right_parents[lv]),
        )
      TextDelete(_) => {
        let target = trace.delete_targets[lv]
        guard target >= 0 else {
          abort("text event delete did not resolve a transient target")
        }
        @core.Op::new_delete(
          -1,
          event.parents.copy(),
          event.id.agent,
          event.id.seq,
          Some(text_event_required_raw(self.graph, target)),
        )
      }
    }
    let admitted = destination.apply_remote(op)
    guard admitted.length() == 1 else {
      abort("text event adapter did not admit exactly one event")
    }
  }
  destination
}

///|
fn text_event_origin_raw(
  graph : @causal_graph.CausalGraph,
  lv : Int,
) -> @core.RawVersion? {
  if lv < 0 {
    None
  } else {
    Some(text_event_required_raw(graph, lv))
  }
}

///|
fn text_event_required_raw(
  graph : @causal_graph.CausalGraph,
  lv : Int,
) -> @core.RawVersion {
  match graph.lv_to_raw(lv) {
    Some(raw) => raw
    None => abort("text event adapter origin is missing from source graph")
  }
}
