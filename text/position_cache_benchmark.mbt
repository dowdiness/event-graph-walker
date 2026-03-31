// Benchmarks to measure position cache rebuild cost on non-sequential inserts.
// Run with: cd event-graph-walker && moon bench --package text --release

///|
fn bench_insert(doc : TextState, pos : Int, text : String) -> Unit {
  doc.insert(Pos::at(pos), text) catch {
    _ => ()
  }
}

// =============================================================================
// Baseline: Sequential append (cursor fast-path, cache preserved)
// =============================================================================

///|
/// Sequential append at 1000 chars — cache stays warm, no rebuild.
test "cache - sequential append (1000 chars)" (b : @bench.T) {
  b.bench(fn() {
    let doc = TextState::new("alice")
    for i = 0; i < 1000; i = i + 1 {
      bench_insert(doc, i, "x")
    }
    b.keep(doc)
  })
}

// =============================================================================
// Non-sequential: alternating positions (cache invalidated every time)
// =============================================================================

///|
/// Alternating insert at pos 0 and end — every other insert is non-sequential,
/// forcing cache rebuild each time.
test "cache - alternating pos (1000 chars)" (b : @bench.T) {
  b.bench(fn() {
    let doc = TextState::new("alice")
    for i = 0; i < 1000; i = i + 1 {
      let pos = if i % 2 == 0 { i / 2 } else { 0 }
      bench_insert(doc, pos, "x")
    }
    b.keep(doc)
  })
}

// =============================================================================
// Realistic: type a line, jump to another position, type another line
// =============================================================================

///|
/// Type 10 chars, jump to pos 0 (FugueMax edge case: falls back to
/// invalidation since origin_left=root on non-empty doc). ~100 rebuilds.
test "cache - jump to pos 0 every 10 chars (1000 chars)" (b : @bench.T) {
  b.bench(fn() {
    let doc = TextState::new("alice")
    let mut pos = 0
    for i = 0; i < 1000; i = i + 1 {
      bench_insert(doc, pos, "x")
      if (i + 1) % 10 == 0 {
        pos = 0
      } else {
        pos = pos + 1
      }
    }
    b.keep(doc)
  })
}

///|
/// Type 10 chars, jump to middle (realistic click-then-type pattern,
/// no FugueMax edge case). Incremental cache maintained. ~100 jumps.
test "cache - jump to middle every 10 chars (1000 chars)" (b : @bench.T) {
  b.bench(fn() {
    let doc = TextState::new("alice")
    let mut pos = 0
    for i = 0; i < 1000; i = i + 1 {
      bench_insert(doc, pos, "x")
      if (i + 1) % 10 == 0 {
        pos = (i + 1) / 2
      } else {
        pos = pos + 1
      }
    }
    b.keep(doc)
  })
}

// =============================================================================
// Isolate: single non-sequential insert on a warm document
// =============================================================================

///|
/// Build a 1000-char doc, warm the cache, then measure a single
/// non-sequential insert (which forces rebuild).
test "cache - single non-seq insert on 1000-char doc" (b : @bench.T) {
  let doc = TextState::new("alice")
  for i = 0; i < 1000; i = i + 1 {
    bench_insert(doc, i, "x")
  }
  ignore(doc.text())
  b.bench(fn() {
    bench_insert(doc, 0, "y")
    b.keep(doc)
  })
}

///|
/// Same but with 5000 chars — check if cost scales linearly.
test "cache - single non-seq insert on 5000-char doc" (b : @bench.T) {
  let doc = TextState::new("alice")
  for i = 0; i < 5000; i = i + 1 {
    bench_insert(doc, i, "x")
  }
  ignore(doc.text())
  b.bench(fn() {
    bench_insert(doc, 0, "y")
    b.keep(doc)
  })
}
