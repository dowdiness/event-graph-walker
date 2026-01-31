///| UndoManager - LV-based undo/redo plugin, generic over Undoable

///|
pub struct UndoManager {
  agent_id : String
  mut undo_stack : Array[UndoGroup]
  mut redo_stack : Array[UndoGroup]
  capture_timeout_ms : Int
  mut last_change_ms : Int
  mut tracking_enabled : Bool
} derive(Show)

///|
/// Create a new UndoManager for the given agent.
/// `capture_timeout_ms` controls time-based grouping (default 500ms).
pub fn UndoManager::new(
  agent_id : String,
  capture_timeout_ms? : Int = 500,
) -> UndoManager {
  {
    agent_id,
    undo_stack: [],
    redo_stack: [],
    capture_timeout_ms,
    last_change_ms: 0,
    tracking_enabled: true,
  }
}

///|
/// Record an insert operation for undo tracking.
/// `target_lv` is the inserted item's LV.
/// Only records if agent matches and tracking is enabled.
/// Groups by time window. Clears redo stack on new edit.
pub fn UndoManager::record_insert(
  self : UndoManager,
  target_lv : Int,
  agent : String,
  timestamp_ms : Int,
  content? : String? = None,
) -> Unit {
  self.record_item(target_lv, Insert, agent, timestamp_ms, content)
}

///|
/// Record a delete operation for undo tracking.
/// `target_lv` is the deleted item's LV (the tombstone).
/// Only records if agent matches and tracking is enabled.
/// Groups by time window. Clears redo stack on new edit.
pub fn UndoManager::record_delete(
  self : UndoManager,
  target_lv : Int,
  agent : String,
  timestamp_ms : Int,
  content? : String? = None,
) -> Unit {
  self.record_item(target_lv, Delete, agent, timestamp_ms, content)
}

///|
fn UndoManager::record_item(
  self : UndoManager,
  target_lv : Int,
  op_type : UndoOpType,
  agent : String,
  timestamp_ms : Int,
  content : String?,
) -> Unit {
  if not(self.tracking_enabled) {
    return
  }
  if agent != self.agent_id {
    return
  }
  let item : UndoItem = { target_lv, op_type, content }
  // Check if we should merge into the current group or start a new one
  let should_merge = match self.undo_stack.last() {
    Some(_) => timestamp_ms - self.last_change_ms < self.capture_timeout_ms
    None => false
  }
  if should_merge {
    match self.undo_stack.last() {
      Some(group) => group.items.push(item)
      None => ()
    }
  } else {
    self.undo_stack.push({ items: [item], timestamp: timestamp_ms })
  }
  self.last_change_ms = timestamp_ms
  self.redo_stack = []
}

///|
/// Pop undo group, apply inverses locally, push to redo.
/// Returns ops to sync (empty in Phase 1, populated in Phase 2).
pub fn[D : @document.Undoable] UndoManager::undo(
  self : UndoManager,
  doc : D,
) -> Array[@oplog.Op] raise @document.DocumentError {
  guard self.undo_stack.length() > 0
  let group = self.undo_stack.unsafe_pop()
  let was_tracking = self.tracking_enabled
  self.tracking_enabled = false
  let synced_ops : Array[@oplog.Op] = []
  let redo_items : Array[UndoItem] = []
  for i = group.items.length() - 1; i >= 0; i = i - 1 {
    let item = group.items[i]
    try {
      match item.op_type {
        Insert => {
          let pos = doc.lv_to_position(item.target_lv)
          match pos {
            Some(_) => {
              doc.delete_lv(item.target_lv)
              redo_items.push({
                target_lv: item.target_lv,
                op_type: Insert,
                content: item.content,
              })
            }
            None => ()
          }
        }
        Delete => {
          doc.undelete_lv(item.target_lv)
          redo_items.push({
            target_lv: item.target_lv,
            op_type: Delete,
            content: item.content,
          })
        }
      }
    } catch {
      @document.DocumentError::Fugue(_) => continue
      e => {
        self.tracking_enabled = was_tracking
        raise e
      }
    }
  }
  if redo_items.length() > 0 {
    redo_items.rev_in_place()
    self.redo_stack.push({ items: redo_items, timestamp: group.timestamp })
  }
  self.tracking_enabled = was_tracking
  synced_ops
}

///|
/// Pop redo group, apply inverses locally, push to undo.
/// Returns ops to sync (empty in Phase 1, populated in Phase 2).
pub fn[D : @document.Undoable] UndoManager::redo(
  self : UndoManager,
  doc : D,
) -> Array[@oplog.Op] raise @document.DocumentError {
  guard self.redo_stack.length() > 0
  let group = self.redo_stack.unsafe_pop()
  let was_tracking = self.tracking_enabled
  self.tracking_enabled = false
  let synced_ops : Array[@oplog.Op] = []
  let undo_items : Array[UndoItem] = []
  for i = group.items.length() - 1; i >= 0; i = i - 1 {
    let item = group.items[i]
    try {
      match item.op_type {
        Insert => {
          doc.undelete_lv(item.target_lv)
          undo_items.push({
            target_lv: item.target_lv,
            op_type: Insert,
            content: item.content,
          })
        }
        Delete => {
          let pos = doc.lv_to_position(item.target_lv)
          match pos {
            Some(_) => {
              doc.delete_lv(item.target_lv)
              undo_items.push({
                target_lv: item.target_lv,
                op_type: Delete,
                content: item.content,
              })
            }
            None => ()
          }
        }
      }
    } catch {
      @document.DocumentError::Fugue(_) => continue
      e => {
        self.tracking_enabled = was_tracking
        raise e
      }
    }
  }
  if undo_items.length() > 0 {
    undo_items.rev_in_place()
    self.undo_stack.push({ items: undo_items, timestamp: group.timestamp })
  }
  self.tracking_enabled = was_tracking
  synced_ops
}

///|
/// Suppress or resume tracking.
pub fn UndoManager::set_tracking(self : UndoManager, enabled : Bool) -> Unit {
  self.tracking_enabled = enabled
}

///|
/// Query tracking state.
pub fn UndoManager::is_tracking(self : UndoManager) -> Bool {
  self.tracking_enabled
}

///|
/// Check if undo is possible.
pub fn UndoManager::can_undo(self : UndoManager) -> Bool {
  self.undo_stack.length() > 0
}

///|
/// Check if redo is possible.
pub fn UndoManager::can_redo(self : UndoManager) -> Bool {
  self.redo_stack.length() > 0
}

///|
/// Reset both stacks.
pub fn UndoManager::clear(self : UndoManager) -> Unit {
  self.undo_stack = []
  self.redo_stack = []
}
