///| Projection failure is sticky. Only an explicit session boundary rebuilds it.

///|
priv enum ProjectionHealth {
  Ready
  Unavailable(DocumentError)
}

///|
fn Document::invalidate_projection(
  self : Document,
  error : DocumentError,
) -> Unit {
  self.invalidate_text_change()
  self.indexed_state.invalidate()
  self.cursor = None
  self.projection_health = Unavailable(error)
}

///|
/// The checkout callback is an invocation-local test seam, never retained state.
fn Document::recover_projection_with(
  self : Document,
  checkout : (@oplog.OpLog, @core.Frontier) -> @branch.Branch raise @branch.BranchError,
) -> Unit raise DocumentError {
  let frontier = self.get_frontier()
  let branch = checkout(self.oplog, frontier) catch {
    error => {
      let failure = DocumentError::ProjectionRecoveryRequired(frontier~, error~)
      self.invalidate_projection(failure)
      raise failure
    }
  }
  let tree = branch.inner_tree()
  let index = IndexedState::from_tree(tree)
  let view = {
    frontier,
    version: @causal_graph.ViewVersion(self.current_graph_version()),
  }
  // Build all derived state before installing the complete accepted cut.
  self.invalidate_text_change()
  self.cursor = None
  self.tree = tree
  self.indexed_state.restore_cache(index.take_cache())
  self.view = view
  self.projection_health = Ready
}

///|
/// Called only by explicit reopening, never by a read or mutation guard.
fn Document::recover_projection(self : Document) -> Unit raise DocumentError {
  self.recover_projection_with((oplog, frontier) => {
    @branch.Branch::checkout(oplog, frontier)
  })
}

///|
pub fn Document::prepare_for_mutation(
  self : Document,
) -> Unit raise DocumentError {
  self.ensure_projection_ready()
}

///|
fn Document::ensure_projection_ready(
  self : Document,
) -> Unit raise DocumentError {
  match self.projection_health {
    Ready => ()
    Unavailable(error) => raise error
  }
}

///|
fn Document::ensure_projection_ready_for_read(
  self : Document,
) -> Unit raise DocumentError {
  self.ensure_projection_ready()
}
