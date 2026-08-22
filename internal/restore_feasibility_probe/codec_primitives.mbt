///|
/// Length-prefix a byte string with the shared minimal unsigned LEB128 codec.
fn lp_bytes(value : Bytes) -> Bytes raise R0CodecError {
  let buffer = Buffer()
  write_lp_bytes(buffer, value)
  buffer.to_bytes()
}

///|
/// Length-prefix strict, preflight-validated UTF-8 bytes.
fn lp_utf8(value : String) -> Bytes raise R0CodecError {
  let buffer = Buffer()
  write_lp_utf8(buffer, value)
  buffer.to_bytes()
}

///|
/// Encode a domain-separation tag using the shared UTF-8 framing.
fn domain(value : String) -> Bytes raise R0CodecError {
  let buffer = Buffer()
  write_domain(buffer, value)
  buffer.to_bytes()
}

///|
/// Encode the canonical internal-core RawVersion identity.
fn encode_raw_version(raw : @core.RawVersion) -> Bytes raise R0CodecError {
  let identity = RawIdentity(agent=raw.agent, sequence=raw.seq)
  encode_raw_identity(identity)
}

///|
/// SHA-256 rendered as lowercase hexadecimal.
fn sha256_hex(value : Bytes) -> String {
  bytes_hex(sha256(value))
}
