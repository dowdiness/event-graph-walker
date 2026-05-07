///| Run-length encoded operation types

///|
/// Compressed content for a run of operations.
pub enum OpRunContent {
  Inserts(Array[Char]) // One char per op, O(1) index access, O(1) amortized append
  Deletes
  Undeletes
} derive(Debug, Eq)

///|
/// A compressed run of consecutive operations from the same agent.
///
/// Represents `count` operations with sequential LVs `[start_lv, start_lv + count)`
/// and sequential seq numbers `[start_seq, start_seq + count)`.
///
/// Only linear left-to-right typing compresses: each op's parent must be the
/// immediately preceding op in the run, and for inserts the origin_left must
/// chain sequentially while origin_right stays constant.
pub struct OpRun {
  start_lv : Int
  agent : String
  start_seq : Int
  content : OpRunContent
  parents : Array[RawVersion]
  origin_left : RawVersion?
  origin_right : RawVersion?
  count : Int
} derive(Debug, Eq)

///|
/// Create a single-element OpRun from an Op.
pub fn OpRun::from_op(op : Op) -> OpRun {
  let content = match op.content() {
    Insert(text) => {
      let chars : Array[Char] = []
      for ch in text {
        chars.push(ch)
      }
      Inserts(chars)
    }
    Delete => Deletes
    Undelete => Undeletes
  }
  {
    start_lv: op.lv(),
    agent: op.agent(),
    start_seq: op.seq(),
    content,
    parents: op.parents(),
    origin_left: op.origin_left(),
    origin_right: op.origin_right(),
    count: 1,
  }
}

///|
/// Decompress a single Op at the given offset within this run.
///
/// `offset` must be in `[0, self.count)`. Returns None if out of bounds.
pub fn OpRun::decompress(self : OpRun, offset : Int) -> Op? {
  if offset < 0 || offset >= self.count {
    return None
  }
  let lv = self.start_lv + offset
  let seq = self.start_seq + offset
  let parents = if offset == 0 {
    self.parents.copy()
  } else {
    [RawVersion::new(self.agent, self.start_seq + offset - 1)]
  }
  let origin_left = if offset == 0 {
    self.origin_left
  } else {
    Some(RawVersion::new(self.agent, self.start_seq + offset - 1))
  }
  let origin_right = self.origin_right
  let content = match self.content {
    Inserts(chars) => Insert("\{chars[offset]}")
    Deletes => Delete
    Undeletes => Undelete
  }
  Some(
    Op::new_from_parts(
      lv~,
      parents~,
      agent=self.agent,
      seq~,
      content~,
      origin_left~,
      origin_right~,
    ),
  )
}

///|
/// Decompress all Ops in this run into the given array.
pub fn OpRun::decompress_into(self : OpRun, result : Array[Op]) -> Unit {
  for offset = 0; offset < self.count; offset = offset + 1 {
    match self.decompress(offset) {
      Some(op) => result.push(op)
      None => ()
    }
  }
}

///|
/// Two OpRuns can merge when they represent a contiguous linear typing run.
pub impl @rle.Mergeable for OpRun with can_merge(a : OpRun, b : OpRun) -> Bool {
  if a.agent != b.agent {
    return false
  }
  if a.start_seq + a.count != b.start_seq {
    return false
  }
  if a.start_lv + a.count != b.start_lv {
    return false
  }
  let expected_parent = RawVersion::new(a.agent, a.start_seq + a.count - 1)
  if b.parents.length() != 1 || b.parents[0] != expected_parent {
    return false
  }
  match (a.content, b.content) {
    (Inserts(_), Inserts(_)) => {
      let expected_origin_left = Some(
        RawVersion::new(a.agent, a.start_seq + a.count - 1),
      )
      if b.origin_left != expected_origin_left {
        return false
      }
      if a.origin_right != b.origin_right {
        return false
      }
      true
    }
    (Deletes, Deletes) => {
      // Delete origin_left is the target item being deleted — only merge
      // when targets chain sequentially (consecutive item deletions).
      let expected_origin_left = Some(
        RawVersion::new(a.agent, a.start_seq + a.count - 1),
      )
      b.origin_left == expected_origin_left
    }
    (Undeletes, Undeletes) => {
      let expected_origin_left = Some(
        RawVersion::new(a.agent, a.start_seq + a.count - 1),
      )
      b.origin_left == expected_origin_left
    }
    _ => false
  }
}

///|
pub impl @rle.Mergeable for OpRun with merge(a : OpRun, b : OpRun) -> OpRun {
  let content = match (a.content, b.content) {
    (Inserts(chars_a), Inserts(chars_b)) => {
      // Mutate a's array in place (a is consumed by merge)
      for ch in chars_b {
        chars_a.push(ch)
      }
      Inserts(chars_a)
    }
    (Deletes, Deletes) => Deletes
    (Undeletes, Undeletes) => Undeletes
    _ => a.content
  }
  {
    start_lv: a.start_lv,
    agent: a.agent,
    start_seq: a.start_seq,
    content,
    parents: a.parents,
    origin_left: a.origin_left,
    origin_right: a.origin_right,
    count: a.count + b.count,
  }
}

///|
pub impl @rle.HasLength for OpRun with length(self : OpRun) -> Int {
  self.count
}

///|
pub impl @rle.Spanning for OpRun with span(self : OpRun) -> Int {
  self.count
}

///|
pub impl @rle.Spanning for OpRun with logical_length(self : OpRun) -> Int {
  self.count
}
