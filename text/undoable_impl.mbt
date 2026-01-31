///| Undoable impl for TextDoc
///  Lives in text/ package where TextDoc's private fields are accessible.

///|
pub impl @document.Undoable for TextDoc with lv_to_position(self, lv) {
  self.inner.tree.lv_to_position(lv)
}

///|
pub impl @document.Undoable for TextDoc with undelete_lv(self, lv) {
  self.inner.tree.undelete(lv) catch {
    e => raise @document.DocumentError::Fugue(e)
  }
}

///|
pub impl @document.Undoable for TextDoc with delete_lv(self, lv) {
  self.inner.tree.delete(lv) catch {
    e => raise @document.DocumentError::Fugue(e)
  }
}
