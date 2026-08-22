///|
/// RFC 4648 base64 used at the native/fresh-JS process seam.
fn base64_encode(bytes : Bytes) -> String {
  let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  let output = StringBuilder::new()
  let mut index = 0
  while index < bytes.length() {
    let remaining = bytes.length() - index
    let first = bytes[index].to_int()
    let second = if remaining > 1 { bytes[index + 1].to_int() } else { 0 }
    let third = if remaining > 2 { bytes[index + 2].to_int() } else { 0 }
    let bits = (first << 16) | (second << 8) | third
    output.write_char(alphabet[(bits >> 18) & 0x3f].to_int().unsafe_to_char())
    output.write_char(alphabet[(bits >> 12) & 0x3f].to_int().unsafe_to_char())
    if remaining > 1 {
      output.write_char(alphabet[(bits >> 6) & 0x3f].to_int().unsafe_to_char())
    } else {
      output.write_char('=')
    }
    if remaining > 2 {
      output.write_char(alphabet[bits & 0x3f].to_int().unsafe_to_char())
    } else {
      output.write_char('=')
    }
    index = index + 3
  }
  output.to_string()
}

///|
fn base64_value(code_unit : UInt16) -> Int {
  let code = code_unit.to_int()
  if code >= 'A'.to_int() && code <= 'Z'.to_int() {
    code - 'A'.to_int()
  } else if code >= 'a'.to_int() && code <= 'z'.to_int() {
    code - 'a'.to_int() + 26
  } else if code >= '0'.to_int() && code <= '9'.to_int() {
    code - '0'.to_int() + 52
  } else if code == '+'.to_int() {
    62
  } else if code == '/'.to_int() {
    63
  } else {
    -1
  }
}

///|
/// Strict canonical RFC 4648 base64 decoder.
fn base64_decode(value : String) -> Bytes raise R0CodecError {
  if value.length() % 4 != 0 {
    raise R0CodecError::MalformedEncoding(detail="invalid base64 length")
  }
  let output = Buffer()
  let mut index = 0
  while index < value.length() {
    let c0 = base64_value(value[index])
    let c1 = base64_value(value[index + 1])
    let final_group = index + 4 == value.length()
    let c2 = if value[index + 2] == '=' {
      -2
    } else {
      base64_value(value[index + 2])
    }
    let c3 = if value[index + 3] == '=' {
      -2
    } else {
      base64_value(value[index + 3])
    }
    if c0 < 0 ||
      c1 < 0 ||
      c2 == -1 ||
      c3 == -1 ||
      (!final_group && (c2 < 0 || c3 < 0)) ||
      (c2 == -2 && c3 != -2) {
      raise R0CodecError::MalformedEncoding(
        detail="invalid base64 alphabet or padding",
      )
    }
    let third = if c2 >= 0 { c2 } else { 0 }
    let fourth = if c3 >= 0 { c3 } else { 0 }
    let bits = (c0 << 18) | (c1 << 12) | (third << 6) | fourth
    output.write_byte(((bits >> 16) & 0xff).to_byte())
    if c2 >= 0 {
      output.write_byte(((bits >> 8) & 0xff).to_byte())
    }
    if c3 >= 0 {
      output.write_byte((bits & 0xff).to_byte())
    }
    index = index + 4
  }
  let decoded = output.to_bytes()
  if base64_encode(decoded) != value {
    raise R0CodecError::MalformedEncoding(detail="non-canonical base64")
  }
  decoded
}
