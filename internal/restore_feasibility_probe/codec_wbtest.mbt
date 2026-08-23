///|
fn repeated_digest(byte : Byte) -> Bytes {
  let values : Array[Byte] = []
  for _ in 0..<32 {
    values.push(byte)
  }
  Bytes::from_array(values)
}

///|
test "R0 codec has frozen minimal-uvarint vectors" {
  let vectors = [
    (0, "00"),
    (1, "01"),
    (127, "7f"),
    (128, "8001"),
    (255, "ff01"),
    (300, "ac02"),
    (16384, "808001"),
    (0x7fff_ffff, "ffffffff07"),
  ]
  for vector in vectors {
    let (value, expected) = vector
    assert_eq(bytes_hex(encode_uvarint(value)), expected)
    let decoder = R0Decoder::_new(encode_uvarint(value))
    assert_eq(try! decoder._read_uvarint(), value)
    try! decoder._finish()
  }
}

///|
test "R0 codec rejects invalid and non-minimal uvarints" {
  let invalid = [
    Bytes::from_array([b'\x80', b'\x00']),
    Bytes::from_array([b'\x81', b'\x00']),
    Bytes::from_array([b'\xff', b'\xff', b'\xff', b'\xff', b'\x08']),
    Bytes::from_array([b'\x80']),
  ]
  for encoded in invalid {
    let decoder = R0Decoder::_new(encoded)
    let result : Result[Int, R0CodecError] = Ok(decoder._read_uvarint()) catch {
      error => Err(error)
    }
    inspect(result is Err(_), content="true")
  }
  let negative : Result[Bytes, R0CodecError] = Ok(encode_uvarint(-1)) catch {
    error => Err(error)
  }
  inspect(negative is Err(_), content="true")
}

///|
test "R0 canonical body and SHA-256 vectors are frozen" {
  assert_eq(
    bytes_hex(encode_canonical_body(InsertScalar(0, "a"))),
    "0101000161",
  )
  assert_eq(
    bytes_hex(_canonical_body_digest(InsertScalar(0, "a"))),
    "687235689e54b2f2ff3b5758f13e811be42e684efab36604c25661910b1c7bff",
  )
  assert_eq(
    bytes_hex(encode_canonical_body(InsertScalar(127, "🙂"))),
    "01017f04f09f9982",
  )
  assert_eq(bytes_hex(encode_canonical_body(DeleteScalar(128))), "02018001")
  assert_eq(
    bytes_hex(
      encode_canonical_body(Undelete(RawIdentity(agent="r0-a", sequence=300))),
    ),
    "030472302d61ac02",
  )
  assert_eq(
    bytes_hex(sha256(b"abc")),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  )
}

///|
test "R0 preflight rejects invalid identities and scalars" {
  let invalid_identities = [
    RawIdentity(agent="", sequence=0),
    RawIdentity(agent="r0-a", sequence=-1),
    RawIdentity(agent="r0-a", sequence=0x7fff_ffff),
  ]
  for identity in invalid_identities {
    let result : Result[Bytes, R0CodecError] = Ok(encode_raw_identity(identity)) catch {
      error => Err(error)
    }
    inspect(result is Err(_), content="true")
  }
  let two_scalars : Result[Bytes, R0CodecError] = Ok(
    encode_canonical_body(InsertScalar(0, "ab")),
  ) catch {
    error => Err(error)
  }
  inspect(two_scalars is Err(_), content="true")
  let malformed = Bytes::from_array([b'\x00', b'\xd8']).to_unchecked_string()
  let malformed_result : Result[Bytes, R0CodecError] = Ok(
    encode_raw_identity(RawIdentity(agent=malformed, sequence=0)),
  ) catch {
    error => Err(error)
  }
  inspect(malformed_result is Err(_), content="true")
}

///|
test "R0 scalar stream preserves CRLF and lone line endings" {
  let scalars = ["\r", "\n", "\r", "a", "\n"]
  let encoded = scalars.map(scalar => {
    encode_canonical_body(InsertScalar(0, scalar))
  })
  assert_eq(bytes_hex(encoded[0]), "010100010d")
  assert_eq(bytes_hex(encoded[1]), "010100010a")
  assert_eq(bytes_hex(encoded[2]), "010100010d")
  assert_eq(bytes_hex(encoded[4]), "010100010a")
  assert_eq(scalars.join(""), "\r\n\ra\n")
  assert_eq(unicode_scalar_length(scalars.join("")), 5)
}

///|
test "R0 raw identity ordering is UTF-8 bytewise then sequence" {
  let values = [
    RawIdentity(agent="😀", sequence=0),
    RawIdentity(agent="é", sequence=0),
    RawIdentity(agent="z", sequence=1),
    RawIdentity(agent="z", sequence=0),
  ]
  values.sort_by(compare_raw_identity)
  assert_eq(values.map(identity => identity.agent), ["z", "z", "é", "😀"])
  assert_eq(values.map(identity => identity.sequence), [0, 1, 0, 0])
}

