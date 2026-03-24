///| Binary lifting (jump pointers) for O(log n) incremental ancestor queries.
///  Exploits FugueTree's append-only structure: jump pointers are permanent.

///|
struct JumpAncestors {
  depth : Array[Int] // depth[lv.0], -1 = gap (non-tree LV)
  jump : Array[Array[Lv]] // jump[lv.0][k] = 2^k-th ancestor, [] = gap
} derive(Show)

///|
fn JumpAncestors::new() -> JumpAncestors {
  { depth: [], jump: [] }
}

///|
/// Register a new tree node with its parent. O(log depth).
/// Precondition: parent was already added (or is root_lv).
fn JumpAncestors::add(self : JumpAncestors, lv : Lv, parent : Lv) -> Unit {
  let idx = lv.0
  while self.depth.length() <= idx {
    self.depth.push(-1)
  }
  while self.jump.length() <= idx {
    self.jump.push([])
  }
  guard parent == root_lv || self.depth[parent.0] != -1
  self.depth[idx] = if parent == root_lv { 1 } else { self.depth[parent.0] + 1 }
  let jumps : Array[Lv] = [parent]
  while true {
    let k = jumps.length()
    let prev = jumps[k - 1]
    if prev == root_lv {
      break
    }
    if k - 1 >= self.jump[prev.0].length() {
      break
    }
    jumps.push(self.jump[prev.0][k - 1])
  }
  self.jump[idx] = jumps
}

///|
/// Check if `ancestor` is an ancestor of `descendant`. O(log depth).
/// Both must be non-root tree nodes. Caller handles root_lv and equality.
/// Returns false for absent or gap LVs.
fn JumpAncestors::is_ancestor(
  self : JumpAncestors,
  ancestor : Lv,
  descendant : Lv,
) -> Bool {
  let a = ancestor.0
  let b = descendant.0
  if a >= self.depth.length() || self.depth[a] == -1 {
    return false
  }
  if b >= self.depth.length() || self.depth[b] == -1 {
    return false
  }
  let depth_a = self.depth[a]
  let depth_b = self.depth[b]
  if depth_a > depth_b {
    return false
  }
  let mut diff = depth_b - depth_a
  let mut current = descendant
  let mut k = self.jump[current.0].length() - 1
  while diff > 0 && k >= 0 {
    if diff >= 1 << k && k < self.jump[current.0].length() {
      current = self.jump[current.0][k]
      diff = diff - (1 << k)
    }
    k = k - 1
  }
  current == ancestor
}
