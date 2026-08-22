///|
/// Canonical test-only codec shared by Gate R0 artifacts.
suberror R0CodecError {
  InvalidValue(detail~ : String)
  MalformedEncoding(detail~ : String)
}

///|
/// Stable identity used by the R0 sidecar and fixture catalog.
struct RawIdentity {
  agent : String
  sequence : Int
} derive(Eq, Debug)

///|
fn RawIdentity::RawIdentity(agent~ : String, sequence~ : Int) -> RawIdentity {
  { agent, sequence }
}

///|
/// One canonical positional text event body.
enum CanonicalBody {
  InsertScalar(Int, String)
  DeleteScalar(Int)
  Undelete(RawIdentity)
} derive(Eq, Debug)

///|
fn validate_utf16(value : String) -> Unit raise R0CodecError {
  let mut index = 0
  while index < value.length() {
    let code = value[index].to_int()
    if code >= 0xD800 && code <= 0xDBFF {
      if index + 1 >= value.length() {
        raise R0CodecError::InvalidValue(detail="malformed UTF-16")
      }
      let trail = value[index + 1].to_int()
      if trail < 0xDC00 || trail > 0xDFFF {
        raise R0CodecError::InvalidValue(detail="malformed UTF-16")
      }
      index = index + 2
    } else if code >= 0xDC00 && code <= 0xDFFF {
      raise R0CodecError::InvalidValue(detail="malformed UTF-16")
    } else {
      index = index + 1
    }
  }
}

///|
fn strict_utf8(value : String) -> Bytes raise R0CodecError {
  validate_utf16(value)
  @utf8.encode(value)
}

///|
fn unicode_scalar_length(value : String) -> Int raise R0CodecError {
  validate_utf16(value)
  let mut count = 0
  let mut index = 0
  while index < value.length() {
    let code = value[index].to_int()
    let width = if code >= 0xD800 && code <= 0xDBFF { 2 } else { 1 }
    index = index + width
    count = count + 1
  }
  count
}

///|
fn encode_uvarint(value : Int) -> Bytes raise R0CodecError {
  if value < 0 {
    raise R0CodecError::InvalidValue(detail="negative uvarint")
  }
  let buffer = Buffer()
  let mut remaining = value
  while remaining >= 0x80 {
    buffer.write_byte(((remaining & 0x7F) | 0x80).to_byte())
    remaining = remaining >> 7
  }
  buffer.write_byte(remaining.to_byte())
  buffer.to_bytes()
}

///|
fn write_uvarint(buffer : Buffer, value : Int) -> Unit raise R0CodecError {
  buffer.write_bytes(encode_uvarint(value))
}

///|
fn write_lp_bytes(buffer : Buffer, value : Bytes) -> Unit raise R0CodecError {
  write_uvarint(buffer, value.length())
  buffer.write_bytes(value)
}

///|
fn write_lp_utf8(buffer : Buffer, value : String) -> Unit raise R0CodecError {
  write_lp_bytes(buffer, strict_utf8(value))
}

///|
fn write_domain(buffer : Buffer, value : String) -> Unit raise R0CodecError {
  write_lp_utf8(buffer, value)
}

///|
fn validate_raw_identity(identity : RawIdentity) -> Unit raise R0CodecError {
  if identity.agent.length() == 0 {
    raise R0CodecError::InvalidValue(detail="empty agent")
  }
  validate_utf16(identity.agent)
  if identity.sequence < 0 || identity.sequence > 0x7fff_fffe {
    raise R0CodecError::InvalidValue(detail="sequence outside R0 bounds")
  }
}

///|
fn write_raw_identity(
  buffer : Buffer,
  identity : RawIdentity,
) -> Unit raise R0CodecError {
  validate_raw_identity(identity)
  write_lp_utf8(buffer, identity.agent)
  write_uvarint(buffer, identity.sequence)
}

///|
fn encode_raw_identity(identity : RawIdentity) -> Bytes raise R0CodecError {
  let buffer = Buffer()
  write_raw_identity(buffer, identity)
  buffer.to_bytes()
}

