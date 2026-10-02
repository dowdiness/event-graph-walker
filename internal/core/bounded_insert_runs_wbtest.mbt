///|
test "legacy oversized insert runs remain decodable and pure" {
  let chars : Array[Char] = Array::make(2049, '😀')
  let run : OpRun = {
    start_lv: 0,
    agent: "legacy-large",
    start_seq: 0,
    content: Inserts(chars),
    parents: [],
    origin_left: None,
    origin_right: None,
    count: chars.length(),
  }
  let decoded : OpRun = try! @json.from_json(
    try! @json.parse(run.to_json().stringify()),
  )
  assert_eq(decoded, run)
  let next = OpRun::from_op(
    Op::insert(
      2049,
      [RawVersion("legacy-large", 2048)],
      "legacy-large",
      2049,
      "x",
      Some(RawVersion("legacy-large", 2048)),
      None,
    ),
  )
  assert_true(!@rle.Mergeable::can_merge(run, next))
  // Pure merge itself is intentionally not a validator or decoder limit.
  let merged = @rle.Mergeable::merge(run, next)
  assert_eq(run.count, 2049)
  assert_eq(chars.length(), 2049)
  assert_eq(merged.decompress(2049).unwrap().content(), Insert("x"))
  assert_eq(run.decompress(2048).unwrap().content(), Insert("😀"))
  assert_true(run.decompress(2049) is None)
}
