///| Unicode safety regression suite for issue #31.
///
/// History:
///   - PR #34 (Step 1) added these tests as panic / inspect probes pinning
///     the broken behavior of current main: Document::insert aborted on
///     non-BMP input, and apply_remote happily ingested lone-surrogate
///     ops which then merged into a malformed `\uD83D X \uDE00` document
///     when agent_id tiebreaking placed a concurrent op between the
///     surrogate halves.
///   - This file (Step 2) flips them to assert the fixed behavior:
///     Document::insert iterates per-codepoint and produces atomic Ops,
///     and apply_remote / merge_remote validate Op content and reject
///     lone surrogates before any state mutation.

///|
/// Construct a String containing a single UTF-16 code unit, including
/// values in the surrogate range. MoonBit's String literals reject
/// lone-surrogate escapes at lex time and `Char` rejects surrogates as
/// non-scalar values, so this is the only path to a malformed-UTF-16
/// String. Bytes are interpreted as UTF-16LE.
fn lone_code_unit(code_unit : Int) -> String {
  let lo = (code_unit & 0xFF).to_byte()
  let hi = ((code_unit >> 8) & 0xFF).to_byte()
  Bytes::from_array([lo, hi]).to_unchecked_string()
}

///|
/// α — Document::insert accepts non-BMP input and produces a single
/// atomic Op for the whole codepoint. Replaces the prior `panic` test
/// asserting String::sub aborted mid-surrogate.
test "α #31: Document::insert accepts non-BMP and stores one atomic Op" {
  let doc = Document::new("alice")
  let last = try! doc.insert(0, "😀")
  inspect(doc.to_text(), content="😀")
  // visible_count returns item count (one item per codepoint after Step 2).
  // For "😀" that's 1 item even though to_text().length() is 2 code units.
  inspect(doc.visible_count(), content="1")
  // The returned Op carries the full codepoint, not a surrogate half.
  match last.content() {
    @core.Insert(text) => inspect(text, content="😀")
    _ => fail("expected Insert content")
  }
}

///|
/// β3 — Document::insert advances cursor by `utf16_len` per codepoint,
/// so a mixed BMP/non-BMP string lays out correctly.
test "β3 #31: Document::insert mixed BMP/non-BMP advances cursor by utf16_len" {
  let doc = Document::new("alice")
  let _ = try! doc.insert(0, "a😀b")
  inspect(doc.to_text(), content="a😀b")
  inspect(doc.visible_count(), content="3") // 3 items: 'a', '😀', 'b'
}

///|
/// β5 — non-BMP insert MIDWAY through an existing document positions
/// subsequent inserts correctly. Caller passes UTF-16 code-unit offsets
/// (`"ab"`, then position 1 to insert between a and b). Internally the
/// loop must keep its item-space position in sync so the second
/// codepoint of the input ("X") lands BEFORE "b", not at the end.
///
/// Pre-Codex-review this case would have produced "a😀bX" because
/// current_pos advanced by 2 code units (past "b" in item-space) after
/// the emoji insert.
test "β5 #31: insert at mid-doc with mixed codepoints lands correctly" {
  let doc = Document::new("alice")
  let _ = try! doc.insert(0, "ab")
  let _ = try! doc.insert(1, "😀X")
  inspect(doc.to_text(), content="a😀Xb")
}

///|
/// β1 — apply_remote rejects an Op whose Insert content is a lone
/// surrogate. After Step 2, validate_insert_content runs before any
/// oplog or tree mutation.
test "β1 #31: apply_remote rejects lone high surrogate with ContentError" {
  let high = lone_code_unit(0xD83D)
  inspect(high.length(), content="1")
  let doc = Document::new("peer_a")
  let op0 = @core.Op::new_insert(-1, [], "peer_a", 0, high, None, None)
  let result : Result[Unit, DocumentError] = try? doc.apply_remote(op0)
  inspect(
    result is Err(DocumentError::ContentError(reason=MalformedUtf16)),
    content="true",
  )
  // The doc remains empty — rejection is atomic.
  inspect(doc.to_text(), content="")
  inspect(doc.visible_count(), content="0")
}

