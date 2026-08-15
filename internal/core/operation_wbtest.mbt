///| Operation payload ownership tests.

///|
test "Op constructors own caller parent arrays" {
  let original = RawVersion::new("alice", 0)
  let changed = RawVersion::new("bob", 0)
  let parents = [original]
  let insert = Op::new_insert(-1, parents, "insert", 0, "i", None, None)
  let delete = Op::new_delete(-1, parents, "delete", 0, Some(original))
  let undelete = Op::new_undelete(-1, parents, "undelete", 0, Some(original))
  let from_parts = Op::new_from_parts(
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
