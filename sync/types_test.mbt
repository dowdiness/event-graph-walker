///|
test "Limits defaults match the v0.4 contract" {
  let limits : Limits = Limits::default()
  inspect(limits.max_encoded_bytes(), content="16777216")
  inspect(limits.max_decoded_operations(), content="100000")
  inspect(limits.max_pending_operations(), content="10000")
  inspect(limits.max_parents_per_operation(), content="256")
}

///|
test "Limits accepts exact zero boundaries" {
  let limits = try! Limits::Limits(
    max_encoded_bytes=0,
    max_decoded_operations=0,
    max_pending_operations=0,
    max_parents_per_operation=0,
  )
  inspect(limits.max_encoded_bytes(), content="0")
}
