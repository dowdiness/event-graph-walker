///| Convergence and concurrency coverage for container undo.
///
/// Phase 4 of the undo-grouping plan. These tests exercise undo against real
/// `apply_remote_sync_message` flows: concurrent peer activity, Undelete LWW
/// corner cases, pending-queue interaction, property undo, and the rule that
/// remote ops never land on the undo stack.

// ---------------------------------------------------------------------------
// Task 4.1 — undo does not clobber peer edits
// ---------------------------------------------------------------------------

///|
test "undo convergence: local undo preserves concurrent remote edits" {
  let alice = @container.Document::new("alice")
  let block = alice.create_node(parent=@container.root_id)
  alice.insert_text(block, 0, "hello")
  let bob = @container.Document::new("bob")
  let r1 = bob.apply_remote_sync_message(alice.export_sync_message())
  inspect(r1.pending_ops, content="0")
  inspect(bob.get_text(block), content="hello")
  bob.insert_text(block, 5, "world")
  let r2 = alice.apply_remote_sync_message(bob.export_sync_message())
  inspect(r2.pending_ops, content="0")
  inspect(alice.get_text(block), content="helloworld")
  let undone = alice.undo()
  inspect(undone, content="true")
  inspect(alice.get_text(block), content="world")
  let r3 = bob.apply_remote_sync_message(alice.export_sync_message())
  inspect(r3.pending_ops, content="0")
  inspect(bob.get_text(block), content="world")
  inspect(alice.get_text(block), content="world")
}

// ---------------------------------------------------------------------------
// Task 4.2 — undo of delete_node preserves concurrent peer text
// ---------------------------------------------------------------------------

///|
test "undo convergence: delete_node/undo preserves concurrent peer text" {
  let alice = @container.Document::new("alice")
  let x = alice.create_node(parent=@container.root_id)
  alice.insert_text(x, 0, "abc")
  let bob = @container.Document::new("bob")
  let _ = bob.apply_remote_sync_message(alice.export_sync_message())
  inspect(bob.get_text(x), content="abc")
  // Concurrent local work on both sides before sync.
  alice.delete_node(x)
  bob.insert_text(x, 1, "Z")
  inspect(alice.is_alive(x), content="false")
  inspect(bob.get_text(x), content="aZbc")
  // Swap sync messages (each applies the other's full history; dedupe handles
  // their own already-seen ops).
  let r_a = alice.apply_remote_sync_message(bob.export_sync_message())
  let r_b = bob.apply_remote_sync_message(alice.export_sync_message())
  inspect(r_a.pending_ops, content="0")
  inspect(r_b.pending_ops, content="0")
  // Alice now has X trashed but "aZbc" in X's fugue tree.
  inspect(alice.is_alive(x), content="false")
  // Alice undoes the delete — restores X to root.
  let undone = alice.undo()
  inspect(undone, content="true")
  inspect(alice.is_alive(x), content="true")
  inspect(alice.get_text(x), content="aZbc")
  // Sync alice's undo-inverse move to bob.
  let r_final = bob.apply_remote_sync_message(alice.export_sync_message())
  inspect(r_final.pending_ops, content="0")
  inspect(bob.is_alive(x), content="true")
  inspect(bob.get_text(x), content="aZbc")
}

// ---------------------------------------------------------------------------
// Task 4.3 — concurrent moves with undo must converge
// ---------------------------------------------------------------------------

///|
/// Helper: snapshot the tree shape as a stable string for equality comparison.
/// Since children() returns ids sorted by fractional index, and we key by
/// node-id, peers that converge will produce identical snapshots.
fn tree_shape(doc : @container.Document) -> String {
  let roots = doc.children(@container.root_id)
  let mut s = "root:["
  for i, id in roots {
    if i > 0 {
      s = s + ","
    }
    s = s + @container.tree_node_id_key(id)
    let kids = doc.children(id)
    if kids.length() > 0 {
      s = s + "{"
      for j, k in kids {
        if j > 0 {
          s = s + ","
        }
        s = s + @container.tree_node_id_key(k)
      }
      s = s + "}"
    }
  }
  s + "]"
}