///|
test "R0 MMR roots have frozen one-to-four-leaf vectors" {
  let leaves = [
    repeated_digest(b'\x01'),
    repeated_digest(b'\x02'),
    repeated_digest(b'\x03'),
    repeated_digest(b'\x04'),
  ]
  let expected = [
    "2521f3d0d65227c22843d4cdf9ecdd606ae9e7521e87d0a8d7336ab036cdf0de", "39875734f964d79c804dd956bcdd74e046d4c897bb6b5f760f4a04261a219aab",
    "6abc04f7b7634609c77d01d32f22d87198cd40a7d40e72c4a303590a24ef2a56", "30fedd648be4ce1aa099c5c774f378dbfdcc797cddb2af80c7baff35051992f0",
  ]
  for count in 1..<=4 {
    let mmr = R0Mmr::_from_leaf_hashes(leaves[:count])
    assert_eq(bytes_hex(mmr._writer_root("r0-a")), expected[count - 1])
    for position in 0..<count {
      let proof = try! mmr._inclusion_proof(position)
      try! _verify_mmr_inclusion(
        agent="r0-a",
        leaf_count=count,
        leaf_hash=leaves[position],
        expected_root=mmr._writer_root("r0-a"),
        proof~,
      )
    }
  }
}

///|
test "R0 Append from an authenticated proof matches full recomputation" {
  let leaves = [
    repeated_digest(b'\x01'),
    repeated_digest(b'\x02'),
    repeated_digest(b'\x03'),
    repeated_digest(b'\x04'),
    repeated_digest(b'\x05'),
    repeated_digest(b'\x06'),
    repeated_digest(b'\x07'),
    repeated_digest(b'\x08'),
    repeated_digest(b'\x09'),
  ]
  for count in [1, 2, 3, 4, 5, 7, 8] {
    let mmr = R0Mmr::_from_leaf_hashes(leaves[:count])
    let proof = try! mmr._inclusion_proof(count - 1)
    let peaks = try! _verify_mmr_inclusion_peaks(
      agent="r0-a",
      leaf_count=count,
      leaf_hash=leaves[count - 1],
      expected_root=mmr._writer_root("r0-a"),
      proof~,
    )
    let appended_root = mmr_append_root("r0-a", count, peaks, leaves[count])
    let all_leaves = leaves[:count].to_owned()
    all_leaves.push(leaves[count])
    let expected = R0Mmr::_from_leaf_hashes(all_leaves)._writer_root("r0-a")
    assert_eq(appended_root, expected)
  }
}

///|
test "R0 MMR verifier rejects every malformed proof dimension" {
  let leaves = [
    repeated_digest(b'\x01'),
    repeated_digest(b'\x02'),
    repeated_digest(b'\x03'),
  ]
  let mmr = R0Mmr::_from_leaf_hashes(leaves[:])
  let root = mmr._writer_root("r0-a")
  let proof = try! mmr._inclusion_proof(0)
  let mutations = [
    proof._with_leaf_position(1),
    proof._with_containing_peak_height(proof.containing_peak_height + 1),
    proof._with_sibling_count(proof.siblings.length() + 1),
    proof._with_other_peak_count(proof.other_peaks.length() + 1),
    proof._with_reversed_other_peaks(),
    proof._with_invalid_direction(),
    proof._with_trailing_byte(),
  ]
  for invalid in mutations {
    let result : Result[Unit, R0ProofError] = Ok(
      _verify_mmr_inclusion(
        agent="r0-a",
        leaf_count=3,
        leaf_hash=leaves[0],
        expected_root=root,
        proof=invalid,
      ),
    ) catch {
      error => Err(error)
    }
    inspect(result is Err(_), content="true")
  }
  let wrong_root = repeated_digest(b'\xff')
  let mismatch : Result[Unit, R0ProofError] = Ok(
    _verify_mmr_inclusion(
      agent="r0-a",
      leaf_count=3,
      leaf_hash=leaves[0],
      expected_root=wrong_root,
      proof~,
    ),
  ) catch {
    error => Err(error)
  }
  inspect(mismatch is Err(_), content="true")
}

///|
test "R0 decoder rejects trailing bytes" {
  let decoder = R0Decoder::_new(Bytes::from_array([b'\x00', b'\x00']))
  assert_eq(try! decoder._read_uvarint(), 0)
  let result : Result[Unit, R0CodecError] = Ok(decoder._finish()) catch {
    error => Err(error)
  }
  inspect(result is Err(_), content="true")
}
