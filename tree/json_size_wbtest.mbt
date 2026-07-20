///|
test "tree JSON size counts exact UTF-8 bytes" {
  let json = "Aé文😀"
  let exact = try! @sync.Limits(max_encoded_bytes=10)
  inspect(try! tree_json_size(json, exact), content="10")
  let too_small = try! @sync.Limits(max_encoded_bytes=9)
  try tree_json_size(json, too_small) catch {
    TreeError::SyncFailed(
      @sync.Failure::LimitExceeded(
        kind=@sync.LimitKind::EncodedBytes,
        limit=9,
        actual=10
      )
    ) => ()
    _ => fail("expected exact UTF-8 encoded size")
  } noraise {
    _ => fail("10 encoded bytes must exceed a 9-byte limit")
  }
}
