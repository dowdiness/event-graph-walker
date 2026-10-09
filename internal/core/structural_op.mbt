///|
pub suberror OpStructureError {
  EmptyReplica
  NegativeSequence
  InvalidParentIdentity
  InvalidParentShape
  EmptyInsert
  MalformedInsertUtf16
  MultiScalarInsert
  InvalidOriginIdentity
  MissingDeleteTarget
  DeleteHasRightTarget
}

///|
/// An operation whose state-independent wire structure and content are valid.
pub struct StructuralOp {
  priv op : Op
}

///|
pub fn StructuralOp::StructuralOp(
  op : Op,
) -> StructuralOp raise OpStructureError {
  if op.agent() == "" {
    raise OpStructureError::EmptyReplica
  }
  if op.seq() < 0 {
    raise OpStructureError::NegativeSequence
  }
  let identity = RawVersion(op.agent(), op.seq())
  let seen_parents : Map[RawVersion, Bool] = Map([])
  for parent in op.parents_iter() {
    if parent.agent == "" || parent.seq < 0 {
      raise OpStructureError::InvalidParentIdentity
    }
    if parent == identity || seen_parents.get(parent) is Some(_) {
      raise OpStructureError::InvalidParentShape
    }
    seen_parents[parent] = true
  }
  match op.content() {
    Insert(text) => {
      validate_single_scalar_insert(text)
      validate_structural_origin(op.origin_left())
      validate_structural_origin(op.origin_right())
    }
    Delete | Undelete => {
      if op.origin_left() is None {
        raise OpStructureError::MissingDeleteTarget
      }
      if op.origin_right() is Some(_) {
        raise OpStructureError::DeleteHasRightTarget
      }
      validate_structural_origin(op.origin_left())
    }
  }
  { op, }
}

///|
pub fn StructuralOp::raw(self : StructuralOp) -> Op {
  self.op
}

///|
fn validate_structural_origin(
  origin : RawVersion?,
) -> Unit raise OpStructureError {
  match origin {
    Some(version) if version.agent == "" || version.seq < 0 =>
      raise OpStructureError::InvalidOriginIdentity
    _ => ()
  }
}

///|
fn validate_single_scalar_insert(text : String) -> Unit raise OpStructureError {
  let code_unit_count = text.length()
  if code_unit_count == 0 {
    raise OpStructureError::EmptyInsert
  }
  let first = text[0].to_int()
  let scalar_width = if first >= 0xD800 && first <= 0xDBFF {
    if code_unit_count < 2 {
      raise OpStructureError::MalformedInsertUtf16
    }
    let second = text[1].to_int()
    if second < 0xDC00 || second > 0xDFFF {
      raise OpStructureError::MalformedInsertUtf16
    }
    2
  } else if first >= 0xDC00 && first <= 0xDFFF {
    raise OpStructureError::MalformedInsertUtf16
  } else {
    1
  }
  if scalar_width != code_unit_count {
    raise OpStructureError::MultiScalarInsert
  }
}