///|
test "undo convergence: concurrent moves + undo converge on both peers" {
  let alice = @container.Document::new("alice")
  let x = alice.create_node(parent=@container.root_id)
  let p1 = alice.create_node(parent=@container.root_id)
  let p2 = alice.create_node(parent=@container.root_id)
  let bob = @container.Document::new("bob")
  let _ = bob.apply_remote_sync_message(alice.export_sync_message())
  // Concurrent moves of X to different parents.
  alice.move_node(target=x, new_parent=p1)
  bob.move_node(target=x, new_parent=p2)
  // Swap sync messages and let LWW resolve the conflict.
  let _ = alice.apply_remote_sync_message(bob.export_sync_message())
  let _ = bob.apply_remote_sync_message(alice.export_sync_message())
  // Whichever parent wins, both peers agree.
  inspect(tree_shape(alice) == tree_shape(bob), content="true")
  // Alice undoes her local move. The inverse-move must also converge.
  let _ = alice.undo()
  let _ = bob.apply_remote_sync_message(alice.export_sync_message())
  let _ = alice.apply_remote_sync_message(bob.export_sync_message())
  inspect(tree_shape(alice) == tree_shape(bob), content="true")
  // Sanity: x is placed somewhere in the tree on both.
  inspect(alice.is_alive(x), content="true")
  inspect(bob.is_alive(x), content="true")
}

// ---------------------------------------------------------------------------
// Task 4.4 — later Delete beats earlier Undelete via natural flow
// ---------------------------------------------------------------------------

///|
test "undo convergence: fresh remote Delete beats prior local Undelete" {
  let alice = @container.Document::new("alice")
  let block = alice.create_node(parent=@container.root_id)
  alice.insert_text(block, 0, "x")
  let bob = @container.Document::new("bob")
  let _ = bob.apply_remote_sync_message(alice.export_sync_message())
  // Alice deletes then undoes. Undelete allocated at the current max ts.
  alice.delete_text(block, 0)
  let _ = alice.undo()
  inspect(alice.get_text(block), content="x")
  // Bob receives alice's insert + delete + undelete. LWW on bob's side: the
  // undelete has the highest ts so "x" is visible on bob too.
  let _ = bob.apply_remote_sync_message(alice.export_sync_message())
  inspect(bob.get_text(block), content="x")
  // Bob now locally deletes "x". His lamport_clock is >= alice's undelete ts,
  // so his delete allocates a strictly higher ts and wins LWW.
  bob.delete_text(block, 0)
  inspect(bob.get_text(block), content="")
  // Sync back to alice: her Undelete loses, "x" ends deleted on both.
  let r = alice.apply_remote_sync_message(bob.export_sync_message())
  inspect(r.pending_ops, content="0")
  inspect(alice.get_text(block), content="")
  inspect(bob.get_text(block), content="")
}

// ---------------------------------------------------------------------------
// Task 4.5 — tie-break add-wins (orchestrated via direct remote-op synthesis)
// ---------------------------------------------------------------------------

///|
test "undo convergence: same-ts Undelete beats Delete (add-wins)" {
  let alice = @container.Document::new("alice")
  let block = alice.create_node(parent=@container.root_id)
  alice.insert_text(block, 0, "x")
  // Recover the LV of "x" from the text-op log.
  let x_lv = {
    let mut lv = -1
    for op in alice.export_text_ops() {
      match op.op {
        @container.Insert(ins) => if ins.content == "x" { lv = ins.id }
        _ => ()
      }
    }
    lv
  }
  let bob = @container.Document::new("bob")
  let _ = bob.apply_remote_sync_message(alice.export_sync_message())
  // Synthesize a Delete and an Undelete at the same timestamp from different
  // agents. Feeding via apply_remote_text_op exercises the same TextBlock
  // path natural emission would.
  let same_ts = 50
  let del : @container.BlockTextOp = {
    block,
    op: @container.Delete({ target: x_lv, timestamp: same_ts, agent: "carol" }),
  }
  let undel : @container.BlockTextOp = {
    block,
    op: @container.Undelete({ target: x_lv, timestamp: same_ts, agent: "dave" }),
  }
  alice.apply_remote_text_op(del)
  alice.apply_remote_text_op(undel)
  bob.apply_remote_text_op(undel)
  bob.apply_remote_text_op(del)
  // Add-wins: Undelete beats Delete on equal ts regardless of arrival order.
  inspect(alice.get_text(block), content="x")
  inspect(bob.get_text(block), content="x")
}

