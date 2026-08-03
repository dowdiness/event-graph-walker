///|
/// The semantic visibility result of one projected operation.
///
/// The scalar encoding keeps this hot cross-package result allocation-free.
/// Double exactly represents every Int LV plus one: zero is unchanged,
/// positive values identify visible LVs, and negative values identify hidden
/// LVs.
pub type VisibilityChange = Double

///|
pub fn is_became_visible(change : VisibilityChange) -> Bool {
  change > 0.0
}

///|
pub fn is_became_hidden(change : VisibilityChange) -> Bool {
  change < 0.0
}

///|
/// Return the changed identity. Call only when `became_visible` or
/// `became_hidden` is true.
pub fn visibility_identity(change : VisibilityChange) -> @fugue.Lv {
  if change > 0.0 {
    @fugue.Lv((change - 1.0).to_int())
  } else {
    @fugue.Lv((-change - 1.0).to_int())
  }
}

///|
#inline
fn encode_visible(lv : @fugue.Lv) -> VisibilityChange {
  lv.0.to_double() + 1.0
}

///|
#inline
fn encode_hidden(lv : @fugue.Lv) -> VisibilityChange {
  -(lv.0.to_double() + 1.0)
}

///|
#inline
fn encode_unchanged() -> VisibilityChange {
  0.0
}

///|
/// Resolve an operation's raw origin through the admitted causal graph.
#inline
fn resolve_origin(
  causal_graph : @causal_graph.CausalGraph,
  raw : @core.RawVersion,
) -> @fugue.Lv raise FugueProjectionError {
  match causal_graph.raw_to_lv(raw) {
    Some(lv) => @fugue.Lv(lv)
    None => raise FugueProjectionError::MissingOrigin(raw~)
  }
}

///|
/// Resolve causal metadata before touching the Fugue tree.
#inline
fn resolve_causal_entry(
  causal_graph : @causal_graph.CausalGraph,
  lv : Int,
) -> @core.GraphEntry raise FugueProjectionError {
  match causal_graph.get_entry(lv) {
    Some(entry) => entry
    None => raise FugueProjectionError::MissingCausalEntry(lv~)
  }
}

///|
/// Insert one operation after resolving all of its causal preconditions.
#inline
fn insert(
  tree : @fugue.FugueTree[String],
  op : @core.Op,
  text : String,
  causal_graph : @causal_graph.CausalGraph,
) -> Unit raise FugueProjectionError {
  let origin_left = match op.origin_left() {
    Some(raw) => Some(resolve_origin(causal_graph, raw))
    None => None
  }
  let origin_right = match op.origin_right() {
    Some(raw) => Some(resolve_origin(causal_graph, raw))
    None => None
  }
  let entry = resolve_causal_entry(causal_graph, op.lv())
  tree.insert({
    id: @fugue.Lv(op.lv()),
    content: text,
    origin_left,
    origin_right,
    timestamp: @fugue.Timestamp(entry.timestamp),
    agent: @fugue.ReplicaId(entry.agent),
  })
}

///|
/// Delete one operation, returning its resolved LV or -1 when targetless.
#inline
fn delete(
  tree : @fugue.FugueTree[String],
  op : @core.Op,
  causal_graph : @causal_graph.CausalGraph,
) -> Int raise FugueProjectionError {
  match op.origin_left() {
    None => -1
    Some(raw) => {
      let target = resolve_origin(causal_graph, raw)
      let entry = resolve_causal_entry(causal_graph, op.lv())
      tree.delete_with_ts(target, entry.timestamp, entry.agent) catch {
        error => raise FugueProjectionError::Fugue(error~)
      }
      target.0
    }
  }
}

///|
/// Undelete one operation, returning its resolved LV or -1 when targetless.
#inline
fn undelete(
  tree : @fugue.FugueTree[String],
  op : @core.Op,
  causal_graph : @causal_graph.CausalGraph,
) -> Int raise FugueProjectionError {
  match op.origin_left() {
    None => -1
    Some(raw) => {
      let target = resolve_origin(causal_graph, raw)
      let entry = resolve_causal_entry(causal_graph, op.lv())
      tree.undelete_with_ts(target, entry.timestamp, entry.agent) catch {
        error => raise FugueProjectionError::Fugue(error~)
      }
      target.0
    }
  }
}

///|
/// Apply one admitted operation without observing a visibility change.
#inline
pub fn apply(
  tree : @fugue.FugueTree[String],
  op : @core.Op,
  causal_graph : @causal_graph.CausalGraph,
) -> Unit raise FugueProjectionError {
  match op.content() {
    @core.Insert(text) => insert(tree, op, text, causal_graph)
    @core.Delete => {
      let _ = delete(tree, op, causal_graph)
    }
    @core.Undelete => {
      let _ = undelete(tree, op, causal_graph)
    }
  }
}

///|
/// Apply an already-collected causal sequence without allocating a new batch.
/// A later failure preserves every earlier successful tree mutation.
#inline
pub fn apply_all(
  tree : @fugue.FugueTree[String],
  operations : ArrayView[@core.Op],
  causal_graph : @causal_graph.CausalGraph,
) -> Unit raise FugueProjectionError {
  for op in operations {
    // Keep dispatch inside the batch seam. wasm-gc does not reliably inline a
    // raising public per-operation call during Branch replay.
    match op.content() {
      @core.Insert(text) => {
        // Keep the replay specialization explicit: wasm-gc retains measurable
        // per-item overhead when this raising helper remains a call.
        let origin_left = match op.origin_left() {
          Some(raw) => Some(resolve_origin(causal_graph, raw))
          None => None
        }
        let origin_right = match op.origin_right() {
          Some(raw) => Some(resolve_origin(causal_graph, raw))
          None => None
        }
        let entry = resolve_causal_entry(causal_graph, op.lv())
        tree.insert({
          id: @fugue.Lv(op.lv()),
          content: text,
          origin_left,
          origin_right,
          timestamp: @fugue.Timestamp(entry.timestamp),
          agent: @fugue.ReplicaId(entry.agent),
        })
      }
      @core.Delete => {
        let _ = delete(tree, op, causal_graph)
      }
      @core.Undelete => {
        let _ = undelete(tree, op, causal_graph)
      }
    }
  }
}

///|
/// Apply one admitted operation and report its semantic visibility outcome.
pub fn apply_with_visible_change(
  tree : @fugue.FugueTree[String],
  op : @core.Op,
  causal_graph : @causal_graph.CausalGraph,
) -> VisibilityChange raise FugueProjectionError {
  match op.content() {
    @core.Insert(text) => {
      insert(tree, op, text, causal_graph)
      encode_visible(@fugue.Lv(op.lv()))
    }
    @core.Delete => {
      let visible_before = tree.visible_count()
      let target = delete(tree, op, causal_graph)
      if target >= 0 && tree.visible_count() < visible_before {
        encode_hidden(@fugue.Lv(target))
      } else {
        encode_unchanged()
      }
    }
    @core.Undelete => {
      let visible_before = tree.visible_count()
      let target = undelete(tree, op, causal_graph)
      if target >= 0 && tree.visible_count() > visible_before {
        encode_visible(@fugue.Lv(target))
      } else {
        encode_unchanged()
      }
    }
  }
}
