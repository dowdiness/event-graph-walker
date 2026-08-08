///|
/// Compare a populated maintained version with the operation-log oracle.
fn cached_version_matches_log(doc : TextState) -> Bool {
  match doc.cached_version {
    Some(actual) => actual == Version::from_ops(doc.inner.get_all_ops())
    None => false
  }
}

///|
/// Calling the public accessor is deliberately separate from the cache check:
/// this helper verifies the lazy rebuild path without hiding invalidation.
fn version_matches_log(doc : TextState) -> Bool {
  doc.version() == Version::from_ops(doc.inner.get_all_ops())
}

///|
test "version cache tracks local mutation paths" {
  let doc = try! TextState::new("alice")
  inspect(cached_version_matches_log(doc), content="true")

  try! doc.insert(Pos::at(0), "abcdef")
  inspect(cached_version_matches_log(doc), content="true")
  try! doc.delete(Pos::at(2))
  inspect(cached_version_matches_log(doc), content="true")
  try! doc.delete_range(try! Range::from_ints(1, 3))
  inspect(doc.cached_version is None, content="true")
  inspect(version_matches_log(doc), content="true")
  try! doc.replace_range(try! Range::from_ints(0, 1), "XYZ")
  inspect(doc.cached_version is None, content="true")
  inspect(version_matches_log(doc), content="true")
  try! doc.replace_range(try! Range::from_ints(doc.len(), doc.len()), "!")
  inspect(cached_version_matches_log(doc), content="true")
}

///|
test "version cache preserves zero-width replacement semantics" {
  let doc = try! TextState::new("alice")
  try! doc.insert(Pos::at(0), "ab")
  try! doc.replace_range(try! Range::from_ints(1, 1), "X")
  inspect(doc.text(), content="aXb")
  inspect(cached_version_matches_log(doc), content="true")
  try! doc.insert(Pos::at(doc.len()), "Y")
  inspect(doc.text(), content="aXbY")
  inspect(cached_version_matches_log(doc), content="true")
}

///|
test "version cache tracks undoable mutation paths" {
  let doc = try! TextState::new("alice")
  let mgr = @undo.UndoManager::new("alice")

  try! doc.insert_and_record(Pos::at(0), "abcd", mgr, timestamp_ms=1000)
  inspect(cached_version_matches_log(doc), content="true")
  try! doc.delete_and_record(Pos::at(1), mgr, timestamp_ms=2000)
  inspect(cached_version_matches_log(doc), content="true")
  try! doc.delete_range_and_record(
    try! Range::from_ints(0, 1),
    mgr,
    timestamp_ms=3000,
  )
  inspect(doc.cached_version is None, content="true")
  inspect(version_matches_log(doc), content="true")
  try! doc.replace_range_and_record(
    try! Range::from_ints(0, 1),
    "XY",
    mgr,
    timestamp_ms=4000,
  )
  inspect(doc.cached_version is None, content="true")
  inspect(version_matches_log(doc), content="true")

  inspect(mgr.undo(doc), content="true")
  inspect(doc.cached_version is None, content="true")
  inspect(version_matches_log(doc), content="true")
  inspect(mgr.redo(doc), content="true")
  inspect(doc.cached_version is None, content="true")
  inspect(version_matches_log(doc), content="true")
}

///|
test "version cache tracks remote admission and concurrent convergence" {
  let alice = try! TextState::new("alice")
  let bob = try! TextState::new("bob")
  try! alice.insert(Pos::at(0), "A")
  let initial = alice.sync().export_all()
  let _ = try! bob.sync().apply(initial)
  inspect(cached_version_matches_log(alice), content="true")
  inspect(bob.cached_version is None, content="true")
  inspect(version_matches_log(bob), content="true")

  let shared = alice.version()
  try! alice.insert(Pos::at(1), "C")
  try! bob.insert(Pos::at(1), "B")
  inspect(cached_version_matches_log(alice), content="true")
  inspect(cached_version_matches_log(bob), content="true")
  let alice_delta = alice.sync().export_since(shared)
  let bob_delta = bob.sync().export_since(shared)
  let _ = try! alice.sync().apply(bob_delta)
  let _ = try! bob.sync().apply(alice_delta)

  inspect(alice.cached_version is None, content="true")
  inspect(bob.cached_version is None, content="true")
  inspect(version_matches_log(alice), content="true")
  inspect(version_matches_log(bob), content="true")
  inspect(alice.version() == bob.version(), content="true")
  inspect(alice.text() == bob.text(), content="true")
}
