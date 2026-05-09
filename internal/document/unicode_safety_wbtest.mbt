///| Step 1 of issue #31 — empirical demonstration of the bug.
///
/// Probes three questions:
///   α: Document::insert non-BMP input aborts via String::sub mid-surrogate.
///      Reproducer pinned with `panic` prefix.
///   β1: When ops with lone-surrogate content are ingested via apply_remote
///      and the agent_id tiebreaker favors the surrogate-pair sibling, the
///      result is well-formed (the high and low halves stay contiguous).
///   β2: When the agent_id tiebreaker favors a concurrent foreign op
///      instead, FugueMax places that op BETWEEN the two surrogates and
///      to_text() returns a malformed UTF-16 string. This is the
///      "concurrent peers split a surrogate pair" scenario described in
///      the issue.
///
/// MoonBit source code cannot literally express a lone surrogate
/// (`\u{D83D}` is rejected at lex time, surrogate values are not valid
/// `Char`s), so lone-surrogate strings are synthesized via
/// `Bytes::to_unchecked_string` over UTF-16LE bytes. This is the path
/// malformed peer ops would take after JSON/binary deserialization.

///|
/// Construct a String containing a single UTF-16 code unit. MoonBit's
/// String literals reject lone-surrogate escapes at lex time and `Char`
/// rejects surrogates as non-scalar values, so this is the only path to
/// a malformed-UTF-16 String. Bytes are interpreted as UTF-16LE.
fn lone_code_unit(code_unit : Int) -> String {
  let lo = (code_unit & 0xFF).to_byte()
  let hi = ((code_unit >> 8) & 0xFF).to_byte()
  Bytes::from_array([lo, hi]).to_unchecked_string()
}

///|
/// α: confirms Document::insert aborts on non-BMP input. The whole call
/// stack — Document::insert → text[i:i+1] → String::sub — panics. Pinned
/// here so the eg-walker test suite carries a reproducer independent of
/// any consumer.
test "panic α #31: Document::insert non-BMP aborts via String::sub" {
  let doc = Document::new("test")
  let _ = try? doc.insert(0, "😀")
}

///|
/// Shared op shape for β1/β2:
///   op0: insert U+D83D (high surrogate) at start. agent=peer_a, seq=0.
///   op1: insert U+DE00 (low surrogate) with origin_left=op0.
///        agent=peer_a, seq=1, parents=[op0].
///   opX: insert "X" with origin_left=op0, concurrent with op1.
///        agent varies between β1 and β2, parents=[op0].
///
/// FugueMax tie-breaks siblings under op0 by Lamport timestamp first,
/// then by agent_id (lexicographic). Both ops here have the same Lamport
/// (one beyond op0), so agent_id decides.
///
/// β1 — agent_id tiebreaker favors op1 (peer_a < peer_b lexically).
/// Result is the CLEAN ordering [D83D, DE00, X]. FugueMax happens to
/// place the surrogate pair contiguously here.
test "β1 #31: apply_remote with peer_a/peer_b — clean ordering" {
  let high = lone_code_unit(0xD83D)
  let low = lone_code_unit(0xDE00)
  inspect(high.length(), content="1")
  inspect(low.length(), content="1")
  let doc = Document::new("peer_a")
  let op0 = @core.Op::new_insert(-1, [], "peer_a", 0, high, None, None)
  doc.apply_remote(op0) catch {
    _ => ()
  }
  let op0_raw = @core.RawVersion::new("peer_a", 0)
  let op1 = @core.Op::new_insert(
    -1,
    [op0_raw],
    "peer_a",
    1,
    low,
    Some(op0_raw),
    None,
  )
  doc.apply_remote(op1) catch {
    _ => ()
  }
  let opX = @core.Op::new_insert(
    -1,
    [op0_raw],
    "peer_b",
    0,
    "X",
    Some(op0_raw),
    None,
  )
  doc.apply_remote(opX) catch {
    _ => ()
  }
  let text = doc.to_text()
  inspect(text.length(), content="3")
  inspect(text.code_unit_at(0).to_string(), content="55357") // D83D
  inspect(text.code_unit_at(1).to_string(), content="56832") // DE00 (low surrogate, kept contiguous)
  inspect(text.code_unit_at(2).to_string(), content="88") // 'X'
}

///|
/// β2 — agent_id tiebreaker favors opX (agent "aaa" < "peer_a"
/// lexically). FugueMax places opX BETWEEN op0 and op1 in the visible
/// sequence, splitting the surrogate pair. Result is the MALFORMED
/// ordering [D83D, X, DE00]. This demonstrates that bug #31 IS reachable
/// through `apply_remote` whenever a lone-surrogate op lands with an
/// agent_id that loses the tie-break to a sibling.
test "β2 #31: apply_remote where opX agent_id sorts before op1 — surrogate split" {
  let high = lone_code_unit(0xD83D)
  let low = lone_code_unit(0xDE00)
  let doc = Document::new("peer_a")
  let op0 = @core.Op::new_insert(-1, [], "peer_a", 0, high, None, None)
  doc.apply_remote(op0) catch {
    _ => ()
  }
  let op0_raw = @core.RawVersion::new("peer_a", 0)
  let op1 = @core.Op::new_insert(
    -1,
    [op0_raw],
    "peer_a",
    1,
    low,
    Some(op0_raw),
    None,
  )
  doc.apply_remote(op1) catch {
    _ => ()
  }
  // agent "aaa" sorts lexically BEFORE "peer_a" → opX wins the tiebreak.
  let opX = @core.Op::new_insert(
    -1,
    [op0_raw],
    "aaa",
    0,
    "X",
    Some(op0_raw),
    None,
  )
  doc.apply_remote(opX) catch {
    _ => ()
  }
  let text = doc.to_text()
  inspect(text.length(), content="3")
  inspect(text.code_unit_at(0).to_string(), content="55357") // D83D
  // BUG: `X` lands between the surrogates.
  inspect(text.code_unit_at(1).to_string(), content="88") // 'X'
  inspect(text.code_unit_at(2).to_string(), content="56832") // DE00
}
