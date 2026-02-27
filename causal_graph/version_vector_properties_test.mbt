// Property-based tests for VersionVector using QuickCheck
//
// These tests verify fundamental algebraic properties of version vectors
// using Arbitrary and Shrink traits for automatic test generation and minimization.

///|
/// Property: Reflexivity - a version vector is always <= itself
fn prop_reflexivity(vv : VersionVector) -> Bool {
  vv <= vv
}

///|
test "property: version vector reflexivity (a <= a)" {
  @qc.quick_check_fn(prop_reflexivity)
}

///|
/// Property: Transitivity - if a <= b and b <= c, then a <= c
fn prop_transitivity(
  vvs : (VersionVector, VersionVector, VersionVector),
) -> Bool {
  let (vv_a, vv_b, vv_c) = vvs
  // Only check transitivity when the premise holds
  if vv_a <= vv_b && vv_b <= vv_c {
    vv_a <= vv_c
  } else {
    true // Premise doesn't hold, so property is vacuously true
  }
}

///|
test "property: version vector transitivity" {
  @qc.quick_check_fn(prop_transitivity)
}

///|
/// Property: Antisymmetry - if a <= b and b <= a, then a == b
fn prop_antisymmetry(pair : (VersionVector, VersionVector)) -> Bool {
  let (vv_a, vv_b) = pair
  if vv_a <= vv_b && vv_b <= vv_a {
    vv_a == vv_b
  } else {
    true
  }
}

///|
test "property: version vector antisymmetry" {
  @qc.quick_check_fn(prop_antisymmetry)
}

///|
/// Property: Merge commutativity - merge(a, b) == merge(b, a)
fn prop_merge_commutative(pair : (VersionVector, VersionVector)) -> Bool {
  let (vv_a, vv_b) = pair
  let merged_ab = vv_a.merge(vv_b)
  let merged_ba = vv_b.merge(vv_a)
  merged_ab == merged_ba
}

///|
test "property: merge is commutative" {
  @qc.quick_check_fn(prop_merge_commutative)
}

///|
/// Property: Merge idempotence - merge(a, a) == a
fn prop_merge_idempotent(vv : VersionVector) -> Bool {
  let merged = vv.merge(vv)
  merged == vv
}

///|
test "property: merge is idempotent" {
  @qc.quick_check_fn(prop_merge_idempotent)
}

///|
/// Property: Merge associativity - merge(merge(a, b), c) == merge(a, merge(b, c))
fn prop_merge_associative(
  triple : (VersionVector, VersionVector, VersionVector),
) -> Bool {
  let (vv_a, vv_b, vv_c) = triple
  let merged_abc = vv_a.merge(vv_b).merge(vv_c)
  let merged_bca = vv_a.merge(vv_b.merge(vv_c))
  merged_abc == merged_bca
}

///|
test "property: merge is associative" {
  @qc.quick_check_fn(prop_merge_associative)
}

///|
/// Property: Merge increases or maintains version numbers
fn prop_merge_preserves(pair : (VersionVector, VersionVector)) -> Bool {
  let (vv_a, vv_b) = pair
  let merged = vv_a.merge(vv_b)
  // Merged version should be >= both inputs
  vv_a <= merged && vv_b <= merged
}

///|
test "property: merge preserves or increases versions" {
  @qc.quick_check_fn(prop_merge_preserves)
}

///|
/// Property: Concurrent symmetry - concurrent(a, b) == concurrent(b, a)
fn prop_concurrent_symmetric(pair : (VersionVector, VersionVector)) -> Bool {
  let (vv_a, vv_b) = pair
  vv_a.concurrent(vv_b) == vv_b.concurrent(vv_a)
}

///|
test "property: concurrent is symmetric" {
  @qc.quick_check_fn(prop_concurrent_symmetric)
}

