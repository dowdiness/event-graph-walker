///|
fn compact_public_archive_for_test(
  records : String,
  heads : String,
  version : String,
) -> String {
  "{\"format\":\"event-graph-walker/experimental-accepted-history\",\"schema\":1,\"actors\":[\"seed\"],\"records\":" +
  records +
  ",\"heads\":" +
  heads +
  ",\"version\":" +
  version.to_json().stringify() +
  "}"
}

///|
fn compact_public_reject_for_test(
  archive : String,
  version : String,
) -> Unit raise {
  try
    TextState::restore_compact_direct_experimental(archive, "fresh", version)
  catch {
    TextError::SyncFailed(@sync.Failure::MalformedMessage(detail=_)) => ()
    _ => fail("expected malformed experimental archive")
  } noraise {
    _ => fail("malformed archive was accepted")
  }
}

///|
test "public compact archive rejects malformed mutations before returning a document" {
  let source = TextState::new("seed")
  source.insert(Pos::at(0), "x")
  let expected = source.version().to_json_string()
  let root = "[\"i\",0,0,[],null,null,\"x\"]"
  let good = compact_public_archive_for_test(
    "[" + root + "]",
    "[[0,0]]",
    expected,
  )
  assert_eq(
    TextState::restore_compact_direct_experimental(good, "fresh", expected).text(),
    "x",
  )
  for
    records in [
      "[" + root + "," + root + "]", // Equal duplicate identity.
      "[" + root + ",[\"i\",0,0,[],null,null,\"y\"]]", // Conflicting duplicate.
      "[[\"i\",0,0,[[0,99]],null,null,\"x\"]]", // Missing parent.
      "[[\"i\",0,0,[],[0,99],null,\"x\"]]", // Missing origin.
      "[[\"i\",0,0,[],[0,0],null,\"x\"]]", // Self origin.
      "[[\"i\",0,0,[[0,1]],null,null,\"x\"],[\"i\",0,1,[],[0,0],null,\"y\"]]", // Combined cycle.
      "[[\"i\",0.5,0,[],null,null,\"x\"]]",
      "[[\"i\",0,0.5,[],null,null,\"x\"]]",
      "[[\"i\",0,0,[[0,0.5]],null,null,\"x\"]]",
      "[[\"i\",0,2147483647,[],null,null,\"xy\"]]", // Checked run overflow.
      "[[\"i\",0,0,[],null,null,\"\"]]",
      "[[\"i\",0,0,[],null,null," +
      String::make(100001, 'x').to_json().stringify() +
      "]]",
    ] {
    compact_public_reject_for_test(
      compact_public_archive_for_test(records, "[[0,0]]", expected),
      expected,
    )
  }
  for heads in ["[]", "[[0,99]]", "[[0,0],[0,0]]", "[[0,0.5]]"] {
    compact_public_reject_for_test(
      compact_public_archive_for_test("[" + root + "]", heads, expected),
      expected,
    )
  }
  compact_public_reject_for_test(good + " trailing", expected)
  assert_eq(source.text(), "x")
  assert_eq(source.version().to_json_string(), expected)
}

///|
test "public compact target must name an earlier Insert" {
  let source = TextState::new("seed")
  let root = @core.RawVersion("seed", 0)
  ignore(
    source
    .sync()
    .apply(
      SyncMessage::SyncMessage(
        [
          @core.Op::insert(-1, [], "seed", 0, "x", None, None),
          @core.Op::delete(-1, [root], "seed", 1, Some(root)),
          @core.Op::undelete(
            -1,
            [@core.RawVersion("seed", 1)],
            "seed",
            2,
            Some(root),
          ),
        ],
        [@core.RawVersion("seed", 2)],
        None,
      ),
    ),
  )
  let expected = source.version().to_json_string()
  let initial = "[\"i\",0,0,[],null,null,\"x\"]"
  let deletion = "[\"d\",0,1,[[0,0]],[0,0]]"
  let valid_undeletion = "[\"u\",0,2,[[0,1]],[0,0]]"
  let good = compact_public_archive_for_test(
    "[" + initial + "," + deletion + "," + valid_undeletion + "]",
    "[[0,2]]",
    expected,
  )
  assert_eq(
    TextState::restore_compact_direct_experimental(good, "fresh", expected).text(),
    "x",
  )
  for kind in ["d", "u"] {
    compact_public_reject_for_test(
      compact_public_archive_for_test(
        "[" +
        initial +
        "," +
        deletion +
        ",[\"" +
        kind +
        "\",0,2,[[0,1]],[0,1]]]",
        "[[0,2]]",
        expected,
      ),
      expected,
    )
  }
  compact_public_reject_for_test(
    compact_public_archive_for_test(
      "[" + initial + "," + deletion + ",[\"i\",0,2,[[0,1]],[0,1],null,\"x\"]]",
      "[[0,2]]",
      expected,
    ),
    expected,
  )
}

///|
test "public compact archive enforces exact UTF8 byte limit" {
  let source = TextState::new("seed")
  source.insert(Pos::at(0), "😀")
  let archive = source.export_compact_experimental()
  let version = source.version().to_json_string()
  let at_limit = archive +
    String::make(compact_max_bytes - @utf8.encode(archive).length(), ' ')
  assert_eq(@utf8.encode(at_limit).length(), compact_max_bytes)
  assert_eq(
    TextState::restore_compact_direct_experimental(at_limit, "fresh", version).text(),
    "😀",
  )
  compact_public_reject_for_test(at_limit + " ", version)
}

///|
test "public compact export rejects over-cap accepted history without truncating" {
  let source = TextState::new("cap-source")
  source.insert(Pos::at(0), String::make(100001, 'x'))
  try source.export_compact_experimental() catch {
    _ => ()
  } noraise {
    _ => fail("over-cap export succeeded")
  }
  assert_eq(source.len(), 100001)
  assert_eq(source.sync().export_all().op_count(), 100001)
}
