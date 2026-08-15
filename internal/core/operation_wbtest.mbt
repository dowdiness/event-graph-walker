///| Operation payload ownership tests.

///|
test "Op constructors own caller parent arrays" {
  let original = RawVersion("alice", 0)
  let changed = RawVersion("bob", 0)
  let parents = [original]
  let insert = Op::insert(-1, parents, "insert", 0, "i", None, None)
  let delete = Op::delete(-1, parents, "delete", 0, Some(original))
  let undelete = Op::undelete(-1, parents, "undelete", 0, Some(original))
  let from_parts = Op(
    lv=-1,
    parents~,
    agent="parts",
    seq=0,
    content=OpContent::Insert("p"),
    origin_left=None,
    origin_right=None,
  )

  parents[0] = changed

  for op in [insert, delete, undelete, from_parts] {
    assert_eq(op.parents(), [original])
  }
}
