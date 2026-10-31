///|
/// Isolate first derivation from CRDT setup and the cached subsequent read.
fn bench_change_set(b : @bench.T, payload : Int, count : Int) -> Unit {
  let edits : Array[Utf16Edit] = [
    { start: 0, end: 0, text: "a".repeat(payload), },
  ]
  for i in 0..<count {
    edits.push({ start: payload + i, end: payload + i, text: "x", })
  }
  let version = Version::empty()
  b.bench(() => {
    let update : TextUpdate = {
      before: version,
      after: version,
      before_len: 0,
      origin: Local(None),
      sync_report: None,
      changes: edits,
      composed: None,
    }
    b.keep(update.change_set())
  })
}

///|
/// Produce the update through the real API; exclude setup and mutation from
/// the timed derivation, clearing only its lazy cache between samples.
fn bench_actual_change_set(b : @bench.T, count : Int, remote : Bool) -> Unit {
  let editor = try! Editor::new("bench-writer")
  guard editor.edit(editor.version(), {
      start: 0,
      end: 0,
      text: "a".repeat(2000),
    })
    is Applied(_) else {
    abort("seed failed")
  }
  let peer = try! Editor::new("bench-reader")
  guard peer.receive(try! editor.export_since(Version::empty())) is Applied(_) else {
    abort("seed receive failed")
  }
  let base = editor.version()
  let parts : Array[ChangeSection] = []
  for _ in 0..<count {
    parts.push(Replace(1, "x"))
    parts.push(Keep(2000 / count - 1))
  }
  let input = try! ChangeSet::new(parts[:])
  guard editor.edit_many(base, input) is Applied(applied) else {
    abort("edit_many failed")
  }
  let update = if remote {
    guard peer.receive(try! editor.export_since(base)) is Applied(received) else {
      abort("receive failed")
    }
    received
  } else {
    applied
  }
  assert_eq(update.change_set(), input) catch {
    _ => abort("incorrect derived changes")
  }
  println(
    "actual count=\{count} remote=\{remote} edits=\{update.edits().length()}",
  )
  b.bench(() => {
    update.composed = None
    b.keep(update.change_set())
  })
}

///|
test "actual edit_many: one replacement derivation" (b : @bench.T) {
  bench_actual_change_set(b, 1, false)
}

///|
test "actual edit_many: four replacements derivation" (b : @bench.T) {
  bench_actual_change_set(b, 4, false)
}

///|
test "actual edit_many: 1000 replacements derivation" (b : @bench.T) {
  bench_actual_change_set(b, 1000, false)
}

///|
test "actual receive: 1000 replacements derivation" (b : @bench.T) {
  bench_actual_change_set(b, 1000, true)
}

///|
test "change_set first derivation: 1Mi UTF16 units then 1000 inserts" (
  b : @bench.T,
) {
  bench_change_set(b, 1048576, 1000)
}

///|
test "change_set first derivation: 1000 inserts" (b : @bench.T) {
  bench_change_set(b, 0, 1000)
}

///|
test "change_set first derivation: 1000 disjoint descending replacements" (
  b : @bench.T,
) {
  let edits : Array[Utf16Edit] = []
  for i = 999; i >= 0; i = i - 1 {
    edits.push({ start: i * 2, end: i * 2 + 1, text: "x", })
  }
  let version = Version::empty()
  b.bench(() => {
    let update : TextUpdate = {
      before: version,
      after: version,
      before_len: 2000,
      origin: Local(None),
      sync_report: None,
      changes: edits,
      composed: None,
    }
    b.keep(update.change_set())
  })
}
