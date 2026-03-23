///| LCA Index -- Euler Tour + Sparse Table for O(1) ancestor queries.

///|
struct LcaIndex {
  euler_tour : Array[Lv]
  depth : Array[Int]
  first : Array[Int] // first[lv] = first occurrence index in euler_tour (non-root items). -1 = not seen.
  root_first : Int // First occurrence of root in euler_tour
  sparse : Array[Array[Int]]
  tour_len : Int
} derive(Show)

///|
fn log2_floor(n : Int) -> Int {
  let mut result = 0
  let mut val = n
  while val > 1 {
    val = val >> 1
    result = result + 1
  }
  result
}

///|
fn[T] LcaIndex::build(tree : FugueTree[T]) -> LcaIndex {
  let euler_tour : Array[Lv] = []
  let depth_arr : Array[Int] = []
  let first : Array[Int] = Array::make(tree.items.length(), -1)
  let mut root_first = -1

  let stack : Array[(Lv, Int, Int)] = [(root_lv, 0, -1)]
  while stack.length() > 0 {
    let (node_id, d, child_idx) = stack[stack.length() - 1]
    if child_idx == -1 {
      euler_tour.push(node_id)
      depth_arr.push(d)
      // Record first occurrence (inlined, not a closure)
      let tour_idx = euler_tour.length() - 1
      if node_id == root_lv {
        if root_first == -1 {
          root_first = tour_idx
        }
      } else if node_id.0 >= 0 &&
        node_id.0 < first.length() &&
        first[node_id.0] == -1 {
        first[node_id.0] = tour_idx
      }
      stack[stack.length() - 1] = (node_id, d, 0)
    } else {
      let child_lvs = tree.get_children_raw(node_id)
      if child_idx < child_lvs.length() {
        stack[stack.length() - 1] = (node_id, d, child_idx + 1)
        let child_lv = child_lvs[child_idx]
        stack.push((child_lv, d + 1, -1))
      } else {
        let _ = stack.pop()
        if stack.length() > 0 {
          let (parent_id, parent_d, _) = stack[stack.length() - 1]
          euler_tour.push(parent_id)
          depth_arr.push(parent_d)
        }
      }
    }
  }

  let tour_len = euler_tour.length()
  let log_n = if tour_len <= 1 { 1 } else { log2_floor(tour_len) + 1 }
  let sparse : Array[Array[Int]] = []
  let level0 : Array[Int] = Array::make(tour_len, 0)
  for i = 0; i < tour_len; i = i + 1 {
    level0[i] = i
  }
  sparse.push(level0)
  for k = 1; k < log_n; k = k + 1 {
    let prev = sparse[k - 1]
    let range = 1 << k
    let len = if tour_len >= range { tour_len - range + 1 } else { 0 }
    let level : Array[Int] = Array::make(len, 0)
    let half = range / 2
    for i = 0; i < len; i = i + 1 {
      let left = prev[i]
      let right = prev[i + half]
      level[i] = if depth_arr[left] <= depth_arr[right] { left } else { right }
    }
    sparse.push(level)
  }

  { euler_tour, depth: depth_arr, first, root_first, sparse, tour_len }
}

///|
/// Resolve an Lv to its first-occurrence index in the Euler tour.
/// Returns None if the Lv was never visited during the DFS.
fn LcaIndex::lv_to_tour_idx(self : LcaIndex, id : Lv) -> Int? {
  if id == root_lv {
    if self.root_first == -1 {
      None
    } else {
      Some(self.root_first)
    }
  } else if id.0 >= 0 && id.0 < self.first.length() {
    let idx = self.first[id.0]
    if idx == -1 {
      None
    } else {
      Some(idx)
    }
  } else {
    None
  }
}

///|
fn LcaIndex::is_ancestor(
  self : LcaIndex,
  ancestor_id : Lv,
  descendant_id : Lv,
) -> Bool {
  if ancestor_id == descendant_id {
    return true
  }
  let a_idx = match self.lv_to_tour_idx(ancestor_id) {
    Some(idx) => idx
    None => return false
  }
  let b_idx = match self.lv_to_tour_idx(descendant_id) {
    Some(idx) => idx
    None => return false
  }
  let lo = if a_idx < b_idx { a_idx } else { b_idx }
  let hi = if a_idx > b_idx { a_idx } else { b_idx }
  let lca_idx = self.rmq(lo, hi)
  self.euler_tour[lca_idx] == ancestor_id
}

///|
fn LcaIndex::rmq(self : LcaIndex, lo : Int, hi : Int) -> Int {
  if lo == hi {
    return lo
  }
  let range = hi - lo + 1
  let k = log2_floor(range)
  let left = self.sparse[k][lo]
  let right = self.sparse[k][hi - (1 << k) + 1]
  if self.depth[left] <= self.depth[right] {
    left
  } else {
    right
  }
}
