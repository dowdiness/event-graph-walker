///|
/// Strict proof-validation failure.
suberror R0ProofError {
  InvalidProof(detail~ : String)
}

///|
struct MmrPeak {
  height : Int
  start : Int
  digest : Bytes
} derive(Eq, Debug)

///|
/// Direction is the sibling's side: 0 left, 1 right.
struct MmrSibling {
  direction : Int
  digest : Bytes
} derive(Eq, Debug)

///|
struct R0MmrProof {
  leaf_position : Int
  containing_peak_height : Int
  siblings : Array[MmrSibling]
  other_peaks : Array[MmrPeak]
  declared_sibling_count : Int
  declared_other_peak_count : Int
  trailing_byte : Bool
} derive(Eq, Debug)

///|
struct R0Mmr {
  leaf_hashes : Array[Bytes]
}

///|
fn validate_digest(digest : Bytes) -> Unit raise R0ProofError {
  if digest.length() != 32 {
    raise R0ProofError::InvalidProof(detail="digest must contain 32 bytes")
  }
}

///|
fn meta_node_hash(height : Int, left : Bytes, right : Bytes) -> Bytes {
  let buffer = Buffer()
  try! write_domain(buffer, "loomark-r0-meta-node:v2")
  try! write_uvarint(buffer, height)
  buffer.write_bytes(left)
  buffer.write_bytes(right)
  sha256(buffer.to_bytes())
}

///|
fn subtree_hash(leaves : Array[Bytes], start : Int, height : Int) -> Bytes {
  if height == 0 {
    leaves[start]
  } else {
    let half = 1 << (height - 1)
    meta_node_hash(
      height,
      subtree_hash(leaves, start, height - 1),
      subtree_hash(leaves, start + half, height - 1),
    )
  }
}

///|
/// Binary decomposition in the MMR's strictly descending peak-height order.
fn peak_layout(leaf_count : Int) -> Array[(Int, Int)] {
  let result : Array[(Int, Int)] = []
  let mut remaining = leaf_count
  let mut start = 0
  while remaining > 0 {
    let mut height = 0
    while 1 << (height + 1) <= remaining {
      height = height + 1
    }
    result.push((height, start))
    let size = 1 << height
    start = start + size
    remaining = remaining - size
  }
  result
}

///|
fn build_peaks(leaves : Array[Bytes]) -> Array[MmrPeak] {
  let peaks : Array[MmrPeak] = []
  for layout in peak_layout(leaves.length()) {
    let (height, start) = layout
    peaks.push({ height, start, digest: subtree_hash(leaves, start, height) })
  }
  peaks
}

///|
fn R0Mmr::from_leaf_hashes(leaves : ArrayView[Bytes]) -> R0Mmr {
  let owned : Array[Bytes] = []
  for leaf in leaves {
    if leaf.length() != 32 {
      panic()
    }
    owned.push(leaf)
  }
  { leaf_hashes: owned }
}

///|
fn writer_root_from_peaks(
  agent : String,
  leaf_count : Int,
  peaks : Array[MmrPeak],
) -> Bytes {
  let buffer = Buffer()
  try! write_domain(buffer, "loomark-r0-writer-root:v2")
  try! write_lp_utf8(buffer, agent)
  try! write_uvarint(buffer, leaf_count)
  try! write_uvarint(buffer, peaks.length())
  for peak in peaks {
    try! write_uvarint(buffer, peak.height)
    buffer.write_bytes(peak.digest)
  }
  sha256(buffer.to_bytes())
}

///|
fn R0Mmr::writer_root(self : R0Mmr, agent : String) -> Bytes {
  let peaks = try! build_peaks(self.leaf_hashes)
  writer_root_from_peaks(agent, self.leaf_hashes.length(), peaks)
}

///|
fn collect_siblings(
  leaves : Array[Bytes],
  start : Int,
  height : Int,
  position : Int,
  siblings : Array[MmrSibling],
) -> Unit {
  if height == 0 {
    return
  }
  let child_height = height - 1
  let half = 1 << child_height
  if position < start + half {
    collect_siblings(leaves, start, child_height, position, siblings)
    siblings.push({
      direction: 1,
      digest: subtree_hash(leaves, start + half, child_height),
    })
  } else {
    collect_siblings(leaves, start + half, child_height, position, siblings)
    siblings.push({
      direction: 0,
      digest: subtree_hash(leaves, start, child_height),
    })
  }
}

///|
fn R0Mmr::inclusion_proof(
  self : R0Mmr,
  position : Int,
) -> R0MmrProof raise R0ProofError {
  if position < 0 || position >= self.leaf_hashes.length() {
    raise R0ProofError::InvalidProof(detail="leaf position outside writer")
  }
  let peaks = build_peaks(self.leaf_hashes)
  let mut containing_index = -1
  for index, peak in peaks {
    if position >= peak.start && position < peak.start + (1 << peak.height) {
      containing_index = index
      break
    }
  }
  if containing_index < 0 {
    raise R0ProofError::InvalidProof(detail="containing peak not found")
  }
  let containing = peaks[containing_index]
  let siblings : Array[MmrSibling] = []
  collect_siblings(
    self.leaf_hashes,
    containing.start,
    containing.height,
    position,
    siblings,
  )
  let other_peaks : Array[MmrPeak] = []
  for index, peak in peaks {
    if index != containing_index {
      other_peaks.push(peak)
    }
  }
  {
    leaf_position: position,
    containing_peak_height: containing.height,
    siblings,
    other_peaks,
    declared_sibling_count: siblings.length(),
    declared_other_peak_count: other_peaks.length(),
    trailing_byte: false,
  }
}

