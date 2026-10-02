///|
test "allocation-free readiness preserves every repeated dependency check" {
  let a = @core.RawVersion("a", 0)
  let b = @core.RawVersion("b", 0)
  let c = @core.RawVersion("c", 0)
  let op = @core.Op::insert(0, [a, a, b], "target", 0, "x", Some(b), Some(c))
  for mask = 0; mask < 64; mask = mask + 1 {
    let planned : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
    let admitted : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
    for index, raw in [a, b, c] {
      if mask.land(1 << index) != 0 {
        planned.add(raw)
      }
      if mask.land(1 << (index + 3)) != 0 {
        admitted.add(raw)
      }
    }
    let expected = remote_admission_dependencies_for(op, None)
      .iter()
      .all(raw => planned.contains(raw) || admitted.contains(raw))
    assert_eq(
      remote_admission_is_ready(
        op,
        planned,
        raw => admitted.contains(raw),
        None,
      ),
      expected,
    )
  }
}

///|
test "empty pending shortcut distinguishes deferred complete from staged missing" {
  let planner = RemoteAdmissionPlanner()
  let ready = @core.Op::insert(0, [], "ready", 0, "x", None, None)
  let complete = try! planner.prepare([ready], _ => false)
  assert_true(complete.storage is DeferredFast)
  assert_eq(complete.remaining_raws(planner), [])
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
  let incomplete = try! planner.prepare([missing], _ => false)
  assert_true(incomplete.storage is ImmediateGeneral(_, planned_count=_))
  assert_eq(incomplete.remaining_raws(planner), [@core.RawVersion("missing", 0)])
  assert_true(planner.pending.is_empty())
}
