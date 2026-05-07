///| Tests for CausalSnapshot.

///|
test "fresh document produces empty snapshot" {
  let doc = @text.TextState::new("alice")
  let snap = doc.causal_snapshot()
  inspect(snap.op_count(), content="0")
  inspect(snap.frontier(), content="[]")
}

///|
test "single insert produces single-entry snapshot" {
  let doc = @text.TextState::new("alice")
  doc.insert(@text.Pos::at(0), "a")
  let snap = doc.causal_snapshot()
  inspect(snap.op_count(), content="1")
  inspect(snap.frontier(), content="[0]")
  let entry = snap.entry(0).unwrap()
  inspect(entry.agent(), content="alice")
  inspect(entry.seq(), content="0")
  inspect(entry.parents().length(), content="0")
  inspect(snap.children_count(0), content="0")
}

///|
test "two-op chain: parents and outdegree" {
  let doc = @text.TextState::new("alice")
  doc.insert(@text.Pos::at(0), "a")
  doc.insert(@text.Pos::at(1), "b")
  let snap = doc.causal_snapshot()
  inspect(snap.op_count(), content="2")
  inspect(snap.frontier(), content="[1]")
  inspect(snap.children_count(0), content="1")
  inspect(snap.children_count(1), content="0")
  let e1 = snap.entry(1).unwrap()
  inspect(e1.parents().length(), content="1")
  inspect(e1.parents()[0], content="0")
}

///|
/// Fork: two ops both depend on the same root → root has outdegree 2.
test "fork: shared parent has children_count == 2" {
  let alice = @text.TextState::new("alice")
  let bob = @text.TextState::new("bob")
  // Establish a shared root op via initial sync from alice.
  alice.insert(@text.Pos::at(0), "X")
  bob.sync().apply(alice.sync().export_all())
  // Diverge: alice and bob each insert independently after the shared root.
  alice.insert(@text.Pos::at(1), "a")
  bob.insert(@text.Pos::at(1), "b")
  // Bring alice up to date by importing bob's divergent op. Now alice's
  // graph has the shared root (LV 0) plus alice's and bob's children.
  alice.sync().apply(bob.sync().export_all())
  let snap = alice.causal_snapshot()
  // Root op has two children — alice's and bob's divergent inserts.
  inspect(snap.children_count(0), content="2")
  // Frontier holds both divergent tips.
  inspect(snap.frontier().length(), content="2")
}

///|
/// Merge: an op produced after fan-in carries multiple parents.
test "merge: post-merge op has parents.length() == 2" {
  let alice = @text.TextState::new("alice")
  let bob = @text.TextState::new("bob")
  // Shared root.
  alice.insert(@text.Pos::at(0), "X")
  bob.sync().apply(alice.sync().export_all())
  // Diverge.
  alice.insert(@text.Pos::at(1), "a")
  bob.insert(@text.Pos::at(1), "b")
  // Alice ingests bob's op — frontier now has two tips on alice's side.
  alice.sync().apply(bob.sync().export_all())
  let pre_merge_op_count = alice.causal_snapshot().op_count()
  // Alice's next insert merges the two tips: it carries both as parents.
  alice.insert(@text.Pos::at(0), "M")
  let snap = alice.causal_snapshot()
  let merge_lv = pre_merge_op_count
  let entry = snap.entry(merge_lv).unwrap()
  inspect(entry.parents().length(), content="2")
  // Frontier collapses back to a single tip after the merge.
  inspect(snap.frontier(), content="[\{merge_lv}]")
}

///|
test "out-of-range entry returns None" {
  let doc = @text.TextState::new("alice")
  let snap = doc.causal_snapshot()
  inspect(snap.entry(0) is None, content="true")
  inspect(snap.entry(-1) is None, content="true")
  inspect(snap.children_count(0), content="0")
  inspect(snap.children_count(-1), content="0")
}
