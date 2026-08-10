// PROTOTYPE — throwaway checkpoint/restore gate
//
// Question:
// Can a materialized CRDT state at a causal cut plus a small tail avoid the
// prefix replay cost observed during archive reopen?
//
// This is intentionally optimistic: the checkpoint is held in memory as a
// Branch, so capture/serialization/deserialization cost is excluded. It only
// answers whether direct materialized-state restore is worth designing. Delete
// this file after the decision is captured in the implementation issue.

///|
fn prototype_source() -> String {
  "# Startup benchmark\n\nSame final document\n"
}

///|
fn prototype_document(cycles : Int) -> Document {
  let source = prototype_source()
  let doc = Document::new("prototype-writer")
  ignore(doc.insert(0, source) catch { _ => abort("prototype insert failed") })
  for i in 0..<cycles {
    let intermediate = source + "intermediate revision " + i.to_string() + "\n"
    ignore(doc.replace_range(0, doc.visible_count(), intermediate) catch {
      _ => abort("prototype intermediate replace failed")
    })
    ignore(doc.replace_range(0, doc.visible_count(), source) catch {
      _ => abort("prototype final replace failed")
    })
  }
  doc
}

///|
fn prototype_append_cycles(
  doc : Document,
  start : Int,
  end : Int,
) -> Unit {
  let source = prototype_source()
  for i in start..<end {
    let intermediate = source + "intermediate revision " + i.to_string() + "\n"
    ignore(doc.replace_range(0, doc.visible_count(), intermediate) catch {
      _ => abort("prototype intermediate replace failed")
    })
    ignore(doc.replace_range(0, doc.visible_count(), source) catch {
      _ => abort("prototype final replace failed")
    })
  }
}

///|
test "PROTOTYPE full replay: 20-cycle history" (b : @bench.T) {
  let doc = prototype_document(20)
  let oplog = doc.oplog
  let frontier = doc.get_frontier()
  println(
    "prototype full replay: ops=" + oplog.op_count().to_string(),
  )
  b.bench(fn() {
    let branch = try! @branch.Branch::checkout(oplog, frontier)
    b.keep(branch.visible_count())
  })
}

///|
test "PROTOTYPE direct restore: 19-cycle checkpoint + 1-cycle tail" (
  b : @bench.T,
) {
  let doc = prototype_document(19)
  let base_frontier = doc.get_frontier()
  let base_branch = try! @branch.Branch::checkout(doc.oplog, base_frontier)
  prototype_append_cycles(doc, 19, 20)
  let target_frontier = doc.get_frontier()
  println(
    "prototype direct restore: base_ops=" +
      base_branch.get_version_vector().to_string() +
      ", tail_target=" + doc.oplog.op_count().to_string(),
  )
  b.bench(fn() {
    let branch = try! base_branch.advance(target_frontier)
    b.keep(branch.visible_count())
  })
}

///|
test "PROTOTYPE direct restore: 10-cycle checkpoint + 10-cycle tail" (
  b : @bench.T,
) {
  let doc = prototype_document(10)
  let base_frontier = doc.get_frontier()
  let base_branch = try! @branch.Branch::checkout(doc.oplog, base_frontier)
  prototype_append_cycles(doc, 10, 20)
  let target_frontier = doc.get_frontier()
  println(
    "prototype direct restore: 10-cycle base, target_ops=" +
      doc.oplog.op_count().to_string(),
  )
  b.bench(fn() {
    let branch = try! base_branch.advance(target_frontier)
    b.keep(branch.visible_count())
  })
}
