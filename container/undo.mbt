///| Document undo/redo internals and public API.
///
/// The record hooks, transaction machinery, and the undo/redo execution path
/// live here. Public Document methods (transaction, undo, redo, accessors)
/// are at the bottom of this file; internal helpers come first.

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

// ============================================================================
// Undo/redo execution path
// ============================================================================

///|
/// Emit a text op as part of an undo or redo replay.
///
/// Allocates a fresh LV+timestamp for the op itself (the target LV of the
/// Delete/Undelete still refers to the original insert). Mirrors
/// `Document::delete_text` minus the position → LV lookup.
fn Document::emit_replay_text_op(
  self : Document,
  block : @mt.TreeNodeId,
  kind : ReplayTextKind,
  target : Int,
) -> Unit raise DocumentError {
  let (lv, timestamp, version) = self.next_version_with_raw()
  let parents = self.raw_parents_for_lv(lv)
  let text_op : TextOp = match kind {
    Kdelete => Delete({ target, timestamp, agent: self.agent_id })
    Kundelete => Undelete({ target, timestamp, agent: self.agent_id })
  }
  let block_text_op : BlockTextOp = { block, op: text_op }
  self.apply_block_text_op(block, block_text_op)
  let _ = self.record_text_op(block_text_op)
  let _ = self.record_sync_text_op({ version, parents, block, op: text_op })
}

///|
priv enum ReplayTextKind {
  Kdelete
  Kundelete
}

///|
/// Emit a property op as part of an undo or redo replay.
fn Document::emit_replay_property(
  self : Document,
  target : @mt.TreeNodeId,
  key : String,
  value : String,
) -> Unit raise DocumentError {
  let (lv, timestamp, version) = self.next_version_with_raw()
  let parents = self.raw_parents_for_lv(lv)
  let op : @mt.TreePropertyOp = {
    timestamp,
    target,
    key,
    value,
    agent: self.agent_id,
  }
  self.apply_property_op(op)
  let _ = self.record_op(@mt.SetProperty(op))
  let _ = self.record_sync_tree_op({ version, parents, op: @mt.SetProperty(op) })
}

///|
/// Apply the inverse of `item` during an undo pass.
fn Document::apply_undo(
  self : Document,
  item : UndoItem,
) -> Unit raise DocumentError {
  match item {
    TextInsert(block~, lv~, content=_) =>
      // Undo an insert: tombstone the LV we created.
      self.emit_replay_text_op(block, Kdelete, lv)
    TextDelete(block~, lv~, content=_) =>
      // Undo a delete: revive the tombstone.
      self.emit_replay_text_op(block, Kundelete, lv)
    TreeMove(target~, old_parent~, old_pos~, new_parent=_, new_pos=_) =>
      // Move back to the pre-move parent/position.
      self.emit_move_op(target, old_parent, old_pos)
    TreeCreate(target~, parent=_, pos=_) => {
      // Node exists; move it to trash. Fresh trash position.
      let position = self.position_after_last_child(@mt.trash_id)
      self.emit_move_op(target, @mt.trash_id, position)
    }
    TreeDelete(target~, old_parent~, old_pos~) =>
      // Node is in trash; move it back to its original parent/position.
      self.emit_move_op(target, old_parent, old_pos)
    PropertySet(target~, key~, old_value~, new_value=_) =>
      self.emit_replay_property(target, key, old_value.unwrap_or(""))
  }
}

///|
/// Apply the forward direction of `item` during a redo pass.
fn Document::apply_redo(
  self : Document,
  item : UndoItem,
) -> Unit raise DocumentError {
  match item {
    TextInsert(block~, lv~, content=_) =>
      // Redo of insert: revive tombstoned LV via Undelete. LWW-wins because
      // we allocate a higher timestamp.
      self.emit_replay_text_op(block, Kundelete, lv)
    TextDelete(block~, lv~, content=_) =>
      // Redo of delete: re-tombstone at a fresh higher timestamp.
      self.emit_replay_text_op(block, Kdelete, lv)
    TreeMove(target~, old_parent=_, old_pos=_, new_parent~, new_pos~) =>
      self.emit_move_op(target, new_parent, new_pos)
    TreeCreate(target~, parent~, pos~) =>
      // Node is in trash (from undo); move back to its original slot.
      self.emit_move_op(target, parent, pos)
    TreeDelete(target~, old_parent=_, old_pos=_) => {
      // Redo of delete: move back to trash with a fresh trash position.
      let position = self.position_after_last_child(@mt.trash_id)
      self.emit_move_op(target, @mt.trash_id, position)
    }
    PropertySet(target~, key~, old_value=_, new_value~) =>
      self.emit_replay_property(target, key, new_value)
  }
}

///|
/// Reverse the most-recent group of forward ops. Returns true if a group was
/// popped, false if the undo stack was empty.
///
/// Items that fail to invert (e.g. target remotely trashed beyond recovery)
/// are silently skipped per §10.5 of the design. The undo/redo execution path
/// bypasses `with_implicit_transaction` so the redo stack is not wiped
/// mid-operation.
pub fn Document::undo(self : Document) -> Bool {
  let group = match self.undo_stack.pop() {
    None => return false
    Some(group) => group
  }
  self.undo_execution_mode = true
  let reversed_redo : Array[UndoItem] = []
  let items = group.items
  let mut i = items.length() - 1
  while i >= 0 {
    let item = items[i]
    let applied = try {
      self.apply_undo(item)
      true
    } catch {
      _ => false
    }
    if applied {
      reversed_redo.push(item)
    }
    i = i - 1
  }
  self.undo_execution_mode = false
  if reversed_redo.length() > 0 {
    self.redo_stack.push({ items: reversed_redo.rev() })
  }
  true
}

///|
/// Re-apply the most-recently undone group. Returns true if a group was
/// popped, false if the redo stack was empty.
pub fn Document::redo(self : Document) -> Bool {
  let group = match self.redo_stack.pop() {
    None => return false
    Some(group) => group
  }
  self.undo_execution_mode = true
  let next_undo : Array[UndoItem] = []
  for item in group.items {
    let applied = try {
      self.apply_redo(item)
      true
    } catch {
      _ => false
    }
    if applied {
      next_undo.push(item)
    }
  }
  self.undo_execution_mode = false
  if next_undo.length() > 0 {
    self.undo_stack.push({ items: next_undo })
  }
  true
}

// ============================================================================
// Public API — grouping and introspection
// ============================================================================

///|
/// Group the mutations inside `action` so they undo and redo as one unit.
///
/// Nested transactions flatten into the outermost one. If `action` raises,
/// the transaction still closes; any items already buffered are discarded.
pub fn[T, E : Error] Document::transaction(
  self : Document,
  action : () -> T raise E,
) -> T raise E {
  self.with_implicit_transaction(action)
}

///|
pub fn Document::can_undo(self : Document) -> Bool {
  self.undo_stack.length() > 0
}

///|
pub fn Document::can_redo(self : Document) -> Bool {
  self.redo_stack.length() > 0
}

///|
/// Drop both undo and redo history and reset any in-progress transaction.
pub fn Document::clear_undo(self : Document) -> Unit {
  self.undo_stack.clear()
  self.redo_stack.clear()
  self.txn_buffer.clear()
  self.txn_depth = 0
}

///|
pub fn Document::is_tracking(self : Document) -> Bool {
  self.tracking_enabled
}

///|
/// Enable or suppress recording of future mutations into the undo stack.
/// When disabled, mutations still apply and sync — only the undo buffer is
/// bypassed.
pub fn Document::set_tracking(self : Document, enabled : Bool) -> Unit {
  self.tracking_enabled = enabled
}
