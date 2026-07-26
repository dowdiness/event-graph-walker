///| Generated compression properties for valid local OpLog traces.

///|
enum CompressionLocalEdit {
  Append(Int)
  Delete(Int)
  Undelete(Int)
} derive(Debug)

///|
struct CompressionTrace {
  suffix : Array[CompressionLocalEdit]
} derive(Debug)

///|
struct CompressionExpectedOp {
  lv : Int
  parents : Array[@core.RawVersion]
  agent : String
  seq : Int
  content : @core.OpContent
  origin_left : @core.RawVersion?
  origin_right : @core.RawVersion?
} derive(Debug, Eq)

///|
struct CompressionReplay {
  oplog : OpLog
  expected : Array[CompressionExpectedOp]
}

///|
impl @quickcheck.Arbitrary for CompressionTrace with fn arbitrary(
  size,
  random_state,
) {
  let suffix : Array[CompressionLocalEdit] = []
  let suffix_count = size.max(0).min(8)
  for _ in 0..<suffix_count {
    let choice = random_state.split().next_positive_int() % 3
    let seed = random_state.split().next_positive_int()
    suffix.push(
      if choice == 0 {
        Append(seed)
      } else if choice == 1 {
        Delete(seed)
      } else {
        Undelete(seed)
      },
    )
  }
  { suffix, }
}

///|
impl @qc.Shrink for CompressionTrace with fn shrink(self) {
  let results : Array[CompressionTrace] = []
  let suffix_count = self.suffix.length()
  if suffix_count > 0 {
    results.push({ suffix: [] })
    let half = suffix_count / 2
    if half > 0 {
      results.push({ suffix: self.suffix[:half].to_owned() })
    }
    if suffix_count > 1 {
      results.push({ suffix: self.suffix[:suffix_count - 1].to_owned() })
    }
  }
  results.iter()
}

///|
fn CompressionTrace::edits(
  self : CompressionTrace,
) -> Array[CompressionLocalEdit] {
  let edits : Array[CompressionLocalEdit] = [
    Append(0),
    Append(1),
    Delete(0),
    Undelete(0),
  ]
  for edit in self.suffix {
    edits.push(edit)
  }
  edits
}

///|
fn CompressionTrace::operation_count(self : CompressionTrace) -> Int {
  4 + self.suffix.length()
}

///|
fn CompressionTrace::selected_lvs(self : CompressionTrace) -> Array[Int] {
  [0, 1, self.operation_count() - 1]
}

///|
fn compression_insert_text(seed : Int) -> String {
  let alphabet : Array[Char] = ['a', 'b', 'c', 'd', 'e']
  alphabet[seed % alphabet.length()].to_string()
}

///|
fn compression_snapshot(op : @core.Op) -> CompressionExpectedOp {
  {
    lv: op.lv(),
    parents: op.parents(),
    agent: op.agent(),
    seq: op.seq(),
    content: op.content(),
    origin_left: op.origin_left(),
    origin_right: op.origin_right(),
  }
}

///|
fn compression_snapshots(ops : Array[@core.Op]) -> Array[CompressionExpectedOp] {
  ops.map(compression_snapshot)
}

///|
fn CompressionTrace::replay(self : CompressionTrace) -> CompressionReplay {
  let oplog = OpLog::new("generated-local")
  let expected : Array[CompressionExpectedOp] = []
  let inserted_lvs : Array[Int] = []
  for edit in self.edits() {
    let op = match edit {
      Append(seed) => {
        let origin_left = match inserted_lvs.last() {
          Some(lv) => lv
          None => -1
        }
        try! oplog.insert(compression_insert_text(seed), origin_left, -1)
      }
      Delete(seed) => {
        let target = inserted_lvs[seed % inserted_lvs.length()]
        try! oplog.delete(target)
      }
      Undelete(seed) => {
        let target = inserted_lvs[seed % inserted_lvs.length()]
        try! oplog.undelete(target)
      }
    }
    expected.push(compression_snapshot(op))
    if op.is_insert() {
      inserted_lvs.push(op.lv())
    }
  }
  { oplog, expected }
}