///|
fn R0MmrProof::copy_with(
  self : R0MmrProof,
  leaf_position? : Int,
  containing_peak_height? : Int,
  siblings? : Array[MmrSibling],
  other_peaks? : Array[MmrPeak],
  declared_sibling_count? : Int,
  declared_other_peak_count? : Int,
  trailing_byte? : Bool,
) -> R0MmrProof {
  {
    leaf_position: leaf_position.unwrap_or(self.leaf_position),
    containing_peak_height: containing_peak_height.unwrap_or(
      self.containing_peak_height,
    ),
    siblings: siblings.unwrap_or(self.siblings.copy()),
    other_peaks: other_peaks.unwrap_or(self.other_peaks.copy()),
    declared_sibling_count: declared_sibling_count.unwrap_or(
      self.declared_sibling_count,
    ),
    declared_other_peak_count: declared_other_peak_count.unwrap_or(
      self.declared_other_peak_count,
    ),
    trailing_byte: trailing_byte.unwrap_or(self.trailing_byte),
  }
}

///|
fn R0MmrProof::with_leaf_position(self : R0MmrProof, value : Int) -> R0MmrProof {
  self.copy_with(leaf_position=value)
}

///|
fn R0MmrProof::with_containing_peak_height(
  self : R0MmrProof,
  value : Int,
) -> R0MmrProof {
  self.copy_with(containing_peak_height=value)
}

///|
fn R0MmrProof::with_sibling_count(self : R0MmrProof, value : Int) -> R0MmrProof {
  self.copy_with(declared_sibling_count=value)
}

///|
fn R0MmrProof::with_other_peak_count(
  self : R0MmrProof,
  value : Int,
) -> R0MmrProof {
  self.copy_with(declared_other_peak_count=value)
}

///|
fn R0MmrProof::with_reversed_other_peaks(self : R0MmrProof) -> R0MmrProof {
  let peaks = self.other_peaks.copy()
  for index in 0..<(peaks.length() / 2) {
    let other = peaks.length() - index - 1
    let held = peaks[index]
    peaks[index] = peaks[other]
    peaks[other] = held
  }
  if peaks.length() == 1 {
    peaks[0] = { ..peaks[0], height: self.containing_peak_height }
  }
  self.copy_with(other_peaks=peaks)
}

///|
fn R0MmrProof::with_invalid_direction(self : R0MmrProof) -> R0MmrProof {
  let siblings = self.siblings.copy()
  if siblings.length() > 0 {
    siblings[0] = { ..siblings[0], direction: 2 }
  }
  self.copy_with(siblings~)
}

///|
fn R0MmrProof::with_trailing_byte(self : R0MmrProof) -> R0MmrProof {
  self.copy_with(trailing_byte=true)
}

///|
fn verify_mmr_inclusion(
  agent~ : String,
  leaf_count~ : Int,
  leaf_hash~ : Bytes,
  expected_root~ : Bytes,
  proof~ : R0MmrProof,
) -> Unit raise R0ProofError {
  validate_digest(leaf_hash)
  validate_digest(expected_root)
  if leaf_count <= 0 ||
    proof.leaf_position < 0 ||
    proof.leaf_position >= leaf_count {
    raise R0ProofError::InvalidProof(detail="wrong leaf position")
  }
  if proof.trailing_byte {
    raise R0ProofError::InvalidProof(detail="trailing proof byte")
  }
  if proof.declared_sibling_count != proof.siblings.length() ||
    proof.declared_sibling_count != proof.containing_peak_height {
    raise R0ProofError::InvalidProof(detail="wrong sibling count")
  }
  if proof.declared_other_peak_count != proof.other_peaks.length() {
    raise R0ProofError::InvalidProof(detail="wrong other-peak count")
  }
  let layout = peak_layout(leaf_count)
  let mut containing_index = -1
  for index, item in layout {
    let (height, start) = item
    if proof.leaf_position >= start &&
      proof.leaf_position < start + (1 << height) {
      containing_index = index
      if proof.containing_peak_height != height {
        raise R0ProofError::InvalidProof(detail="wrong containing peak height")
      }
      break
    }
  }
  if containing_index < 0 || proof.other_peaks.length() + 1 != layout.length() {
    raise R0ProofError::InvalidProof(detail="incomplete peak set")
  }
  let mut current = leaf_hash
  for level, sibling in proof.siblings {
    validate_digest(sibling.digest)
    let relative = proof.leaf_position - layout[containing_index].1
    let expected_direction = if ((relative >> level) & 1) == 0 { 1 } else { 0 }
    if sibling.direction != expected_direction {
      raise R0ProofError::InvalidProof(detail="wrong proof direction")
    }
    current = if sibling.direction == 0 {
      meta_node_hash(level + 1, sibling.digest, current)
    } else {
      meta_node_hash(level + 1, current, sibling.digest)
    }
  }
  let all_peaks : Array[MmrPeak] = []
  let mut other_index = 0
  for index, item in layout {
    let (expected_height, expected_start) = item
    if index == containing_index {
      all_peaks.push({
        height: expected_height,
        start: expected_start,
        digest: current,
      })
    } else {
      let other = proof.other_peaks[other_index]
      validate_digest(other.digest)
      if other.height != expected_height {
        raise R0ProofError::InvalidProof(detail="wrong other-peak order")
      }
      all_peaks.push({
        height: other.height,
        start: expected_start,
        digest: other.digest,
      })
      other_index = other_index + 1
    }
  }
  if writer_root_from_peaks(agent, leaf_count, all_peaks) != expected_root {
    raise R0ProofError::InvalidProof(detail="writer root mismatch")
  }
}
