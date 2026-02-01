///| Undoable impl for TextDoc
///  Lives in text/ package where TextDoc's private fields are accessible.

///|
pub impl @document.Undoable for TextDoc with lv_to_position(self, lv) {
  self.inner.lv_to_position(lv)
}

///|
pub impl @document.Undoable for TextDoc with undelete_lv(self, lv) {
  self.inner.undelete(lv) catch {
    e => raise e
  }
}

///|
pub impl @document.Undoable for TextDoc with delete_lv(self, lv) {
  self.inner.delete_by_lv(lv) catch {
    e => raise e
  }
}
