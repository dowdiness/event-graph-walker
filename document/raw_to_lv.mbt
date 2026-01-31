///| Core trait impls for document

///|
/// Implement RawToLv for Document
pub impl @core.RawToLv for Document with raw_to_lv(self, raw) {
  self.oplog.graph.raw_to_lv(raw)
}
