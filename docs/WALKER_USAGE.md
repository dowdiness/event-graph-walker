# Event Graph Walker - Usage Guide

## Core API

### Graph-Level Methods (`internal/causal_graph/walker.mbt`)

```moonbit
/// Walk from a frontier, returning RLE-compressed LVs in topological order.
/// Linear histories compress to a single run.
pub fn CausalGraph::walk_from_frontier(
  self : CausalGraph,
  frontier : Frontier,
) -> Rle[LvRange]

/// Diff two frontiers for incremental updates.
/// Returns (retreat_lvs, advance_lvs) as RLE-compressed ranges.
/// retreat_lvs are in reverse topological order (for undo).
/// advance_lvs are in topological order (for redo).
pub fn CausalGraph::diff_frontiers_lvs(
  self : CausalGraph,
  from_frontier : Frontier,
  to_frontier : Frontier,
) -> (Rle[LvRange], Rle[LvRange])

/// Raw symmetric difference (unsorted). Prefer diff_frontiers_lvs for replay.
pub fn CausalGraph::graph_diff(
  self : CausalGraph,
  from : Frontier,
  to : Frontier,
) -> (Array[Int], Array[Int])
```

### OpLog-Level Methods (`internal/oplog/walker.mbt`)

```moonbit
/// Walk and collect operations in causal order
pub fn OpLog::walk_and_collect(
  self : OpLog,
  frontier : Frontier,
) -> Array[Op]

/// Walk with filtering
pub fn OpLog::walk_filtered(
  self : OpLog,
  frontier : Frontier,
  predicate : (Op) -> Bool,
) -> Array[Op]

/// Diff frontiers and collect operations
pub fn OpLog::diff_and_collect(
  self : OpLog,
  from_frontier : Frontier,
  to_frontier : Frontier,
) -> (Array[Op], Array[Op])  // (retreat_ops, advance_ops)

/// Collect operations from RLE-compressed LV ranges
pub fn OpLog::get_ops_rle(
  self : OpLog,
  lvs : Rle[LvRange],
) -> Array[Op]
```

## Usage Examples

### Replay All Operations

```moonbit
let oplog = OpLog::new("agent-1")

// Create some operations
let _op1 = oplog.insert("h", -1, -1)
let _op2 = oplog.insert("i", 0, -1)

// Walk and collect all operations in causal order
let ops = oplog.walk_and_collect(oplog.get_frontier())

for op in ops {
  // Apply operation to reconstruct document
}
```

### Incremental Update (Fast-Forward)

```moonbit
let frontier1 = oplog.get_frontier()

// User makes more edits...
let frontier2 = oplog.get_frontier()

// Get only the NEW operations
let (retreat, advance) = oplog.diff_and_collect(frontier1, frontier2)
// retreat is empty when moving forward
// advance contains the new operations in causal order
```

### Merge via Branch

```moonbit
// Branch::checkout uses walk_and_collect internally
let branch = Branch::checkout(oplog, frontier)

// Branch::advance uses diff_and_collect internally
let updated = branch.advance(target_frontier)

// merge() uses diff_frontiers_lvs (RLE-compressed, topologically sorted)
// Raises BranchError on inconsistent input (e.g. unknown frontier).
merge(tree, oplog, current_frontier, target_frontier)
// Returns Unit raise BranchError
```

## Algorithm Details

### Topological Sort

The walker uses **Kahn's algorithm** for topological sorting:

1. Calculate in-degrees (number of dependencies) for each version
2. Start with versions that have in-degree 0
3. Process versions, decrementing in-degrees of children
4. Add newly-zero-in-degree versions to queue
5. Compress output into `Rle[LvRange]` via `from_sorted_ints`

**Determinism**: Concurrent operations (same parent, no dependencies between them) are sorted by LV to ensure deterministic ordering across replicas.

### RLE Compression

Graph traversal results are compressed using `Rle[LvRange]`:
- Linear history of 10,000 ops compresses to 1 run
- Concurrent edits produce multiple runs (one per contiguous sequence)
- `iter()` iterates runs directly; `iter_units()` expands to individual LVs

### Complexity

- **Time**: O(V + E) where V = versions, E = edges (parent relationships)
- **Space**: O(V) for visited set; compressed output is O(runs)

## References

- [Eg-walker paper](https://arxiv.org/abs/2409.14252)
- [Topological sorting (Kahn's algorithm)](https://en.wikipedia.org/wiki/Topological_sorting)
