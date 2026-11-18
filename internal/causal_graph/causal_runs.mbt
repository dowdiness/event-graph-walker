///|
/// A causal chain with an affine mapping from LV to external identity and rank.
priv struct CausalRun {
  start : Int32
  mut count : Int32
  agent : String
  seq : Int32
  timestamp : Int32
  parents : Array[Int32]
}

///|
/// Positive sequence keys. Every run, including a singleton, has one leaf entry.
priv enum IdentityPage {
  Leaf(Array[CausalRun])
  Branch(Array[Int32], Array[IdentityPage])
}

///|
priv struct IdentityIndex {
  mut root : IdentityPage
}

///|
fn IdentityPage::first_key(self : IdentityPage) -> Int32 {
  match self {
    Leaf(runs) => runs[0].seq
    Branch(keys, _) => keys[0]
  }
}

///|
/// Index of the last key <= sequence, or -1 before the first key.
fn floor_key(keys : Array[Int32], sequence : Int32) -> Int32 {
  let mut low = 0
  let mut high = keys.length()
  while low < high {
    let mid = low + (high - low) / 2
    if keys[mid] <= sequence {
      low = mid + 1
    } else {
      high = mid
    }
  }
  low - 1
}

///|
fn IdentityIndex::find(self : IdentityIndex, seq : Int32) -> CausalRun? {
  for page = self.root {
    match page {
      Branch(keys, children) => {
        let index = floor_key(keys, seq)
        if index < 0 {
          break None
        }
        continue children[index]
      }
      Leaf(runs) => {
        let mut low = 0
        let mut high = runs.length()
        while low < high {
          let mid = low + (high - low) / 2
          if runs[mid].seq <= seq {
            low = mid + 1
          } else {
            high = mid
          }
        }
        if low == 0 {
          break None
        }
        let run = runs[low - 1]
        break if seq - run.seq < run.count { Some(run) } else { None }
      }
    }
  }
}

///|
/// Insert a checked unique start. Split pages, never move an unbounded suffix.
fn IdentityPage::insert(self : IdentityPage, run : CausalRun) -> IdentityPage? {
  match self {
    Leaf(runs) => {
      let index = match runs.binary_search_by(r => r.seq.compare(run.seq)) {
        Err(index) => index
        Ok(_) => abort("duplicate checked identity")
      }
      runs.insert(index, run)
      if runs.length() <= 32 {
        return None
      }
      let right = runs[16:].to_owned()
      runs.truncate(16)
      Some(Leaf(right))
    }
    Branch(keys, children) => {
      let found = floor_key(keys, run.seq)
      let index = if found < 0 { 0 } else { found }
      let split = children[index].insert(run)
      keys[index] = children[index].first_key()
      if split is Some(right) {
        keys.insert(index + 1, right.first_key())
        children.insert(index + 1, right)
      }
      if children.length() <= 32 {
        return None
      }
      let right = Branch(keys[16:].to_owned(), children[16:].to_owned())
      keys.truncate(16)
      children.truncate(16)
      Some(right)
    }
  }
}

///|
fn IdentityIndex::insert(self : IdentityIndex, run : CausalRun) -> Unit {
  if self.root.insert(run) is Some(right) {
    self.root = Branch([self.root.first_key(), right.first_key()], [
      self.root,
      right,
    ])
  }
}

///|
/// Internal callers have checked LV bounds. No query state lives in the graph.
fn CausalGraph::run_index(self : CausalGraph, lv : Int32) -> Int32 {
  let mut low = 0
  let mut high = self.runs.length() - 1
  while low < high {
    let mid = low + (high - low) / 2
    if self.runs[mid].start + self.runs[mid].count <= lv {
      low = mid + 1
    } else {
      high = mid
    }
  }
  low
}

///|
fn CausalGraph::run_at(self : CausalGraph, lv : Int32) -> CausalRun {
  self.runs[self.run_index(lv)]
}

///|
/// Both live admission and checked history import append through this path.
fn CausalGraph::append_entry(
  self : CausalGraph,
  parents : Array[Int32],
  agent : String,
  seq : Int32,
  timestamp : Int32,
) -> Unit {
  let lv = self.next_lv
  if !self.runs.is_empty() {
    let last = self.runs[self.runs.length() - 1]
    if last.agent == agent &&
      seq >= last.seq &&
      seq - last.seq == last.count &&
      parents.length() == 1 &&
      parents[0] == lv - 1 &&
      timestamp == last.timestamp + last.count {
      last.count += 1
      self.next_lv += 1
      return
    }
  }
  let run = {
    start: lv,
    count: 1,
    agent,
    seq,
    timestamp,
    parents: parents.copy(),
  }
  self.runs.push(run)
  let index = match self.agent_runs.get(agent) {
    Some(index) => index
    None => {
      let index = IdentityIndex::{ root: IdentityPage::Leaf([]), }
      self.agent_runs[agent] = index
      index
    }
  }
  index.insert(run)
  self.next_lv += 1
}