///|
fn compression_decompress_runs(
  runs : Array[@core.OpRun],
) -> Array[CompressionExpectedOp]? {
  let decompressed : Array[CompressionExpectedOp] = []
  for run in runs {
    for offset in 0..<run.length() {
      match run.decompress(offset) {
        Some(op) => decompressed.push(compression_snapshot(op))
        None => return None
      }
    }
  }
  Some(decompressed)
}

///|
fn compression_trace_has_required_edits(trace : CompressionTrace) -> Bool {
  let mut inserts = 0
  let mut deletes = 0
  let mut undeletes = 0
  for edit in trace.edits() {
    match edit {
      Append(_) => inserts += 1
      Delete(_) => deletes += 1
      Undelete(_) => undeletes += 1
    }
  }
  inserts >= 2 && deletes >= 1 && undeletes >= 1
}

///|
fn prop_generated_compression_matches_model(trace : CompressionTrace) -> Bool {
  if !compression_trace_has_required_edits(trace) {
    return false
  }
  let replay = trace.replay()
  let oplog = replay.oplog
  let expected = replay.expected
  let count = trace.operation_count()
  if expected.length() != count || oplog.op_count() != count {
    return false
  }

  let all_ops = oplog.get_all_ops()
  if oplog.op_count() != all_ops.length() ||
    compression_snapshots(all_ops) != expected {
    return false
  }
  for lv in 0..<count {
    match oplog.get_op(lv) {
      Some(op) => {
        let actual = compression_snapshot(op)
        if actual != expected[lv] || actual != compression_snapshot(all_ops[lv]) {
          return false
        }
      }
      None => return false
    }
  }
  if oplog.get_op(-1) is Some(_) ||
    oplog.get_op(count) is Some(_) ||
    oplog.get_op(count + 1) is Some(_) {
    return false
  }

  match compression_decompress_runs(oplog.get_all_runs()) {
    Some(decompressed) =>
      if decompressed != expected ||
        decompressed != compression_snapshots(all_ops) {
        return false
      }
    None => return false
  }

  let selected_lvs = trace.selected_lvs()
  let selected_expected = selected_lvs.map(lv => expected[lv])
  let selected_rle : @rle.Rle[@core.LvRange] = @rle.Rle::from_sorted_ints(
    selected_lvs,
  )
  let from_lvs = compression_snapshots(oplog.get_ops(selected_lvs))
  let from_rle = compression_snapshots(oplog.get_ops_rle(selected_rle))
  from_lvs == selected_expected &&
  from_rle == selected_expected &&
  from_lvs == from_rle
}

///|
test "property generator: local compression traces are complete and non-vacuous" {
  let traces : Array[CompressionTrace] = @quickcheck.samples(32)
  assert_true(!traces.is_empty())
  let mut saw_generated_suffix = false
  for trace in traces {
    assert_true(compression_trace_has_required_edits(trace))
    let replay = trace.replay()
    let runs = replay.oplog.get_all_runs()
    assert_true(runs.length() > 1)
    assert_true(runs.length() < replay.expected.length())
    assert_true(runs[0].length() >= 2)
    let selected_lvs = trace.selected_lvs()
    assert_eq(selected_lvs.length(), 3)
    assert_eq(selected_lvs[0] + 1, selected_lvs[1])
    assert_true(selected_lvs[1] + 1 < selected_lvs[2])
    let selected_rle : @rle.Rle[@core.LvRange] = @rle.Rle::from_sorted_ints(
      selected_lvs,
    )
    assert_eq(selected_rle.length(), 2)
    assert_eq(selected_rle.span(), selected_lvs.length())
    if !trace.suffix.is_empty() {
      saw_generated_suffix = true
    }
  }
  assert_true(saw_generated_suffix)
}

///|
test "property: generated local traces preserve compressed query semantics" {
  @qc.quick_check_fn(prop_generated_compression_matches_model)
}
