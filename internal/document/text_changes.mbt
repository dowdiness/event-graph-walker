///| Projection-owned, sequential UTF-16 edits. No snapshot diffing.

///|
pub(all) struct VisibleTextEdit {
  start : Int32
  end : Int32
  text : String
}

///|
priv struct PendingTextEdit {
  mut start : Int32
  mut end : Int32
  text : StringBuilder
  prepended : Array[String]
  mut inserted_length : Int32
}

///|
priv struct TextChangeCollector {
  edits : Array[VisibleTextEdit]
  mut pending : PendingTextEdit?
  mut valid : Bool
}

///|
fn TextChangeCollector::flush(self : TextChangeCollector) -> Unit {
  match self.pending {
    Some(edit) => {
      let text = StringBuilder()
      for i = edit.prepended.length() - 1; i >= 0; i = i - 1 {
        text.write_string(edit.prepended[i])
      }
      text.write_string(edit.text.to_string())
      self.edits.push({
        start: edit.start,
        end: edit.end,
        text: text.to_string(),
      })
    }
    None => ()
  }
  self.pending = None
}

///|
fn TextChangeCollector::insert(
  self : TextChangeCollector,
  position : Int32,
  text : String,
) -> Unit {
  match self.pending {
    Some(edit) if position == edit.start + edit.inserted_length => {
      edit.text.write_string(text)
      edit.inserted_length += text.length()
    }
    Some(edit) if position == edit.start => {
      edit.prepended.push(text)
      edit.inserted_length += text.length()
    }
    _ => {
      self.flush()
      let builder = StringBuilder()
      builder.write_string(text)
      self.pending = Some({
        start: position,
        end: position,
        text: builder,
        prepended: [],
        inserted_length: text.length(),
      })
    }
  }
}

///|
fn TextChangeCollector::delete(
  self : TextChangeCollector,
  start : Int32,
  end : Int32,
) -> Unit {
  match self.pending {
    Some(edit) if edit.inserted_length == 0 && start == edit.start =>
      edit.end += end - start
    Some(edit) if edit.inserted_length == 0 && end == edit.start =>
      edit.start = start
    _ => {
      self.flush()
      self.pending = Some({
        start,
        end,
        text: StringBuilder(),
        prepended: [],
        inserted_length: 0,
      })
    }
  }
}

///|
/// Internal synchronous publication boundary, owned by the editor facade.
pub fn Document::begin_text_change(self : Document) -> Unit raise DocumentError {
  self.ensure_projection_ready()
  ignore(self.indexed_state.ensure(self.tree))
  if self.text_changes is Some(_) {
    abort("nested text change publication")
  }
  self.text_changes = Some({ edits: [], pending: None, valid: true, })
}

///|
/// None invalidates the consumer; it never requests a snapshot fallback.
pub fn Document::finish_text_change(self : Document) -> Array[VisibleTextEdit]? {
  let collector = self.text_changes.unwrap()
  self.text_changes = None
  if !collector.valid {
    return None
  }
  collector.flush()
  Some(collector.edits)
}

///|
fn Document::invalidate_text_change(self : Document) -> Unit {
  match self.text_changes {
    Some(collector) => collector.valid = false
    None => ()
  }
}
