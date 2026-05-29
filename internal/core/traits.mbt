///| Core traits shared across packages

///|
/// Minimal resolver for mapping RawVersion -> LV
pub(open) trait RawToLv {
  fn raw_to_lv(Self, RawVersion) -> Int?
}