///|
/// Property: If not concurrent, one must be <= the other
fn prop_total_order_or_concurrent(
  pair : (VersionVector, VersionVector),
) -> Bool {
  let (vv_a, vv_b) = pair
  if not(vv_a.concurrent(vv_b)) {
    // One must be <= the other
    vv_a <= vv_b || vv_b <= vv_a
  } else {
    true
  }
}

///|
test "property: total order or concurrent" {
  @qc.quick_check_fn(prop_total_order_or_concurrent)
}

///|
/// Property: Empty version vector is <= any version vector
fn prop_empty_is_minimal(vv : VersionVector) -> Bool {
  let empty = VersionVector::new()
  empty <= vv
}

///|
test "property: empty is minimal" {
  @qc.quick_check_fn(prop_empty_is_minimal)
}

///|
/// Property: Set with larger value makes version vector larger
fn prop_set_increases(vv : VersionVector) -> Bool {
  // Pick first agent if any, otherwise use a new agent
  let agents = vv.agents()
  let agent = if agents.length() > 0 { agents[0] } else { "test" }
  let current_seq = match vv.0.get(agent) {
    Some(seq) => seq
    None => 0
  }
  let vv2 = vv.set(agent, current_seq + 5)
  // vv should be <= vv2 after increasing sequence
  vv <= vv2
}

///|
test "property: set with larger value increases version" {
  @qc.quick_check_fn(prop_set_increases)
}

///|
/// Property: Includes is consistent with <=
fn prop_includes_consistent(pair : (VersionVector, VersionVector)) -> Bool {
  let (vv_a, vv_b) = pair
  // If vv_a <= vv_b, then all versions in vv_a should be included in vv_b
  if vv_a <= vv_b {
    let mut all_included = true
    vv_a
    .agents()
    .each(fn(agent) {
      match vv_a.0.get(agent) {
        Some(seq) => if not(vv_b.includes(agent, seq)) { all_included = false }
        None => ()
      }
    })
    all_included
  } else {
    true
  }
}

///|
test "property: includes consistent with comparison" {
  @qc.quick_check_fn(prop_includes_consistent)
}

///|
/// Property: length equals number of agents
fn prop_length_equals_agents(vv : VersionVector) -> Bool {
  vv.0.length() == vv.agents().length()
}

///|
test "property: length equals agent count" {
  @qc.quick_check_fn(prop_length_equals_agents)
}

///|
/// Property: Empty version vector has length 0
fn prop_empty_length_zero(_unit : Unit) -> Bool {
  let vv = VersionVector::new()
  vv.0.is_empty() && vv.0.length() == 0
}

///|
test "property: empty has length zero" {
  @qc.quick_check_fn(prop_empty_length_zero)
}

///|
/// Property: Equality is symmetric
fn prop_equality_symmetric(pair : (VersionVector, VersionVector)) -> Bool {
  let (vv_a, vv_b) = pair
  (vv_a == vv_b) == (vv_b == vv_a)
}

///|
test "property: equality is symmetric" {
  @qc.quick_check_fn(prop_equality_symmetric)
}

///|
/// Property: Equality is transitive
fn prop_equality_transitive(
  triple : (VersionVector, VersionVector, VersionVector),
) -> Bool {
  let (vv_a, vv_b, vv_c) = triple
  if vv_a == vv_b && vv_b == vv_c {
    vv_a == vv_c
  } else {
    true
  }
}

///|
test "property: equality is transitive" {
  @qc.quick_check_fn(prop_equality_transitive)
}

///|
/// Property: Agents returns all agent IDs correctly
fn prop_agents_correct(vv : VersionVector) -> Bool {
  let agents = vv.agents()
  // Every agent in agents() should have a value in the version vector
  let mut all_have_values = true
  agents.each(fn(agent) {
    match vv.0.get(agent) {
      Some(_) => ()
      None => all_have_values = false
    }
  })
  all_have_values
}

///|
test "property: agents returns all agent IDs" {
  @qc.quick_check_fn(prop_agents_correct)
}

