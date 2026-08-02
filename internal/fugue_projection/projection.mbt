///|
/// The semantic visibility result of one projected operation.
pub(all) enum VisibilityChange {
  BecameVisible(@fugue.Lv)
  BecameHidden(@fugue.Lv)
  Unchanged
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
    apply(tree, op, causal_graph)
  }
}

///|
/// Apply one admitted operation and report its semantic visibility outcome.
#inline
pub fn apply_with_visible_change(
  tree : @fugue.FugueTree[String],
  op : @core.Op,
  causal_graph : @causal_graph.CausalGraph,
) -> VisibilityChange raise FugueProjectionError {
  match op.content() {
    @core.Insert(text) => {
      insert(tree, op, text, causal_graph)
      VisibilityChange::BecameVisible(@fugue.Lv(op.lv()))
    }
    @core.Delete => {
      let visible_before = tree.visible_count()
      let target = delete(tree, op, causal_graph)
      if target >= 0 && tree.visible_count() < visible_before {
        VisibilityChange::BecameHidden(@fugue.Lv(target))
      } else {
        VisibilityChange::Unchanged
      }
    }
    @core.Undelete => {
      let visible_before = tree.visible_count()
      let target = undelete(tree, op, causal_graph)
      if target >= 0 && tree.visible_count() > visible_before {
        VisibilityChange::BecameVisible(@fugue.Lv(target))
      } else {
        VisibilityChange::Unchanged
      }
    }
  }
}
