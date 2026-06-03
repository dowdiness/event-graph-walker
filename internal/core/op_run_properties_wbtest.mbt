///| QuickCheck properties for OpRun merge/decompress laws.

///|
fn oprun_agent(seed : Int) -> String {
  if seed % 3 == 0 {
    "alice"
  } else if seed % 3 == 1 {
    "bob"
  } else {
    "carol"
  }
}

///|
fn random_insert_chars(rs : @splitmix.RandomState, count : Int) -> Array[Char] {
  let pool : Array[Char] = ['a', 'b', 'c', 'd', 'e']
  let chars : Array[Char] = []
  for _ in 0..<count {
    let idx = rs.next_uint64().to_int().abs() % pool.length()
    chars.push(pool[idx])
  }
  chars
}

///|
fn random_oprun_content(
  rs : @splitmix.RandomState,
  kind : Int,
  count : Int,
) -> OpRunContent {
  if kind == 0 {
    Inserts(random_insert_chars(rs, count))
  } else if kind == 1 {
    Deletes
  } else {
    Undeletes
  }
}

///|
fn make_op_run(
  agent : String,
  start_lv : Int,
  start_seq : Int,
  count : Int,
  kind : Int,
  parents : Array[RawVersion],
  origin_left : RawVersion?,
  origin_right : RawVersion?,
  rs : @splitmix.RandomState,
) -> OpRun {
  {
    start_lv,
    agent,
    start_seq,
    content: random_oprun_content(rs, kind, count),
    parents,
    origin_left,
    origin_right,
    count,
  }
}

///|
struct CompatibleOpRunPair {
  first : OpRun
  second : OpRun
} derive(Debug)

///|
impl @quickcheck.Arbitrary for CompatibleOpRunPair with fn arbitrary(
  _size,
  random_state,
) {
  let rs = random_state.split()
  let start_lv = rs.next_uint64().to_int().abs() % 20
  let start_seq = rs.next_uint64().to_int().abs() % 20
  let count_a = rs.next_uint64().to_int().abs() % 3 + 1
  let count_b = rs.next_uint64().to_int().abs() % 3 + 1
  let kind = rs.next_uint64().to_int().abs() % 3
  let agent = oprun_agent(rs.next_uint64().to_int().abs())

  let first_parents = if rs.next_uint64().to_int().abs() % 2 == 0 {
    [RawVersion::new("seed", 0)]
  } else {
    []
  }
  let first_origin_left = if rs.next_uint64().to_int().abs() % 2 == 0 {
    Some(RawVersion::new("seed", 0))
  } else {
    None
  }
  let shared_origin_right = if kind == 0 &&
    rs.next_uint64().to_int().abs() % 2 == 0 {
    Some(RawVersion::new("edge", 0))
  } else {
    None
  }
  let link_seq = start_seq + count_a - 1
  let chain = RawVersion::new(agent, link_seq)

  let first = make_op_run(
    agent,
    start_lv,
    start_seq,
    count_a,
    kind,
    first_parents,
    first_origin_left,
    if kind == 0 {
      shared_origin_right
    } else {
      None
    },
    rs,
  )
  let second = make_op_run(
    agent,
    start_lv + count_a,
    start_seq + count_a,
    count_b,
    kind,
    [chain],
    Some(chain),
    if kind == 0 {
      shared_origin_right
    } else {
      None
    },
    rs,
  )
  { first, second }
}

///|
struct CompatibleOpRunTriple {
  first : OpRun
  second : OpRun
  third : OpRun
} derive(Debug)

