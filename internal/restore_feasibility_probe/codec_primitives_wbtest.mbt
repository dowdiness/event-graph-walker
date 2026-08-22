///|
/// Independent vectors for the shared R0 test codec.
test "shared codec primitive vectors" {
  assert_eq(bytes_hex(encode_uvarint(0)), "00")
  assert_eq(bytes_hex(encode_uvarint(1)), "01")
  assert_eq(bytes_hex(encode_uvarint(127)), "7f")
  assert_eq(bytes_hex(encode_uvarint(128)), "8001")
  assert_eq(bytes_hex(encode_uvarint(0x7fff_fffe)), "feffffff07")
  assert_eq(bytes_hex(lp_bytes(@utf8.encode("ab"))), "026162")
  assert_eq(bytes_hex(lp_utf8("é")), "02c3a9")
  assert_eq(bytes_hex(domain("é")), "02c3a9")
  assert_eq(
    bytes_hex(encode_raw_version(@core.RawVersion("a", 128))),
    "01618001",
  )
  assert_eq(
    sha256_hex(Bytes::new(0)),
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  )
  let negative : Result[Bytes, R0CodecError] = Ok(
    encode_raw_version(@core.RawVersion("a", -1)),
  ) catch {
    error => Err(error)
  }
  inspect(negative is Err(_), content="true")
}
