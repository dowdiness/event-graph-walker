///| Tests for CausalView.

///|
test "fresh document produces empty snapshot" {
  let doc = try! @text.TextState::new("alice")
  let snap = doc.causal_view()
  inspect(snap.op_count(), content="0")
  @debug.debug_inspect(snap.frontier(), content="[]")
}

///|
test "single insert produces single-entry snapshot" {
  let doc = try! @text.TextState::new("alice")
  doc.insert(@text.Pos::at(0), "a")
  let snap = doc.causal_view()
  inspect(snap.op_count(), content="1")
  @debug.debug_inspect(snap.frontier(), content="[0]")
  let entry = snap.entry(0).unwrap()
  inspect(entry.agent(), content="alice")
  inspect(entry.seq(), content="0")
  inspect(entry.parents().length(), content="0")
  assert_eq(snap.children_counts(), [0])
}

///|
test "two-op chain: parents and outdegree" {
  let doc = try! @text.TextState::new("alice")
  doc.insert(@text.Pos::at(0), "a")
  doc.insert(@text.Pos::at(1), "b")
  let snap = doc.causal_view()
  inspect(snap.op_count(), content="2")
  @debug.debug_inspect(snap.frontier(), content="[1]")
  assert_eq(snap.children_counts(), [1, 0])
  let e1 = snap.entry(1).unwrap()
  inspect(e1.parents().length(), content="1")
  inspect(e1.parents()[0], content="0")
}

///|
/// Fork: two ops both depend on the same root → root has outdegree 2.
test "fork: shared parent has two children" {
  let alice = try! @text.TextState::new("alice")
  let bob = try! @text.TextState::new("bob")
  // Establish a shared root op via initial sync from alice.
  alice.insert(@text.Pos::at(0), "X")
  let _ = bob.sync().apply(alice.sync().export_all())
  // Diverge: alice and bob each insert independently after the shared root.
  alice.insert(@text.Pos::at(1), "a")
  bob.insert(@text.Pos::at(1), "b")
  // Bring alice up to date by importing bob's divergent op. Now alice's
  // graph has the shared root (LV 0) plus alice's and bob's children.
  let _ = alice.sync().apply(bob.sync().export_all())
  let snap = alice.causal_view()
  // Root op has two children — alice's and bob's divergent inserts.
  assert_eq(snap.children_counts(), [2, 0, 0])
  // Frontier holds both divergent tips.
  inspect(snap.frontier().length(), content="2")
}

///|
/// Merge: an op produced after fan-in carries multiple parents.
test "merge: post-merge op has parents.length() == 2" {
  let alice = try! @text.TextState::new("alice")
  let bob = try! @text.TextState::new("bob")
  // Shared root.
  alice.insert(@text.Pos::at(0), "X")
  let _ = bob.sync().apply(alice.sync().export_all())
  // Diverge.
  alice.insert(@text.Pos::at(1), "a")
  bob.insert(@text.Pos::at(1), "b")
  // Alice ingests bob's op — frontier now has two tips on alice's side.
  let _ = alice.sync().apply(bob.sync().export_all())
  let pre_merge_op_count = alice.causal_view().op_count()
  // Alice's next insert merges the two tips: it carries both as parents.
  alice.insert(@text.Pos::at(0), "M")
  let snap = alice.causal_view()
  let merge_lv = pre_merge_op_count
  let entry = snap.entry(merge_lv).unwrap()
  inspect(entry.parents().length(), content="2")
  // Frontier collapses back to a single tip after the merge.
  @debug.debug_inspect(snap.frontier(), content="[\{merge_lv}]")
}

///|
test "out-of-range entry returns None" {
  let doc = try! @text.TextState::new("alice")
  let snap = doc.causal_view()
  inspect(snap.entry(0) is None, content="true")
  inspect(snap.entry(-1) is None, content="true")
  assert_eq(snap.children_counts(), [])
}

///|
test "frontier and child counts are owned captures of a live view" {
  let doc = try! @text.TextState::new("alice")
  doc.insert(@text.Pos::at(0), "abc")
  let snapshot = doc.causal_view()
  let counts = snapshot.children_counts()
  let frontier = snapshot.frontier()
  assert_eq(frontier, [2])
  assert_eq(counts, [1, 1, 0])
  doc.insert(@text.Pos::at(3), "d")
  assert_eq(frontier, [2])
  assert_eq(snapshot.frontier(), [3])
  assert_eq(counts, [1, 1, 0])
  assert_eq(snapshot.children_counts(), [1, 1, 1, 0])
  frontier.clear()
  counts[0] = 99
  assert_eq(snapshot.frontier(), [3])
  assert_eq(snapshot.children_counts(), [1, 1, 1, 0])
}
