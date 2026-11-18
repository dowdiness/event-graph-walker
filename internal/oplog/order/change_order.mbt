///|
/// A dependency in a later arrival slot wakes its dependent in the next scan.
pub fn dependency_ready_round(
  arrival : Int32,
  dependency_arrival : Int32,
  dependency_round : Int32,
) -> Int32 where {
  proof_require: 0 <= dependency_round && dependency_round < 2147483647,
  proof_ensure: round => {
    dependency_round <= round &&
    round <= dependency_round + 1 &&
    (
      (arrival > dependency_arrival && round == dependency_round) ||
      (arrival <= dependency_arrival && round == dependency_round + 1)
    )
  },
} {
  if arrival > dependency_arrival {
    dependency_round
  } else {
    dependency_round + 1
  }
}
