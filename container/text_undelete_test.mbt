///| TextOp::Undelete wire-protocol tests.
///
/// Phase 1 wire tests: validate that the new Undelete variant routes through
/// `undelete_with_ts` for LWW-correct revival. Because no production code path
/// emits Undelete until Phase 3 lands, these tests synthesize the op and feed
/// it via the public `apply_remote_text_op`. Causal/pending behavior is
/// covered in Phase 4.

///|
fn find_insert_lv(doc : @container.Document, content : String) -> Int {
  let mut lv = -1
  for op in doc.export_text_ops() {
    match op.op {
      @container.Insert(ins) => if ins.content == content { lv = ins.id }
      _ => ()
    }
  }
  lv
}

///|
fn find_delete_target_ts(doc : @container.Document, target : Int) -> Int {
  let mut ts = -1
  for op in doc.export_text_ops() {
    match op.op {
      @container.Delete(d) => if d.target == target { ts = d.timestamp }
      _ => ()
    }
  }
  ts
}

///|
/// Task 1.5 — local Delete then synthesized Undelete round-trip.
test "document: Undelete revives a locally-deleted char" {
  let doc = @container.Document::new("alice")
  let block = doc.create_node(parent=@container.root_id)
  doc.insert_text(block, 0, "hello")
  doc.delete_text(block, 0)
  inspect(doc.get_text(block), content="ello")
  let h_lv = find_insert_lv(doc, "h")
  let del_ts = find_delete_target_ts(doc, h_lv)
  let undelete_op : @container.BlockTextOp = {
    block,
    op: @container.Undelete({
      target: h_lv,
      timestamp: del_ts + 1000,
      agent: "alice",
    }),
  }
  doc.apply_remote_text_op(undelete_op)
  inspect(doc.get_text(block), content="hello")
}

///|
/// Task 1.6 — convergence under two orderings (higher-ts Undelete beats Delete).
test "document: Undelete converges across orderings (delete-then-undelete)" {
  let alice = @container.Document::new("alice")
  let block = alice.create_node(parent=@container.root_id)
  alice.insert_text(block, 0, "x")
  let sync = alice.export_sync_message()
  let bob = @container.Document::new("bob")
  let _ = bob.apply_remote_sync_message(sync)
  inspect(bob.get_text(block), content="x")
  let x_lv = find_insert_lv(alice, "x")
  let delete_op : @container.BlockTextOp = {
    block,
    op: @container.Delete({ target: x_lv, timestamp: 5, agent: "alice" }),
  }
  let undelete_op : @container.BlockTextOp = {
    block,
    op: @container.Undelete({ target: x_lv, timestamp: 10, agent: "bob" }),
  }
  // Alice receives delete first, then undelete (her own ops echoed from wire).
  alice.apply_remote_text_op(delete_op)
  alice.apply_remote_text_op(undelete_op)
  inspect(alice.get_text(block), content="x")
}

///|
test "document: Undelete converges across orderings (undelete-then-delete)" {
  let alice = @container.Document::new("alice")
  let block = alice.create_node(parent=@container.root_id)
  alice.insert_text(block, 0, "x")
  let sync = alice.export_sync_message()
  let bob = @container.Document::new("bob")
  let _ = bob.apply_remote_sync_message(sync)
  let x_lv = find_insert_lv(alice, "x")
  let delete_op : @container.BlockTextOp = {
    block,
    op: @container.Delete({ target: x_lv, timestamp: 5, agent: "alice" }),
  }
  let undelete_op : @container.BlockTextOp = {
    block,
    op: @container.Undelete({ target: x_lv, timestamp: 10, agent: "bob" }),
  }
  // Bob receives undelete first, then delete. LWW (ts 10 > 5) keeps item visible.
  bob.apply_remote_text_op(undelete_op)
  bob.apply_remote_text_op(delete_op)
  inspect(bob.get_text(block), content="x")
}

///|
/// Task 1.7 — same-timestamp tie-break: Undelete wins (add-wins).
test "document: Undelete wins tie-break against Delete at equal timestamp" {
  let alice = @container.Document::new("alice")
  let block = alice.create_node(parent=@container.root_id)
  alice.insert_text(block, 0, "x")
  let sync = alice.export_sync_message()
  let bob = @container.Document::new("bob")
  let _ = bob.apply_remote_sync_message(sync)
  let x_lv = find_insert_lv(alice, "x")
  let delete_op : @container.BlockTextOp = {
    block,
    op: @container.Delete({ target: x_lv, timestamp: 7, agent: "alice" }),
  }
  let undelete_op : @container.BlockTextOp = {
    block,
    op: @container.Undelete({ target: x_lv, timestamp: 7, agent: "beta" }),
  }
  // Order A: delete first, then undelete at same ts — Undelete wins (add-wins).
  alice.apply_remote_text_op(delete_op)
  alice.apply_remote_text_op(undelete_op)
  inspect(alice.get_text(block), content="x")
  // Order B: undelete first, then delete at same ts — Undelete still wins.
  bob.apply_remote_text_op(undelete_op)
  bob.apply_remote_text_op(delete_op)
  inspect(bob.get_text(block), content="x")
}