// ---------------------------------------------------------------------------
// Task 4.6 — pending-queue flushes across local undo
// ---------------------------------------------------------------------------

///|
test "undo convergence: pending sync queue drains around local undo" {
  let alice = @container.Document::new("alice")
  let block = alice.create_node(parent=@container.root_id)
  alice.insert_text(block, 0, "hi")
  alice.delete_node(block)
  let undone = alice.undo()
  inspect(undone, content="true")
  // Alice's full history now has: create, insert×2, move-to-trash, inverse
  // move-back. Shipping it all at once should fully converge a fresh peer.
  let bob = @container.Document::new("bob")
  let r = bob.apply_remote_sync_message(alice.export_sync_message())
  inspect(r.pending_ops, content="0")
  inspect(bob.is_alive(block), content="true")
  inspect(bob.get_text(block), content="hi")
}

// ---------------------------------------------------------------------------
// Task 4.7 — property undo: prior value + absent-key (v1 limitation)
// ---------------------------------------------------------------------------

///|
test "undo: set_property undo restores prior value" {
  let doc = @container.Document::new("alice")
  let n = doc.create_node(parent=@container.root_id)
  doc.set_property(n, "type", "paragraph")
  doc.set_property(n, "type", "heading")
  inspect(doc.get_property(n, "type"), content="Some(\"heading\")")
  let _ = doc.undo()
  inspect(doc.get_property(n, "type"), content="Some(\"paragraph\")")
}

///|
test "undo: set_property undo on absent key produces Some(\"\") (v1 limit)" {
  // Design §11: property None-vs-"" asymmetry. set_property on an absent key
  // followed by undo cannot restore None because there is no RemoveProperty
  // op in v1. We lock in the documented behavior here to catch regressions.
  let doc = @container.Document::new("alice")
  let n = doc.create_node(parent=@container.root_id)
  inspect(doc.get_property(n, "foo"), content="None")
  doc.set_property(n, "foo", "bar")
  inspect(doc.get_property(n, "foo"), content="Some(\"bar\")")
  let _ = doc.undo()
  inspect(doc.get_property(n, "foo"), content="Some(\"\")")
}

// ---------------------------------------------------------------------------
// Task 4.7b — redo converges after a concurrent remote edit
// ---------------------------------------------------------------------------

///|
test "undo convergence: redo converges after concurrent remote edits" {
  let alice = @container.Document::new("alice")
  let block = alice.create_node(parent=@container.root_id)
  alice.insert_text(block, 0, "hello")
  let bob = @container.Document::new("bob")
  let _ = bob.apply_remote_sync_message(alice.export_sync_message())
  // Alice undoes — locally "", redo stack holds the insert inverse.
  let _ = alice.undo()
  inspect(alice.get_text(block), content="")
  let _ = bob.apply_remote_sync_message(alice.export_sync_message())
  inspect(bob.get_text(block), content="")
  // Bob makes a concurrent edit against the post-undo state.
  bob.insert_text(block, 0, "world")
  // Alice redoes her original insert at a fresh higher timestamp. Because
  // redo allocates new timestamps, LWW resolves naturally on both sides.
  let _ = alice.redo()
  let _ = alice.apply_remote_sync_message(bob.export_sync_message())
  let _ = bob.apply_remote_sync_message(alice.export_sync_message())
  // Both peers converge on the same content.
  inspect(alice.get_text(block) == bob.get_text(block), content="true")
}

// ---------------------------------------------------------------------------
// Task 4.8 — remote ops never recorded
// ---------------------------------------------------------------------------

///|
test "undo: remote ops never record to the receiver's undo stack" {
  let alice = @container.Document::new("alice")
  let block = alice.create_node(parent=@container.root_id)
  alice.insert_text(block, 0, "hi")
  alice.set_property(block, "type", "paragraph")
  let bob = @container.Document::new("bob")
  let _ = bob.apply_remote_sync_message(alice.export_sync_message())
  inspect(bob.get_text(block), content="hi")
  inspect(bob.get_property(block, "type"), content="Some(\"paragraph\")")
  inspect(bob.can_undo(), content="false")
  inspect(bob.undo(), content="false")
  // State is unchanged.
  inspect(bob.get_text(block), content="hi")
  inspect(bob.get_property(block, "type"), content="Some(\"paragraph\")")
}