///|
fn compare_utf8_bytes(left : String, right : String) -> Int {
  let left_bytes = @utf8.encode(left)
  let right_bytes = @utf8.encode(right)
  let shared = left_bytes.length().min(right_bytes.length())
  for index in 0..<shared {
    let comparison = left_bytes[index]
      .to_int()
      .compare(right_bytes[index].to_int())
    if comparison != 0 {
      return comparison
    }
  }
  left_bytes.length().compare(right_bytes.length())
}

///|
fn compare_raw_identity(left : RawIdentity, right : RawIdentity) -> Int {
  match compare_utf8_bytes(left.agent, right.agent) {
    0 => left.sequence.compare(right.sequence)
    other => other
  }
}

///|
fn encode_canonical_body(body : CanonicalBody) -> Bytes raise R0CodecError {
  let buffer = Buffer()
  match body {
    InsertScalar(position, scalar) => {
      if position < 0 || position >= 0x7fff_ffff {
        raise R0CodecError::InvalidValue(
          detail="insert position outside R0 bounds",
        )
      }
      if unicode_scalar_length(scalar) != 1 {
        raise R0CodecError::InvalidValue(
          detail="insert body must be one scalar",
        )
      }
      buffer.write_byte(b'\x01')
      buffer.write_byte(b'\x01')
      write_uvarint(buffer, position)
      write_lp_bytes(buffer, strict_utf8(scalar))
    }
    DeleteScalar(position) => {
      if position < 0 || position >= 0x7fff_ffff {
        raise R0CodecError::InvalidValue(
          detail="delete position outside R0 bounds",
        )
      }
      buffer.write_byte(b'\x02')
      buffer.write_byte(b'\x01')
      write_uvarint(buffer, position)
    }
    Undelete(target) => {
      buffer.write_byte(b'\x03')
      write_raw_identity(buffer, target)
    }
  }
  buffer.to_bytes()
}

///|
fn sha256(value : Bytes) -> Bytes {
  @crypto.sha256(value).unsafe_reinterpret_as_bytes()
}

///|
fn canonical_body_digest(body : CanonicalBody) -> Bytes raise R0CodecError {
  let buffer = Buffer()
  write_domain(buffer, "loomark-r0-event-body:v1")
  buffer.write_bytes(encode_canonical_body(body))
  sha256(buffer.to_bytes())
}

///|
fn bytes_hex(value : Bytes) -> String {
  @crypto.bytes_to_hex_string(value)
}

///|
/// Strict cursor decoder used by native and fresh JS targets.
struct R0Decoder {
  bytes : Bytes
  mut position : Int
}

///|
fn R0Decoder::new(bytes : Bytes) -> R0Decoder {
  { bytes, position: 0 }
}

///|
fn R0Decoder::read_byte(self : R0Decoder) -> Byte raise R0CodecError {
  if self.position >= self.bytes.length() {
    raise R0CodecError::MalformedEncoding(detail="unexpected end of input")
  }
  let value = self.bytes[self.position]
  self.position = self.position + 1
  value
}

///|
fn R0Decoder::read_uvarint(self : R0Decoder) -> Int raise R0CodecError {
  let start = self.position
  let mut value = 0
  let mut shift = 0
  while shift <= 28 {
    let byte = self.read_byte().to_int()
    let payload = byte & 0x7F
    if shift == 28 && payload > 0x07 {
      raise R0CodecError::MalformedEncoding(detail="uvarint overflow")
    }
    value = value | (payload << shift)
    if (byte & 0x80) == 0 {
      if self.position - start > 1 && payload == 0 {
        raise R0CodecError::MalformedEncoding(detail="non-minimal uvarint")
      }
      return value
    }
    shift = shift + 7
  }
  raise R0CodecError::MalformedEncoding(detail="uvarint overflow")
}

///|
fn R0Decoder::finish(self : R0Decoder) -> Unit raise R0CodecError {
  if self.position != self.bytes.length() {
    raise R0CodecError::MalformedEncoding(detail="trailing bytes")
  }
}
