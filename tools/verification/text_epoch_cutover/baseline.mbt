///|
pub(all) suberror ProtocolError {
  InvalidChunkSize(Int)
  InvalidDocumentId
  InvalidEpoch(Int)
  InvalidSubmissionIdentity
  StaleEpoch(expected~ : Int, actual~ : Int)
  Quiescing(Int)
  PendingOperations(Int)
  SubmissionConflict(client_instance_id~ : String, sequence~ : Int)
  InvalidCursor(requested~ : Int, current~ : Int)
  CutoverAlreadyStarted(Int)
  CutoverNotStarted(Int)
  BaselineSourceMismatch
  TextFailure(@text.TextError)
}

///|
fn[T] map_text(action : () -> T raise @text.TextError) -> T raise ProtocolError {
  action() catch {
    error => raise ProtocolError::TextFailure(error)
  }
}

///|
fn chunks_by_scalar(text : String, chunk_scalars : Int) -> Array[String] {
  let chunks : Array[String] = []
  let builder = StringBuilder()
  let mut scalar_count = 0
  for scalar in text {
    builder.write_char(scalar)
    scalar_count += 1
    if scalar_count == chunk_scalars {
      chunks.push(builder.to_string())
      builder.reset()
      scalar_count = 0
    }
  }
  if scalar_count > 0 {
    chunks.push(builder.to_string())
  }
  chunks
}

///|
/// A fully built fresh-generation baseline and its canonical schema-2 pages.
///
/// Construction is isolated from any live server. Callers publish the baseline
/// only after `build` returns successfully.
pub struct Baseline {
  priv document : @text.TextState
  priv pages : Array[String]
  priv version : @text.Version
}

///|
pub fn Baseline::build(
  visible_text : String,
  baseline_agent~ : String,
  chunk_scalars~ : Int,
) -> Baseline raise ProtocolError {
  if chunk_scalars <= 0 {
    raise ProtocolError::InvalidChunkSize(chunk_scalars)
  }
  let document = map_text(() => @text.TextState::new(baseline_agent))
  let validator = map_text(() => {
    @text.TextState::new("epoch-baseline-validator")
  })
  let pages : Array[String] = []
  for chunk in chunks_by_scalar(visible_text, chunk_scalars) {
    let before = document.version()
    map_text(() => document.insert(@text.Pos::at(document.len()), chunk))
    let message = map_text(() => document.sync().export_since(before))
    ignore(map_text(() => validator.sync().apply(message)))
    pages.push(message.to_json_string())
  }
  { document, pages, version: document.version() }
}

///|
pub fn Baseline::page_count(self : Baseline) -> Int {
  self.pages.length()
}

///|
pub fn Baseline::version(self : Baseline) -> @text.Version {
  self.version
}

///|
pub fn Baseline::text(self : Baseline) -> String {
  self.document.text()
}

///|
pub fn Baseline::page_json(self : Baseline) -> Array[String] {
  self.pages.copy()
}

///|
pub fn Baseline::apply_to(
  self : Baseline,
  receiver_agent : String,
) -> @text.TextState raise ProtocolError {
  let receiver = map_text(() => @text.TextState::new(receiver_agent))
  for encoded in self.pages {
    let message = map_text(() => @text.SyncMessage::from_json_string(encoded))
    ignore(map_text(() => receiver.sync().apply(message)))
  }
  receiver
}
