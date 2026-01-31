///| Core Change type shared across packages

///|
/// Represents a local edit operation (insert or delete).
/// Returned from TextDoc::insert() and TextDoc::delete().
pub(all) struct Change {
  priv op : @oplog.Op
} derive(Show)

///|
/// Create a Change from an internal Op (for advanced use).
pub fn Change::from_op(op : @oplog.Op) -> Change {
  { op, }
}

///|
/// Convert to internal Op (for advanced use/serialization).
pub fn Change::to_op(self : Change) -> @oplog.Op {
  self.op
}

///|
/// Check if this change is an insert operation.
pub fn Change::is_insert(self : Change) -> Bool {
  self.op.is_insert()
}

///|
/// Check if this change is a delete operation.
pub fn Change::is_delete(self : Change) -> Bool {
  self.op.is_delete()
}

///|
/// Get the inserted text, if this is an insert operation.
pub fn Change::get_text(self : Change) -> String? {
  self.op.get_insert_text()
}

///|
/// Get the target element LV for undo tracking.
/// For Insert: the inserted item's LV (same as op.lv).
/// For Delete: map the origin RawVersion via the resolver.
pub fn[R : RawToLv] Change::target_lv(self : Change, resolver : R) -> Int? {
  match self.op.content {
    Insert(_) => Some(self.op.lv)
    Delete =>
      match self.op.origin_left {
        None => None
        Some(raw) => resolver.raw_to_lv(raw)
      }
  }
}

///|
/// Get the agent ID that created this change.
pub fn Change::agent(self : Change) -> String {
  self.op.agent
}