///|
impl @quickcheck.Arbitrary for CompatibleOpRunTriple with fn arbitrary(
  _size,
  random_state,
) {
  let rs = random_state.split()
  let start_lv = rs.next_uint64().to_int().abs() % 20
  let start_seq = rs.next_uint64().to_int().abs() % 20
  let count_a = rs.next_uint64().to_int().abs() % 3 + 1
  let count_b = rs.next_uint64().to_int().abs() % 3 + 1
  let count_c = rs.next_uint64().to_int().abs() % 3 + 1
  let kind = rs.next_uint64().to_int().abs() % 3
  let agent = oprun_agent(rs.next_uint64().to_int().abs())
  let shared_origin_right = if kind == 0 &&
    rs.next_uint64().to_int().abs() % 2 == 0 {
    Some(RawVersion::new("edge", 0))
  } else {
    None
  }

  let first_parents = if rs.next_uint64().to_int().abs() % 2 == 0 {
    [RawVersion::new("seed", 0)]
  } else {
    []
  }
  let link_a = RawVersion::new(agent, start_seq + count_a - 1)
  let link_b = RawVersion::new(agent, start_seq + count_a + count_b - 1)

  let first = make_op_run(
    agent,
    start_lv,
    start_seq,
    count_a,
    kind,
    first_parents,
    None,
    if kind == 0 {
      shared_origin_right
    } else {
      None
    },
    rs,
  )
  let second = make_op_run(
    agent,
    start_lv + count_a,
    start_seq + count_a,
    count_b,
    kind,
    [link_a],
    Some(link_a),
    if kind == 0 {
      shared_origin_right
    } else {
      None
    },
    rs,
  )
  let third = make_op_run(
    agent,
    start_lv + count_a + count_b,
    start_seq + count_a + count_b,
    count_c,
    kind,
    [link_b],
    Some(link_b),
    if kind == 0 {
      shared_origin_right
    } else {
      None
    },
    rs,
  )
  { first, second, third }
}

///|
struct OpRunSingle {
  run : OpRun
} derive(Debug)

///|
impl @quickcheck.Arbitrary for OpRunSingle with fn arbitrary(
  _size,
  random_state,
) {
  let rs = random_state.split()
  let start_lv = rs.next_uint64().to_int().abs() % 20
  let start_seq = rs.next_uint64().to_int().abs() % 20
  let count = rs.next_uint64().to_int().abs() % 4 + 1
  let kind = rs.next_uint64().to_int().abs() % 3
  let agent = oprun_agent(rs.next_uint64().to_int().abs())
  let prior_seq = if start_seq > 0 { start_seq - 1 } else { 0 }

  let run = make_op_run(
    agent,
    start_lv,
    start_seq,
    count,
    kind,
    if rs.next_uint64().to_int().abs() % 2 == 0 {
      [RawVersion::new("seed", prior_seq)]
    } else {
      []
    },
    if rs.next_uint64().to_int().abs() % 2 == 0 {
      Some(RawVersion::new("seed", prior_seq))
    } else {
      None
    },
    if kind == 0 && rs.next_uint64().to_int().abs() % 2 == 0 {
      Some(RawVersion::new("edge", 0))
    } else {
      None
    },
    rs,
  )
  { run, }
}

///|
fn decompress_all_ops(run : OpRun) -> Array[Op] {
  let result : Array[Op] = []
  for i in 0..<run.count {
    match run.decompress(i) {
      Some(op) => result.push(op)
      None => ()
    }
  }
  result
}

///|
fn ops_eq(a : Op, b : Op) -> Bool {
  a.lv() == b.lv() &&
  a.seq() == b.seq() &&
  a.agent() == b.agent() &&
  a.content() == b.content() &&
  a.parents() == b.parents() &&
  a.origin_left() == b.origin_left() &&
  a.origin_right() == b.origin_right()
}

///|
fn ops_array_eq(a : Array[Op], b : Array[Op]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i in 0..<a.length() {
    if !ops_eq(a[i], b[i]) {
      return false
    }
  }
  true
}

///|
fn prop_oprun_merge_two_decompress_concats(pair : CompatibleOpRunPair) -> Bool {
  if !@rle.Mergeable::can_merge(pair.first, pair.second) {
    return false
  }
  let merged = @rle.Mergeable::merge(pair.first, pair.second)
  let lhs = decompress_all_ops(pair.first)
  let rhs = decompress_all_ops(pair.second)
  for op in rhs {
    lhs.push(op)
  }
  ops_array_eq(lhs, decompress_all_ops(merged))
}

///|
test "property: merge-compatible two OpRuns preserves decompressed operations" {
  let samples : Array[CompatibleOpRunPair] = @quickcheck.samples(32)
  for sample in samples {
    inspect(prop_oprun_merge_two_decompress_concats(sample), content="true")
  }
}

