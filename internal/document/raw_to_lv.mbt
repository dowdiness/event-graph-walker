///| Core trait impls for document

///|
/// Implement RawToLv for Document
pub impl @core.RawToLv for Document with fn raw_to_lv(self, raw) {
  self.oplog.causal_graph().raw_to_lv(raw)
}

// --- Explicit trait-method promotions (E0079) ---

///|
#doc(hidden)
pub extend Document with @dowdiness/event-graph-walker/internal/core.RawToLv::{
  raw_to_lv,
}