///|
/// β2 — same construction as β1 but tries the lone low surrogate. Same
/// rejection. Pre-fix this scenario could lead to a malformed merge with
/// concurrent ops; post-fix the malformed Op never reaches the FugueTree.
test "β2 #31: apply_remote rejects lone low surrogate with ContentError" {
  let low = lone_code_unit(0xDE00)
  inspect(low.length(), content="1")
  let doc = Document::new("peer_a")
  let op0 = @core.Op::new_insert(-1, [], "peer_a", 0, low, None, None)
  let result : Result[Unit, DocumentError] = try? doc.apply_remote(op0)
  inspect(
    result is Err(DocumentError::ContentError(reason=MalformedUtf16)),
    content="true",
  )
  inspect(doc.to_text(), content="")
}

///|
/// Multiple-codepoint Op content is also rejected. Document::insert never
/// produces such ops, but a malicious / buggy peer could send one.
test "β #31: apply_remote rejects multi-codepoint Insert content" {
  let doc = Document::new("peer_a")
  let op0 = @core.Op::new_insert(-1, [], "peer_a", 0, "ab", None, None)
  let result : Result[Unit, DocumentError] = try? doc.apply_remote(op0)
  inspect(
    result is Err(DocumentError::ContentError(reason=MultipleCodepoints)),
    content="true",
  )
}

///|
/// Empty-content Op is also rejected on ingest. (Document::insert's
/// internal empty-string fallback returns a synthesized op via oplog
/// directly without going through apply_remote, so that path is
/// unaffected.)
test "β #31: apply_remote rejects empty Insert content" {
  let doc = Document::new("peer_a")
  let op0 = @core.Op::new_insert(-1, [], "peer_a", 0, "", None, None)
  let result : Result[Unit, DocumentError] = try? doc.apply_remote(op0)
  inspect(
    result is Err(DocumentError::ContentError(reason=EmptyContent)),
    content="true",
  )
}

///|
/// Concurrent merge with well-formed emoji ops can NOT split the
/// surrogate pair, because the surrogate halves are now atomic at the
/// Op level. This is the post-fix counterpart of pre-fix β2 (the
/// malformed-merge scenario from the issue body).
test "β4 #31: concurrent insert next to atomic emoji op cannot split surrogates" {
  let doc = Document::new("peer_a")
  // Local insert produces one atomic Op for "😀".
  let _ = try! doc.insert(0, "😀")
  let op0_raw = @core.RawVersion::new("peer_a", 0)
  // Concurrent peer "aaa" inserts "X" with origin_left=op0 (i.e., "right
  // after op0" from aaa's perspective). agent_id "aaa" wins the tiebreak,
  // but op0's content is "😀" — there's nowhere "between" for X to land.
  let opX = @core.Op::new_insert(
    -1,
    [op0_raw],
    "aaa",
    0,
    "X",
    Some(op0_raw),
    None,
  )
  try! doc.apply_remote(opX)
  let text = doc.to_text()
  // Either "😀X" or "X😀" depending on how FugueMax tiebreaks at the
  // Item level; both are well-formed. Assert no surrogate split.
  let cu0 = text.code_unit_at(0).to_int()
  let cu1 = text.code_unit_at(1).to_int()
  let cu2 = text.code_unit_at(2).to_int()
  // Surrogate halves must remain adjacent: a high surrogate is always
  // followed immediately by a low surrogate.
  let high_pair_at_0 = cu0 >= 0xD800 &&
    cu0 <= 0xDBFF &&
    cu1 >= 0xDC00 &&
    cu1 <= 0xDFFF
  let high_pair_at_1 = cu1 >= 0xD800 &&
    cu1 <= 0xDBFF &&
    cu2 >= 0xDC00 &&
    cu2 <= 0xDFFF
  inspect(high_pair_at_0 || high_pair_at_1, content="true")
}
