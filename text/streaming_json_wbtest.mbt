///|
fn optional_identity_json(raw : @core.RawVersion?) -> Json {
  match raw {
    Some(value) => identity_json(value)
    None => Json::null()
  }
}

///|
fn op_json(op : @core.Op) -> Json {
  let parents : Array[Json] = []
  for parent in sorted_raw(op.parents()) {
    parents.push(identity_json(parent))
  }
  let (kind, content) = match op.content() {
    @core.Insert(text) => ("insert", text.to_json())
    @core.Delete => ("delete", Json::null())
    @core.Undelete => ("undelete", Json::null())
  }
  Json::object({
    "id": identity_json(op_identity(op)),
    "parents": parents.to_json(),
    "kind": kind.to_json(),
    "content": content,
    "origin_left": optional_identity_json(op.origin_left()),
    "origin_right": optional_identity_json(op.origin_right()),
  })
}

///|
fn SyncMessage::original_sync_json_for_test(self : SyncMessage) -> String {
  let operations : Array[Json] = []
  for op in self.structural_operations {
    operations.push(op_json(op.raw()))
  }
  let heads : Array[Json] = []
  for head in self.heads {
    heads.push(identity_json(head))
  }
  Json::object({
    "schema": text_schema.to_json(),
    "format": text_sync_format.to_json(),
    "operations": operations.to_json(),
    "heads": heads.to_json(),
  }).stringify()
}

///|
test "streamed schema2 exactly matches original JSON tree encoder" {
  for agent in ["plain", "quote\"slash\\tab\tline\n", "😀漢\u{2028}\u{2029}"] {
    let source = try! TextState::new(agent)
    let empty = try! source.sync().export_all()
    assert_eq(
      empty.to_json_string(),
      SyncMessage::original_sync_json_for_test(empty),
    )
    let version = source.version()
    try! source.insert(Pos::at(0), "a\"\\\n\t\u{2028}\u{2029}😀")
    try! source.delete(Pos::at(1))
    ignore(try! source.inner.undelete(1))
    for
      message in [
        try! source.sync().export_all(),
        try! source.sync().export_since(version),
      ] {
      let encoded = message.to_json_string()
      assert_eq(encoded, SyncMessage::original_sync_json_for_test(message))
      let decoded = try! SyncMessage::from_json_string(encoded)
      assert_eq(decoded.to_json_string(), encoded)
    }
  }
}

///|
test "streaming preserves duplicate accounting and canonical concurrent order" {
  let a = try! TextState::new("z\"😀")
  let b = try! TextState::new("a\n漢")
  try! a.insert(Pos::at(0), "ABC")
  try! b.insert(Pos::at(0), "xyz")
  let operations = a.inner.get_all_ops()
  operations.append(b.inner.get_all_ops())
  operations.push(operations[0])
  let message = try! SyncMessage::SyncMessage(operations, [], None)
  assert_eq(message.decoded_operation_count, 7)
  assert_eq(message.op_count(), 6)
  assert_eq(
    message.to_json_string(),
    SyncMessage::original_sync_json_for_test(message),
  )
}

///|
test "owned waiter buckets preserve canonical wide-fork ordering" {
  let root = @core.Op::insert(0, [], "root", 0, "r", None, None)
  let root_id = @core.RawVersion("root", 0)
  let children : Array[@core.Op] = []
  for i = 513; i > 0; i = i - 1 {
    children.push(
      @core.Op::insert(i, [root_id], "child-\{i}", 0, "x", Some(root_id), None),
    )
  }
  let operations = children.copy()
  operations.push(root)
  let message = try! SyncMessage::SyncMessage(operations, [], None)
  let expected = children.copy()
  expected.sort_by((a, b) => compare_raw(op_identity(a), op_identity(b)))
  assert_eq(op_identity(message.operations[0]), root_id)
  for i = 0; i < expected.length(); i = i + 1 {
    assert_eq(op_identity(message.operations[i + 1]), op_identity(expected[i]))
  }
  assert_eq(message.to_json_string(), message.original_sync_json_for_test())
  // Input operation metadata remains immutable despite local bucket mutation.
  assert_eq(children[0].parents(), [root_id])
  assert_eq(children.length(), 513)
}
