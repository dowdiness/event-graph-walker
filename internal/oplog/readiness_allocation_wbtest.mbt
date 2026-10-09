///|
test "allocation-free readiness preserves every repeated dependency check" {
  let a = @core.RawVersion("a", 0)
  let b = @core.RawVersion("b", 0)
  let c = @core.RawVersion("c", 0)
  let op = @core.Op::insert(0, [a, a, b], "target", 0, "x", Some(b), Some(c))
  for mask = 0; mask < 64; mask = mask + 1 {
    let planned : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
    let applied : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
    for index, raw in [a, b, c] {
      if mask.land(1 << index) != 0 {
        planned.add(raw)
      }
      if mask.land(1 << (index + 3)) != 0 {
        applied.add(raw)
      }
    }
    let expected = apply_changes_dependencies_for(op, None)
      .iter()
      .all(raw => planned.contains(raw) || applied.contains(raw))
    assert_eq(
      apply_changes_is_ready(op, planned, raw => applied.contains(raw), None),
      expected,
    )
  }
}

///|
test "empty pending shortcut distinguishes deferred complete from staged missing" {
  let pending_changes = PendingChanges()
  let ready = @core.Op::insert(0, [], "ready", 0, "x", None, None)
  let complete = try! pending_changes.prepare([ready], _ => false)
  assert_true(complete.storage is DeferredFast)
  assert_eq(complete.remaining_raws(pending_changes), [])
  let parent = @core.RawVersion("absent", 0)
  let missing = @core.Op::insert(
    0,
    [parent],
    "missing",
    0,
    "x",
    Some(parent),
    None,
  )
  let incomplete = try! pending_changes.prepare([missing], _ => false)
  assert_true(incomplete.storage is ImmediateGeneral(_, planned_count=_))
  assert_eq(incomplete.remaining_raws(pending_changes), [
    @core.RawVersion("missing", 0),
  ])
  assert_true(pending_changes.pending.is_empty())
}
