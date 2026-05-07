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
test "out-of-range entry returns None" {
  let doc = @text.TextState::new("alice")
  let snap = doc.causal_snapshot()
  inspect(snap.entry(0) is None, content="true")
  inspect(snap.entry(-1) is None, content="true")
  inspect(snap.children_count(0), content="0")
  inspect(snap.children_count(-1), content="0")
}
