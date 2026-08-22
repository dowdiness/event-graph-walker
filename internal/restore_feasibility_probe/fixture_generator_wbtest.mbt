///|
fn identity_key(identity : RawIdentity) -> String {
  identity.agent + ":" + identity.sequence.to_string()
}

///|
test "R0 linear generator pins identities parents bodies and text" {
  let fixture = try! generate_fixture("S-linear", 4)
  assert_eq(fixture.fixture_id, "S-linear-4")
  assert_eq(fixture.document_id, "loomark-r0-fixture-S-linear-4")
  assert_eq(fixture.events.length(), 4)
  assert_eq(fixture.events.map(event => identity_key(event.identity)), [
    "r0-a:0", "r0-a:1", "r0-a:2", "r0-a:3",
  ])
  assert_eq(fixture.events[0].parents, [])
  assert_eq(fixture.events[1].parents, [RawIdentity(agent="r0-a", sequence=0)])
  assert_eq(
    fixture.events.map(event => bytes_hex(event.canonical_body_bytes)),
    ["0101000161", "01010102c3a9", "0101020165", "01010302cc81"],
  )
  assert_eq(fixture.final_text, "aéé")
  assert_eq(fixture.replay_order.map(identity_key), [
    "r0-a:0", "r0-a:1", "r0-a:2", "r0-a:3",
  ])
}

///|
test "R0 distributed and tombstone positions are formula-derived" {
  let distributed = try! generate_fixture("S-distributed", 7)
  assert_eq(
    distributed.events.map(event => bytes_hex(event.canonical_body_bytes)),
    [
      "0101000161", "01010102c3a9", "0101020165", "01010302cc81", "01010404f09f9982",
      "010105010a", "010102010d",
    ],
  )
  assert_eq(distributed.final_text, "aé\ré🙂\n")
  let tombstone = try! generate_fixture("S-tombstone", 6)
  assert_eq(tombstone.events[4].body, DeleteScalar(0))
  assert_eq(tombstone.events[5].body, DeleteScalar(1))
  assert_eq(tombstone.final_text, "é́")
}

///|
test "R0 replacement unicode and mixed morphologies preserve exact scalars" {
  let replacement = try! generate_fixture("S-replacement", 102)
  assert_eq(unicode_scalar_length(replacement.final_text), 2)
  assert_eq(replacement.final_text, "é")
  let unicode = try! generate_fixture("S-unicode", 7)
  assert_eq(unicode.final_text, "aéé🙂\n\r")
  assert_eq(unicode_scalar_length(unicode.final_text), 7)
  let mixed = try! generate_fixture("U-mixed", 4)
  assert_eq(mixed.final_text, "xy")
  assert_eq(
    mixed.events[3].body,
    Undelete(RawIdentity(agent="r0-a", sequence=0)),
  )
}

///|
test "R0 stable replay ignores reversed generation order and UTF-16 order" {
  let root_z = fixture_event_for_order(0, RawIdentity(agent="z", sequence=0), [])
  let root_astral = fixture_event_for_order(
    1,
    RawIdentity(agent="😀", sequence=0),
    [],
  )
  let root_accent = fixture_event_for_order(
    2,
    RawIdentity(agent="é", sequence=0),
    [],
  )
  let merge = fixture_event_for_order(
    3,
    RawIdentity(agent="merge", sequence=0),
    [root_accent.identity, root_astral.identity, root_z.identity],
  )
  let reversed = [merge, root_accent, root_astral, root_z]
  assert_eq((try! stable_topological_order(reversed)).map(identity_key), [
    "z:0", "é:0", "😀:0", "merge:0",
  ])
}

///|
test "R0 concurrent morphologies pin exact replay IDs" {
  let short = try! generate_fixture("C-short", 17)
  assert_eq(short.events.length(), 17)
  assert_eq(
    short.events[16].identity,
    RawIdentity(agent="r0-merge", sequence=0),
  )
  assert_eq(short.events[16].parents, [
    RawIdentity(agent="r0-a", sequence=7),
    RawIdentity(agent="r0-b", sequence=7),
  ])
  assert_eq(short.replay_order.map(identity_key), [
    "r0-a:0", "r0-a:1", "r0-a:2", "r0-a:3", "r0-a:4", "r0-a:5", "r0-a:6", "r0-a:7",
    "r0-b:0", "r0-b:1", "r0-b:2", "r0-b:3", "r0-b:4", "r0-b:5", "r0-b:6", "r0-b:7",
    "r0-merge:0",
  ])
  let multiroot = try! generate_fixture("C-multiroot", 4)
  assert_eq(multiroot.replay_order.map(identity_key), [
    "r0-a:0", "r0-a:1", "r0-b:0", "r0-b:1",
  ])
}

///|
test "R0 required catalog is complete deterministic and seedless" {
  let first = try! generate_required_catalog()
  let second = try! generate_required_catalog()
  assert_eq(first.fixtures.length(), 19)
  assert_eq(first.fixture_seed, "none")
  assert_eq(first.to_json_string(), second.to_json_string())
  assert_true(first.fixtures.all(fixture => fixture.event_count > 0))
  assert_true(
    first.fixtures.all(fixture => fixture.canonical_sha256.length() == 64),
  )
  assert_true(
    first.fixtures.any(fixture => fixture.fixture_id == "S-linear-100000"),
  )
  assert_true(
    first.fixtures.any(fixture => fixture.fixture_id == "A-long-10000-r050"),
  )
}

///|
test "R0 generator rejects unknown shapes and invalid scales" {
  let unknown : Result[GeneratedFixture, FixtureError] = Ok(
    generate_fixture("unknown", 4),
  ) catch {
    error => Err(error)
  }
  inspect(unknown is Err(_), content="true")
  let invalid_mixed : Result[GeneratedFixture, FixtureError] = Ok(
    generate_fixture("U-mixed", 5),
  ) catch {
    error => Err(error)
  }
  inspect(invalid_mixed is Err(_), content="true")
}