///|
/// Property: merge is the least upper bound (LUB / join)
///
/// merge(a, b) is not just *an* upper bound — it is the *smallest* one.
/// For any c that is an upper bound of both a and b, merge(a, b) <= c.
/// Together with prop_merge_preserves, this makes merge a semilattice join.
fn prop_merge_is_lub(
  triple : (VersionVector, VersionVector, VersionVector),
) -> Bool {
  let (vv_a, vv_b, vv_c) = triple
  if vv_a <= vv_c && vv_b <= vv_c {
    vv_a.merge(vv_b) <= vv_c
  } else {
    true // premise doesn't hold; vacuously true
  }
}

///|
test "property: merge is least upper bound" {
  @qc.quick_check_fn(prop_merge_is_lub)
}

///|
/// Property: empty is the identity element for merge
///
/// Merging with the empty version vector is a no-op in both directions.
fn prop_merge_empty_identity(vv : VersionVector) -> Bool {
  let empty = VersionVector::new()
  vv.merge(empty) == vv && empty.merge(vv) == vv
}

///|
test "property: merge with empty is identity" {
  @qc.quick_check_fn(prop_merge_empty_identity)
}

///|
/// Property: merge is monotone in both arguments
///
/// If a <= b, then for any c, merge(a, c) <= merge(b, c).
/// This ensures that learning more (advancing a to b) never makes the merge smaller.
fn prop_merge_monotone(triple : (VersionVector, VersionVector, VersionVector)) -> Bool {
  let (vv_a, vv_b, vv_c) = triple
  if vv_a <= vv_b {
    vv_a.merge(vv_c) <= vv_b.merge(vv_c)
  } else {
    true
  }
}

///|
test "property: merge is monotone in its arguments" {
  @qc.quick_check_fn(prop_merge_monotone)
}

///|
/// Property: concurrent is irreflexive
///
/// A version vector is never concurrent with itself.
/// (By definition: concurrent(a, a) would require !(a <= a), but a <= a always holds.)
fn prop_concurrent_irreflexive(vv : VersionVector) -> Bool {
  not(vv.concurrent(vv))
}

///|
test "property: concurrent is irreflexive" {
  @qc.quick_check_fn(prop_concurrent_irreflexive)
}

///|
/// Property: includes is downward-closed in seq
///
/// If a version vector includes (agent, seq), it also includes (agent, seq')
/// for any seq' <= seq. Knowing "up to seq" implies knowing "up to seq-1, seq-2, ...".
fn prop_includes_downward_closed(vv : VersionVector) -> Bool {
  let agents = vv.agents()
  if agents.is_empty() {
    return true
  }
  let agent = agents[0]
  match vv.0.get(agent) {
    Some(max_seq) => {
      // includes(max_seq) is true; includes(0..max_seq) must all be true
      let mut ok = true
      for s = 0; s <= max_seq && ok; s = s + 1 {
        if not(vv.includes(agent, s)) {
          ok = false
        }
      }
      ok
    }
    None => true
  }
}

///|
test "property: includes is downward-closed in seq" {
  @qc.quick_check_fn(prop_includes_downward_closed)
}

///|
/// Property: increment only changes the target agent
///
/// After vv.increment(agent), every other agent retains its original seq,
/// and the target agent's seq increases by exactly 1 (or becomes 0 if new).
fn prop_increment_target_only(vv : VersionVector) -> Bool {
  let target = "alice" // always present in generated VVs or may be absent
  let before = vv.0.get(target)
  let vv2 = vv.increment(target)
  let after = vv2.0.get(target)

  // Target agent changes correctly
  let target_ok = match (before, after) {
    (Some(n), Some(m)) => m == n + 1
    (None, Some(0)) => true
    _ => false
  }
  // All other agents are unchanged
  let others_ok = vv.agents().iter().all(fn(agent) {
    if agent == target {
      true
    } else {
      vv.0.get(agent) == vv2.0.get(agent)
    }
  })
  target_ok && others_ok
}

///|
test "property: increment only changes the target agent" {
  @qc.quick_check_fn(prop_increment_target_only)
}
