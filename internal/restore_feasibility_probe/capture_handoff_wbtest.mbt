///|
test "R0 capture base64 matches RFC 4648 vectors" {
  inspect(base64_encode(Bytes::new(0)), content="")
  inspect(base64_encode(@utf8.encode("f")), content="Zg==")
  inspect(base64_encode(@utf8.encode("fo")), content="Zm8=")
  inspect(base64_encode(@utf8.encode("foo")), content="Zm9v")
  inspect(base64_encode(@utf8.encode("foobar")), content="Zm9vYmFy")
}

///|
test "R0 capture base64 round trips binary bytes" {
  let bytes = Bytes::from_array([0x00, 0x01, 0x7f, 0x80, 0xfe, 0xff])
  inspect(
    bytes_hex(try! base64_decode(base64_encode(bytes))),
    content="00017f80feff",
  )
}

///|
test "R0 capture base64 rejects non-canonical input" {
  let invalid : Result[Bytes, R0CodecError] = Ok(base64_decode("Zh==")) catch {
    error => Err(error)
  }
  inspect(invalid is Err(_), content="true")
}
