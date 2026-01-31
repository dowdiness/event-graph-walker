///| Core traits shared across packages

///|
/// Minimal resolver for mapping RawVersion -> LV
pub(open) trait RawToLv {
  raw_to_lv(Self, @causal_graph.RawVersion) -> Int?
}
