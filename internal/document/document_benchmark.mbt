// Benchmarks for position cache rebuild cost.
// This is what incremental remote op cache updates optimize.
// Run with: cd event-graph-walker && moon bench --release

///|
fn build_doc(n : Int) -> Document {
  let doc = Document::new("bench")
  if n > 0 {
    let _ = doc.insert(0, "x".repeat(n)) catch { _ => abort("unreachable") }
  }
  doc
}

// =============================================================================
// Cache rebuild cost: invalidate warm cache, then force rebuild via position query.
// This is the cost paid after every remote op in the current implementation.
// =============================================================================

///|
test "bench: cache invalidate + position query (1000 chars)" (b : @bench.T) {
  let doc = build_doc(1000)
  // Warm cache
  ignore(doc.lv_at_position(0))
  b.bench(fn() {
    doc.invalidate_cache()
    b.keep(doc.lv_at_position(500))
  })
}

///|
test "bench: cache invalidate + position query (5000 chars)" (b : @bench.T) {
  let doc = build_doc(5000)
  ignore(doc.lv_at_position(0))
  b.bench(fn() {
    doc.invalidate_cache()
    b.keep(doc.lv_at_position(2500))
  })
}

///|
test "bench: cache invalidate + position query (10000 chars)" (b : @bench.T) {
  let doc = build_doc(10000)
  ignore(doc.lv_at_position(0))
  b.bench(fn() {
    doc.invalidate_cache()
    b.keep(doc.lv_at_position(5000))
  })
}

// =============================================================================
// apply_remote + query: measures incremental cache update benefit.
// Each iteration: build bob, sync with alice, warm cache, then receive
// 10 more remote inserts with position queries between each.
// =============================================================================

///|
test "bench: 10 remote inserts + queries (1000-char doc)" (b : @bench.T) {
  b.bench(fn() {
    let alice = build_doc(1000)
    let bob = Document::new("bob")
    for op in alice.get_all_ops() {
      bob.apply_remote(op) catch {
        _ => abort("unreachable")
      }
    }
    ignore(bob.lv_at_position(0))
    // Alice types 10 more chars
    for i in 0..<10 {
      let _ = alice.insert(500 + i, "y") catch { _ => abort("unreachable") }
    }
    let ops = alice.get_all_ops()
    // Bob receives them one at a time, querying position after each
    for i in 1000..<ops.length() {
      bob.apply_remote(ops[i]) catch {
        _ => abort("remote apply failed in benchmark")
      }
      ignore(bob.lv_at_position(500))
    }
    b.keep(bob.visible_count())
  })
}

///|
test "bench: 10 remote inserts + queries (5000-char doc)" (b : @bench.T) {
  b.bench(fn() {
    let alice = build_doc(5000)
    let bob = Document::new("bob")
    for op in alice.get_all_ops() {
      bob.apply_remote(op) catch {
        _ => abort("unreachable")
      }
    }
    ignore(bob.lv_at_position(0))
    for i in 0..<10 {
      let _ = alice.insert(2500 + i, "y") catch { _ => abort("unreachable") }
    }
    let ops = alice.get_all_ops()
    for i in 5000..<ops.length() {
      bob.apply_remote(ops[i]) catch {
        _ => abort("remote apply failed in benchmark")
      }
      ignore(bob.lv_at_position(2500))
    }
    b.keep(bob.visible_count())
  })
}

// =============================================================================
// Warm cache position query: baseline cost when cache is valid.
// =============================================================================

///|
test "bench: warm cache position query (1000 chars)" (b : @bench.T) {
  let doc = build_doc(1000)
  ignore(doc.lv_at_position(0))
  b.bench(fn() { b.keep(doc.lv_at_position(500)) })
}

///|
test "bench: warm cache position query (10000 chars)" (b : @bench.T) {
  let doc = build_doc(10000)
  ignore(doc.lv_at_position(0))
  b.bench(fn() { b.keep(doc.lv_at_position(5000)) })
}
