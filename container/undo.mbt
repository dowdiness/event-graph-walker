///| Document undo/redo internals: record hooks, transaction machinery.
///
/// All helpers here are package-private. Public API (Document::transaction,
/// undo, redo, etc.) lands in Phase 3.

///|
/// Record a forward-op snapshot into the currently-open transaction buffer.
///
/// Three gates must all pass: tracking is enabled, we are not currently
/// replaying an undo/redo, and a transaction is open. Otherwise no-op.
fn Document::record_undo_item(self : Document, item : UndoItem) -> Unit {
  if !self.tracking_enabled {
    return
  }
  if self.undo_execution_mode {
    return
  }
  if self.txn_depth <= 0 {
    return
  }
  self.txn_buffer.push(item)
}

///|
/// Open a new (possibly nested) transaction scope.
///
/// On the outermost open (0 → 1), clear the buffer defensively — it should
/// already be empty, but a prior raise during close could leave residue if
/// we ever let that happen.
fn Document::txn_open(self : Document) -> Unit {
  if self.txn_depth == 0 {
    self.txn_buffer.clear()
  }
  self.txn_depth = self.txn_depth + 1
}

///|
/// Close the current transaction scope.
///
/// Nested closes just decrement. On the outermost close (1 → 0), commit: if
/// the buffer holds any items, push a new UndoGroup onto the undo stack and
/// clear the redo stack (any new commit invalidates redo history). Always
/// clear the buffer afterward.
fn Document::txn_close(self : Document) -> Unit {
  if self.txn_depth <= 0 {
    return
  }
  self.txn_depth = self.txn_depth - 1
  if self.txn_depth == 0 {
    if self.txn_buffer.length() > 0 {
      let group : UndoGroup = { items: self.txn_buffer.copy() }
      self.undo_stack.push(group)
      self.redo_stack.clear()
    }
    self.txn_buffer.clear()
  }
}

///|
/// Run `action` inside an implicit transaction, closing on success or raise.
///
/// On raise, we still close so the depth counter and buffer stay coherent;
/// then re-raise. Used by every public mutation method to wrap per-call
/// grouping and to flatten into an enclosing explicit transaction.
fn[T, E : Error] Document::with_implicit_transaction(
  self : Document,
  action : () -> T raise E,
) -> T raise E {
  self.txn_open()
  let result = action() catch {
    e => {
      self.txn_close()
      raise e
    }
  }
  self.txn_close()
  result
}
