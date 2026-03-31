// Property-based tests for position round-trip correctness.
//
// Verifies that insert(position, char) places the character at exactly
// that position in the resulting text. This catches any divergence between
// the FugueMax tree placement and the position-based API contract.

///|
fn do_insert(doc : TextState, pos : Int, ch : String) -> Unit {
  doc.insert(Pos::at(pos), ch) catch {
    _ => ()
  }
}

///|
/// Property: after insert(pos, ch), text()[pos] == ch.
///
/// This is the fundamental contract between the position-based Document API
/// and the FugueMax tree. If FugueMax places a character at a different
/// position than requested, this test catches it.
fn prop_insert_position_roundtrip(ops : RealOps) -> Bool {
  let doc = TextState::new("roundtrip")
  for edit in ops.edits {
    match edit {
      Insert(pos, ch) => {
        let before_len = doc.len()
        doc.insert(Pos::at(pos), ch) catch {
          _ => continue
        }
        let text = doc.text()
        // Core invariant: character is at the requested position
        if text[pos:pos + 1].to_string() != ch {
          return false
        }
        // Length increased by exactly 1
        if text.length() != before_len + 1 {
          return false
        }
      }
      Delete(pos) => doc.delete(Pos::at(pos)) catch { _ => continue }
    }
  }
  true
}

///|
test "property: insert at position P places character at position P" {
  @qc.quick_check_fn(
    prop_insert_position_roundtrip,
    max_success=200,
    max_size=50,
  ) catch {
    failure => raise failure
  }
}

///|
/// Targeted test: insert at position 0 on non-empty document.
/// This is the specific case where FugueMax's find_parent_and_side(None, _)
/// places the item as a right child of root (at the END), violating the
/// position contract.
test "position roundtrip: insert at 0 on non-empty doc" {
  let doc = TextState::new("test")
  do_insert(doc, 0, "a")
  do_insert(doc, 1, "b")
  do_insert(doc, 2, "c")
  // Now insert at position 0 on a 3-char doc
  do_insert(doc, 0, "X")
  let text = doc.text()
  // X must be at position 0, not at the end
  inspect(text[0:1].to_string(), content="X")
  inspect(text, content="Xabc")
}

///|
/// Targeted test: multiple inserts at position 0 interleave correctly.
test "position roundtrip: repeated insert at 0" {
  let doc = TextState::new("test")
  do_insert(doc, 0, "c")
  do_insert(doc, 0, "b")
  do_insert(doc, 0, "a")
  // Each insert at 0 pushes previous content right
  inspect(doc.text(), content="abc")
}

///|
/// Targeted test: insert at 0, then insert at end, then insert at 0 again.
test "position roundtrip: alternating insert at 0 and end" {
  let doc = TextState::new("test")
  do_insert(doc, 0, "a")
  inspect(doc.text(), content="a")
  do_insert(doc, 1, "b")
  inspect(doc.text(), content="ab")
  do_insert(doc, 0, "X")
  inspect(doc.text(), content="Xab")
  do_insert(doc, 3, "Y")
  inspect(doc.text(), content="XabY")
  do_insert(doc, 0, "Z")
  inspect(doc.text(), content="ZXabY")
}
