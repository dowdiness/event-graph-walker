///|
/// The semantic visibility result of one projected operation.
pub(all) enum VisibilityChange {
  BecameVisible(@fugue.Lv, String)
  BecameHidden(@fugue.Lv)
  Unchanged
}

///|
/// Resolved operation data is private to the projection core and mutation seam.
priv enum ResolvedProjection {
  Noop
  Insert(
    id~ : @fugue.Lv,
    text~ : String,
    origin_left~ : @fugue.Lv?,
    origin_right~ : @fugue.Lv?,
    timestamp~ : Int,
    agent~ : String
  )
  Delete(target~ : @fugue.Lv, timestamp~ : Int, agent~ : String)
  Undelete(target~ : @fugue.Lv, timestamp~ : Int, agent~ : String)
}

///|
/// Resolve an operation's raw origin through the admitted causal graph.
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
/// Resolve all causal operation preconditions without touching the tree.
fn resolve_projection(
  op : @core.Op,
  causal_graph : @causal_graph.CausalGraph,
) -> ResolvedProjection raise FugueProjectionError {
  let op_lv = op.lv()
  match op.content() {
    @core.Insert(text) => {
      let origin_left = match op.origin_left() {
        Some(raw) => Some(resolve_origin(causal_graph, raw))
        None => None
      }
      let origin_right = match op.origin_right() {
        Some(raw) => Some(resolve_origin(causal_graph, raw))
        None => None
      }
      let entry = resolve_causal_entry(causal_graph, op_lv)
      ResolvedProjection::Insert(
        id=@fugue.Lv(op_lv),
        text~,
        origin_left~,
        origin_right~,
        timestamp=entry.timestamp,
        agent=entry.agent,
      )
    }
    @core.Delete =>
      match op.origin_left() {
        None => ResolvedProjection::Noop
        Some(raw) => {
          let target = resolve_origin(causal_graph, raw)
          let entry = resolve_causal_entry(causal_graph, op_lv)
          ResolvedProjection::Delete(
            target~,
            timestamp=entry.timestamp,
            agent=entry.agent,
          )
        }
      }
    @core.Undelete =>
      match op.origin_left() {
        None => ResolvedProjection::Noop
        Some(raw) => {
          let target = resolve_origin(causal_graph, raw)
          let entry = resolve_causal_entry(causal_graph, op_lv)
          ResolvedProjection::Undelete(
            target~,
            timestamp=entry.timestamp,
            agent=entry.agent,
          )
        }
      }
  }
}

///|
/// The one Fugue mutation seam shared by both public entry points.
fn mutate_resolved(
  tree : @fugue.FugueTree[String],
  resolved : ResolvedProjection,
) -> Unit raise FugueProjectionError {
  match resolved {
    ResolvedProjection::Noop => ()
    ResolvedProjection::Insert(
      id~,
      text~,
      origin_left~,
      origin_right~,
      timestamp~,
      agent~
    ) =>
      tree.insert({
        id,
        content: text,
        origin_left,
        origin_right,
        timestamp: @fugue.Timestamp(timestamp),
        agent: @fugue.ReplicaId(agent),
      })
    ResolvedProjection::Delete(target~, timestamp~, agent~) =>
      tree.delete_with_ts(target, timestamp, agent) catch {
        error => raise FugueProjectionError::Fugue(error~)
      }
    ResolvedProjection::Undelete(target~, timestamp~, agent~) =>
      tree.undelete_with_ts(target, timestamp, agent) catch {
        error => raise FugueProjectionError::Fugue(error~)
      }
  }
}

///|
/// Apply one admitted operation without observing a visibility change.
pub fn apply(
  tree : @fugue.FugueTree[String],
  op : @core.Op,
  causal_graph : @causal_graph.CausalGraph,
) -> Unit raise FugueProjectionError {
  let resolved = resolve_projection(op, causal_graph)
  mutate_resolved(tree, resolved)
}

///|
/// Apply one admitted operation and report its semantic visibility outcome.
pub fn apply_with_visible_change(
  tree : @fugue.FugueTree[String],
  op : @core.Op,
  causal_graph : @causal_graph.CausalGraph,
) -> VisibilityChange raise FugueProjectionError {
  let resolved = resolve_projection(op, causal_graph)
  // Only an observed undelete needs the target content for its result. Read it
  // before the shared mutation seam so a missing target cannot mutate the tree.
  let undelete_text = match resolved {
    ResolvedProjection::Undelete(target~, ..) =>
      match tree.get(target) {
        Some(item) => Some(item.content)
        None =>
          raise FugueProjectionError::Fugue(
            error=@fugue.FugueError::MissingItem(id=target),
          )
      }
    _ => None
  }
  let visible_before = tree.visible_count()
  mutate_resolved(tree, resolved)
  let visible_after = tree.visible_count()
  match resolved {
    ResolvedProjection::Noop => VisibilityChange::Unchanged
    ResolvedProjection::Insert(id~, text~, ..) =>
      VisibilityChange::BecameVisible(id, text)
    ResolvedProjection::Delete(target~, ..) =>
      if visible_after < visible_before {
        VisibilityChange::BecameHidden(target)
      } else {
        VisibilityChange::Unchanged
      }
    ResolvedProjection::Undelete(target~, ..) =>
      match undelete_text {
        Some(text) =>
          if visible_after > visible_before {
            VisibilityChange::BecameVisible(target, text)
          } else {
            VisibilityChange::Unchanged
          }
        None => VisibilityChange::Unchanged
      }
  }
}
