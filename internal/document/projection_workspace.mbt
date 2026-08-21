///|
/// Detached projection state for one fallible authority admission.
priv struct ProjectionWorkspace {
  indexed : IndexedState
  effects : Array[ProjectionEffect]
  mut exact : Bool
}

///|
fn ProjectionWorkspace::new(
  snapshot : (@order_tree.OrderTree[VisibleRun]?, LvLocator?),
  exact : Bool,
) -> ProjectionWorkspace {
  {
    indexed: IndexedState::from_snapshot(
      if exact {
        snapshot
      } else {
        (None, None)
      },
    ),
    effects: [],
    exact,
  }
}

///|
/// Apply one committed operation and record its sequential visible effect.
fn ProjectionWorkspace::project(
  self : ProjectionWorkspace,
  tree : @fugue.FugueTree[String],
  operation : @core.Op,
  causal_graph : @causal_graph.CausalGraph,
) -> Unit raise DocumentError {
  if !self.exact {
    apply_projection(tree, operation, causal_graph)
    return
  }
  let change = apply_projection_with_visible_change(
    tree, operation, causal_graph,
  )
  if @fugue_projection.is_became_hidden(change) {
    let lv = @fugue_projection.visibility_identity(change)
    match self.indexed.lv_to_position(tree, lv.0) {
      Some(position) =>
        if self.indexed.delete_at(position) {
          self.effects.push(Delete(start=position, end=position + 1))
        } else {
          self.exact = false
          self.indexed.invalidate()
          self.effects.clear()
        }
      None => {
        self.exact = false
        self.indexed.invalidate()
        self.effects.clear()
      }
    }
  } else if @fugue_projection.is_became_visible(change) {
    let lv = @fugue_projection.visibility_identity(change)
    match tree.get(lv) {
      Some(item) =>
        match
          self.indexed.insert_visible(tree, lv.0, {
            start_lv: lv.0,
            text: item.content,
            count: 1,
          }) {
          Some(position) =>
            self.effects.push(Insert(position~, text=item.content))
          None => {
            self.exact = false
            self.indexed.invalidate()
            self.effects.clear()
          }
        }
      _ => {
        self.exact = false
        self.indexed.invalidate()
        self.effects.clear()
      }
    }
  }
}

///|
/// Move the candidate cache back to its canonical owner after success.
fn ProjectionWorkspace::take_cache(
  self : ProjectionWorkspace,
) -> (@order_tree.OrderTree[VisibleRun]?, LvLocator?) {
  self.indexed.take_cache()
}
