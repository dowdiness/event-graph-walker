///|
/// Sections consume the base document from left to right, in UTF-16 units.
#derive(Eq, Debug)
pub(all) enum ChangeSection {
  Keep(Int32)
  Replace(Int32, String)
}

///|
#derive(Eq)
pub(all) suberror ChangeError {
  LengthMismatch
  InvalidLength
  InvalidBoundary(offset~ : Int32)
  InvalidText
}

///|
/// Immutable, normalized base-coordinate changes. No document or history owner.
#derive(Eq, Debug)
pub struct ChangeSet {
  priv parts : Array[ChangeSection]
  priv old_length : Int32
  priv new_length : Int32
}

///|
pub fn ChangeSet::new(
  sections : ArrayView[ChangeSection],
) -> ChangeSet raise ChangeError {
  normalize_sections(sections, validate_text=true)
}

///|
/// Composition supplies only validated strings and boundary-checked slices.
fn normalize_sections(
  sections : ArrayView[ChangeSection],
  validate_text~ : Bool,
) -> ChangeSet raise ChangeError {
  let parts : Array[ChangeSection] = []
  let mut old_length = 0
  let mut new_length = 0
  let mut deleted = 0
  let mut first = ""
  let mut inserted : StringBuilder? = None
  let mut replacing = false
  for section in sections {
    let (old, next) = match section {
      Keep(n) => (n, n)
      Replace(n, text) => {
        if validate_text && !is_well_formed_utf16(text) {
          raise InvalidText
        }
        (n, text.length())
      }
    }
    if old < 0 ||
      old_length > 2147483647 - old ||
      new_length > 2147483647 - next {
      raise InvalidLength
    }
    old_length += old
    new_length += next
    match section {
      Keep(0) | Replace(0, "") => ()
      Keep(n) => {
        if replacing {
          parts.push(
            Replace(
              deleted,
              match inserted {
                Some(builder) => builder.to_string()
                None => first
              },
            ),
          )
          deleted = 0
          first = ""
          inserted = None
          replacing = false
        }
        match parts.last() {
          Some(Keep(before)) => parts[parts.length() - 1] = Keep(before + n)
          _ => parts.push(Keep(n))
        }
      }
      Replace(n, text) => {
        replacing = true
        deleted += n
        if text != "" {
          match inserted {
            Some(builder) => builder.write_string(text)
            None if first == "" => first = text
            None => {
              let builder = StringBuilder()
              builder.write_string(first)
              builder.write_string(text)
              inserted = Some(builder)
            }
          }
        }
      }
    }
  }
  if replacing {
    parts.push(
      Replace(
        deleted,
        match inserted {
          Some(builder) => builder.to_string()
          None => first
        },
      ),
    )
  }
  { parts, old_length, new_length, }
}

///|
pub fn ChangeSet::length(self : ChangeSet) -> Int32 {
  self.old_length
}

///|
pub fn ChangeSet::new_length(self : ChangeSet) -> Int32 {
  self.new_length
}

///|
pub fn ChangeSet::sections(self : ChangeSet) -> ArrayView[ChangeSection] {
  self.parts[:]
}

///|
priv enum ChangePiece {
  Original(Int32, Int32)
  Inserted(String)
}

///|
fn ChangePiece::length(self : ChangePiece) -> Int32 {
  match self {
    Original(start, end) => end - start
    Inserted(text) => text.length()
  }
}

///|
/// Compose A→B with B→C. Walk section boundaries, never the unchanged text.
pub fn ChangeSet::compose(
  self : ChangeSet,
  next : ChangeSet,
) -> ChangeSet raise ChangeError {
  if self.new_length != next.old_length {
    raise LengthMismatch
  }
  let pieces : Array[ChangePiece] = []
  let mut position = 0
  for section in self.parts {
    match section {
      Keep(n) => {
        pieces.push(Original(position, position + n))
        position += n
      }
      Replace(n, text) => {
        if text != "" {
          pieces.push(Inserted(text))
        }
        position += n
      }
    }
  }
  let result : Array[ChangePiece] = []
  let mut index = 0
  let mut offset = 0
  let mut consumed = 0
  for section in next.parts {
    let (amount, keep) = match section {
      Keep(n) => (n, true)
      Replace(n, text) => {
        if text != "" {
          result.push(Inserted(text))
        }
        (n, false)
      }
    }
    let mut remaining = amount
    while remaining > 0 {
      let piece = pieces[index]
      let take = remaining.min(piece.length() - offset)
      match piece {
        Original(start, _) =>
          if keep {
            result.push(Original(start + offset, start + offset + take))
          }
        Inserted(text) => {
          let end = offset + take
          // StringView::to_owned repairs split surrogates; check the raw
          // boundary first rather than silently changing the inserted text.
          if end < text.length() {
            let unit = text[end].to_int()
            if unit >= 0xDC00 && unit <= 0xDFFF {
              raise InvalidBoundary(offset=consumed + take)
            }
          }
          if keep {
            result.push(Inserted(text[offset:end].to_owned()))
          }
        }
      }
      consumed += take
      remaining -= take
      offset += take
      if offset == piece.length() {
        index += 1
        offset = 0
      }
    }
  }
  let sections : Array[ChangeSection] = []
  let mut original = 0
  for piece in result {
    match piece {
      Original(start, end) => {
        if start > original {
          sections.push(Replace(start - original, ""))
        }
        sections.push(Keep(end - start))
        original = end
      }
      Inserted(text) => sections.push(Replace(0, text))
    }
  }
  if original < self.old_length {
    sections.push(Replace(self.old_length - original, ""))
  }
  normalize_sections(sections[:], validate_text=false)
}

///|
pub extend ChangeSection with Eq::{equal, not_equal}

///|
pub extend ChangeSection with @debug.Debug::{to_repr}

///|
pub extend ChangeError with Eq::{equal, not_equal}

///|
pub extend ChangeSet with Eq::{equal, not_equal}

///|
pub extend ChangeSet with @debug.Debug::{to_repr}
