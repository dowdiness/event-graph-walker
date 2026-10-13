///|
/// Projection errors owned by the Fugue projection seam.
pub(all) suberror FugueProjectionError {
  MissingOrigin(raw~ : @core.RawVersion)
  MissingCausalEntry(lv~ : Int32)
  Fugue(error~ : @fugue.FugueError)
}