///|
fn prop_oprun_merge_three_is_associative(
  triple : CompatibleOpRunTriple,
) -> Bool {
  if !@rle.Mergeable::can_merge(triple.first, triple.second) {
    return false
  }
  if !@rle.Mergeable::can_merge(triple.second, triple.third) {
    return false
  }
  let left = @rle.Mergeable::merge(
    @rle.Mergeable::merge(triple.first, triple.second),
    triple.third,
  )
  let right = @rle.Mergeable::merge(
    triple.first,
    @rle.Mergeable::merge(triple.second, triple.third),
  )
  let expected = decompress_all_ops(triple.first)
  let tail = decompress_all_ops(triple.second)
  let tail2 = decompress_all_ops(triple.third)
  for op in tail {
    expected.push(op)
  }
  for op in tail2 {
    expected.push(op)
  }
  let left_ops = decompress_all_ops(left)
  let right_ops = decompress_all_ops(right)
  ops_array_eq(left_ops, expected) && ops_array_eq(right_ops, expected)
}

///|
test "property: three-way merge associativity on compatible OpRuns" {
  let samples : Array[CompatibleOpRunTriple] = @quickcheck.samples(16)
  for sample in samples {
    inspect(prop_oprun_merge_three_is_associative(sample), content="true")
  }
}

///|
fn prop_oprun_decompress_out_of_bounds(sample : OpRunSingle) -> Bool {
  let run = sample.run
  run.decompress(-1) is None &&
  run.decompress(run.count) is None &&
  run.decompress(run.count + 1) is None
}

///|
test "property: OpRun::decompress returns None outside valid offsets" {
  let samples : Array[OpRunSingle] = @quickcheck.samples(32)
  for sample in samples {
    inspect(prop_oprun_decompress_out_of_bounds(sample), content="true")
  }
}

///|
fn prop_oprun_decompress_chain_metadata(sample : OpRunSingle) -> Bool {
  let run = sample.run
  match run.content {
    Inserts(chars) => {
      for offset in 0..<run.count {
        let op = match run.decompress(offset) {
          Some(op) => op
          None => return false
        }
        let expected_parents = if offset == 0 {
          run.parents
        } else {
          [RawVersion::new(run.agent, run.start_seq + offset - 1)]
        }
        let expected_origin_left = if offset == 0 {
          run.origin_left
        } else {
          Some(RawVersion::new(run.agent, run.start_seq + offset - 1))
        }
        let expected_text = String::from_array([chars[offset]])
        if op.lv() != run.start_lv + offset {
          return false
        }
        if op.seq() != run.start_seq + offset {
          return false
        }
        if op.content() != Insert(expected_text) {
          return false
        }
        if op.parents() != expected_parents {
          return false
        }
        if op.origin_left() != expected_origin_left {
          return false
        }
        if op.origin_right() != run.origin_right {
          return false
        }
      }
      true
    }
    Deletes => {
      for offset in 0..<run.count {
        let op = match run.decompress(offset) {
          Some(op) => op
          None => return false
        }
        let expected_parents = if offset == 0 {
          run.parents
        } else {
          [RawVersion::new(run.agent, run.start_seq + offset - 1)]
        }
        let expected_origin_left = if offset == 0 {
          run.origin_left
        } else {
          Some(RawVersion::new(run.agent, run.start_seq + offset - 1))
        }
        if op.lv() != run.start_lv + offset {
          return false
        }
        if op.seq() != run.start_seq + offset {
          return false
        }
        if op.content() != Delete {
          return false
        }
        if op.parents() != expected_parents {
          return false
        }
        if op.origin_left() != expected_origin_left {
          return false
        }
        if op.origin_right() != run.origin_right {
          return false
        }
      }
      true
    }
    Undeletes => {
      for offset in 0..<run.count {
        let op = match run.decompress(offset) {
          Some(op) => op
          None => return false
        }
        let expected_parents = if offset == 0 {
          run.parents
        } else {
          [RawVersion::new(run.agent, run.start_seq + offset - 1)]
        }
        let expected_origin_left = if offset == 0 {
          run.origin_left
        } else {
          Some(RawVersion::new(run.agent, run.start_seq + offset - 1))
        }
        if op.lv() != run.start_lv + offset {
          return false
        }
        if op.seq() != run.start_seq + offset {
          return false
        }
        if op.content() != Undelete {
          return false
        }
        if op.parents() != expected_parents {
          return false
        }
        if op.origin_left() != expected_origin_left {
          return false
        }
        if op.origin_right() != run.origin_right {
          return false
        }
      }
      true
    }
  }
}

///|
test "property: OpRun::decompress metadata chains across offsets" {
  let samples : Array[OpRunSingle] = @quickcheck.samples(16)
  for sample in samples {
    inspect(prop_oprun_decompress_chain_metadata(sample), content="true")
  }
}
