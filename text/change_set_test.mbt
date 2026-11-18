///|
fn apply_change_set(source : String, changes : @text.ChangeSet) -> String raise {
  assert_eq(source.length(), changes.length())
  let result = StringBuilder()
  let mut offset = 0
  for section in changes.sections() {
    match section {
      Keep(n) => {
        result.write_string(source[offset:offset + n].to_owned())
        offset += n
      }
      Replace(n, text) => {
        result.write_string(text)
        offset += n
      }
    }
  }
  assert_eq(offset, source.length())
  assert_eq(result.to_string().length(), changes.new_length())
  result.to_string()
}

///|
fn replacement(
  length : Int32,
  start : Int32,
  end : Int32,
  text : String,
) -> @text.ChangeSet raise {
  @text.ChangeSet::new([
    Keep(start),
    Replace(end - start, text),
    Keep(length - end),
  ])
}

///|
fn scalar_boundaries(source : String) -> Array[Int32] {
  let offsets = [0]
  for ch in source {
    offsets.push(offsets[offsets.length() - 1] + ch.to_string().length())
  }
  offsets
}

///|
test "ChangeSet normalizes owns input and rejects malformed sections" {
  let parts : Array[@text.ChangeSection] = [
    Keep(0),
    Keep(1),
    Keep(2),
    Replace(1, ""),
    Replace(0, "🙂"),
    Keep(0),
    Replace(2, "X"),
    Keep(1),
  ]
  let changes = @text.ChangeSet::new(parts[:])
  parts[1] = Keep(9)
  assert_eq(changes.sections().to_owned(), [
    Keep(3),
    Replace(3, "🙂X"),
    Keep(1),
  ])
  assert_eq(apply_change_set("abcdefg", changes), "abc🙂Xg")
  for
    invalid in [
      [@text.ChangeSection::Keep(-1)],
      [Keep(2147483647), Keep(1)],
      [Replace(0, b"\x00\xD8".to_unchecked_string())],
    ] {
    let result = try {
      ignore(@text.ChangeSet::new(invalid[:]))
      false
    } catch {
      _ => true
    }
    assert_true(result)
  }
  let first = replacement(0, 0, 0, "🙂")
  let split = replacement(2, 1, 1, "x")
  let result = try {
    ignore(first.compose(split))
    false
  } catch {
    _ => true
  }
  assert_true(result)
  let mismatch = try {
    ignore(first.compose(@text.ChangeSet::new([Keep(3)])))
    false
  } catch {
    _ => true
  }
  assert_true(mismatch)
}

///|
test "compose checks surrogate boundaries even in discarded inserted slices" {
  let first = replacement(2, 1, 1, "🙂🚀")
  for (start, end, offset) in [(2, 2, 2), (1, 2, 2), (2, 5, 2), (3, 4, 4)] {
    let result = Ok(first.compose(replacement(6, start, end, "X"))) catch {
      error => Err(error)
    }
    assert_true(
      result is Err(@text.ChangeError::InvalidBoundary(offset=actual)) &&
      actual == offset,
    )
  }
  let composed = first.compose(replacement(6, 3, 5, "漢"))
  assert_eq(apply_change_set("ab", composed), "a🙂漢b")
  assert_eq(@text.ChangeSet::new(composed.sections()), composed)
}

///|
test "ChangeSet composition agrees with independent string edits across Unicode boundaries" {
  for source in ["", "abc", "a🙂漢"] {
    let offsets = scalar_boundaries(source)
    for start in offsets {
      for end in offsets {
        if end < start {
          continue
        }
        for text in ["", "XY", "🚀"] {
          let first = replacement(source.length(), start, end, text)
          let middle = source[:start].to_owned() +
            text +
            source[end:].to_owned()
          assert_eq(apply_change_set(source, first), middle)
          assert_eq(
            first.compose(@text.ChangeSet::new([Keep(middle.length())])),
            first,
          )
          assert_eq(
            @text.ChangeSet::new([Keep(source.length())]).compose(first),
            first,
          )
          let next_offsets = scalar_boundaries(middle)
          for a in next_offsets {
            for b in next_offsets {
              if b < a {
                continue
              }
              for inserted in ["", "z", "日本"] {
                let second = replacement(middle.length(), a, b, inserted)
                let expected = middle[:a].to_owned() +
                  inserted +
                  middle[b:].to_owned()
                let composed = first.compose(second)
                assert_eq(apply_change_set(source, composed), expected)
                // A third edit crosses prior section boundaries and tests
                // composition associativity, not only the final text.
                let boundaries = scalar_boundaries(expected)
                let left = boundaries[(boundaries.length() - 1) / 3]
                let right = boundaries[(boundaries.length() - 1) * 2 / 3]
                let third = replacement(
                  expected.length(),
                  left,
                  right,
                  "終🙂",
                )
                assert_eq(
                  composed.compose(third),
                  first.compose(second.compose(third)),
                )
                assert_eq(
                  apply_change_set(source, composed.compose(third)),
                  expected[:left].to_owned() +
                  "終🙂" +
                  expected[right:].to_owned(),
                )
              }
            }
          }
        }
      }
    }
  }
}
