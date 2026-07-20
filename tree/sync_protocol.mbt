///| Strict façade-specific tree wire envelopes.

///|
let tree_version_format : String = "event-graph-walker/tree-version"

///|
let tree_sync_format : String = "event-graph-walker/tree-sync"

///|
fn exact_tree_fields(
  object : Map[String, Json],
  expected : Array[String],
) -> Bool {
  if object.length() != expected.length() {
    return false
  }
  for key in object.keys() {
    let mut found = false
    for expected_key in expected {
      if key == expected_key {
        found = true
      }
    }
    if !found {
      return false
    }
  }
  true
}

///|
fn check_tree_encoded_size(
  size : Int,
  limits : @sync.Limits,
) -> Unit raise TreeError {
  let limit = limits.max_encoded_bytes()
  if size > limit {
    raise TreeError::SyncFailed(
      @sync.Failure::LimitExceeded(
        kind=@sync.LimitKind::EncodedBytes,
        limit~,
        actual=size,
      ),
    )
  }
}

///|
fn tree_json_size(
  json_string : String,
  limits : @sync.Limits,
) -> Int raise TreeError {
  let mut index = 0
  while index < json_string.length() {
    let value = json_string[index].to_int()
    if value >= 0xD800 && value <= 0xDBFF {
      if index + 1 >= json_string.length() {
        raise TreeError::SyncFailed(
          @sync.Failure::MalformedMessage(detail="invalid tree JSON"),
        )
      }
      let low = json_string[index + 1].to_int()
      if low < 0xDC00 || low > 0xDFFF {
        raise TreeError::SyncFailed(
          @sync.Failure::MalformedMessage(detail="invalid tree JSON"),
        )
      }
      index = index + 2
    } else if value >= 0xDC00 && value <= 0xDFFF {
      raise TreeError::SyncFailed(
        @sync.Failure::MalformedMessage(detail="invalid tree JSON"),
      )
    } else {
      index = index + 1
    }
  }
  let size = @utf8.encode(json_string).length()
  check_tree_encoded_size(size, limits)
  size
}

///|
pub fn SyncMessage::is_empty(self : SyncMessage) -> Bool {
  self.inner.is_empty()
}

///|
pub fn SyncMessage::op_count(self : SyncMessage) -> Int {
  self.inner.op_count()
}

///|
pub fn SyncMessage::to_json_string(self : SyncMessage) -> String {
  let payload = @json.parse(self.inner.to_json_string()) catch {
    _ => abort("container SyncMessage produced invalid JSON")
  }
  Json::object({
    "schema": (1).to_json(),
    "format": tree_sync_format.to_json(),
    "payload": payload,
  }).stringify()
}

///|
fn decode_tree_sync_json(
  json_string : String,
  limits : @sync.Limits,
  decode_payload : (String) -> @container.SyncMessage raise @container.DocumentError,
) -> SyncMessage raise TreeError {
  let encoded_size = tree_json_size(json_string, limits)
  try {
    let root = @json.parse(json_string)
    let object = match root {
      Json::Object(value) => value
      _ => fail("tree sync envelope must be an object")
    }
    guard exact_tree_fields(object, ["schema", "format", "payload"]) else {
      fail("tree sync envelope contains missing or unknown fields")
    }
    let schema : Int = @json.from_json(
      object.get("schema").unwrap_or(Json::null()),
    )
    let format : String = @json.from_json(
      object.get("format").unwrap_or(Json::null()),
    )
    guard schema == 1 && format == tree_sync_format else {
      fail("unsupported tree sync envelope")
    }
    let inner = map_document_error(fn() raise @container.DocumentError {
      decode_payload(object.get("payload").unwrap_or(Json::null()).stringify())
    })
    guard !inner.has_text_operations() else {
      raise TreeError::SyncFailed(
        @sync.Failure::InvalidContent(
          detail="tree messages cannot contain text operations",
        ),
      )
    }
    SyncMessage(inner, Some(encoded_size))
  } catch {
    TreeError::EmptyReplicaId => raise TreeError::EmptyReplicaId
    TreeError::TargetNotFound => raise TreeError::TargetNotFound
    TreeError::ParentNotFound => raise TreeError::ParentNotFound
    TreeError::CycleDetected => raise TreeError::CycleDetected
    TreeError::SyncFailed(failure) => raise TreeError::SyncFailed(failure)
    TreeError::Internal(detail~) => raise TreeError::Internal(detail~)
    _ =>
      raise TreeError::SyncFailed(
        @sync.Failure::MalformedMessage(detail="invalid tree sync JSON"),
      )
  }
}

///|
/// Decode a tree synchronization message using the default protocol limits.
///
/// Use `TreeState::sync().decode_json(...)` when decoding for a receiver with
/// explicitly configured synchronization limits.
pub fn SyncMessage::from_json_string(
  json_string : String,
) -> SyncMessage raise TreeError {
  decode_tree_sync_json(json_string, @sync.Limits::default(), payload => {
    @container.SyncMessage::from_json_string(payload)
  })
}

///|
/// Decode tree synchronization JSON using this receiver's configured limits.
pub fn SyncSession::decode_json(
  self : SyncSession,
  json_string : String,
) -> SyncMessage raise TreeError {
  decode_tree_sync_json(json_string, self.state.sync_limits, payload => {
    self.state.document.sync().decode_json(payload)
  })
}

///|
pub fn Version::to_json_string(self : Version) -> String {
  let payload = @json.parse(self.inner.to_json_string()) catch {
    _ => abort("container Version produced invalid JSON")
  }
  Json::object({
    "schema": (1).to_json(),
    "format": tree_version_format.to_json(),
    "payload": payload,
  }).stringify()
}

///|
pub fn Version::from_json_string(
  json_string : String,
) -> Version raise TreeError {
  let _ = tree_json_size(json_string, @sync.Limits::default())
  try {
    let root = @json.parse(json_string)
    let object = match root {
      Json::Object(value) => value
      _ => fail("tree version envelope must be an object")
    }
    guard exact_tree_fields(object, ["schema", "format", "payload"]) else {
      fail("tree version envelope contains missing or unknown fields")
    }
    let schema : Int = @json.from_json(
      object.get("schema").unwrap_or(Json::null()),
    )
    let format : String = @json.from_json(
      object.get("format").unwrap_or(Json::null()),
    )
    guard schema == 1 && format == tree_version_format else {
      fail("unsupported tree version envelope")
    }
    Version(
      map_document_error(fn() raise @container.DocumentError {
        @container.Version::from_json_string(
          object.get("payload").unwrap_or(Json::null()).stringify(),
        )
      }),
    )
  } catch {
    TreeError::EmptyReplicaId => raise TreeError::EmptyReplicaId
    TreeError::TargetNotFound => raise TreeError::TargetNotFound
    TreeError::ParentNotFound => raise TreeError::ParentNotFound
    TreeError::CycleDetected => raise TreeError::CycleDetected
    TreeError::SyncFailed(failure) => raise TreeError::SyncFailed(failure)
    TreeError::Internal(detail~) => raise TreeError::Internal(detail~)
    _ =>
      raise TreeError::SyncFailed(
        @sync.Failure::MalformedMessage(detail="invalid tree version JSON"),
      )
  }
}

///|
fn write_tree_uvarint(buffer : Buffer, value : Int) -> Unit {
  let mut remaining = value
  while remaining >= 0x80 {
    buffer.write_byte(((remaining & 0x7F) | 0x80).to_byte())
    remaining = remaining >> 7
  }
  buffer.write_byte(remaining.to_byte())
}

///|
pub fn SyncMessage::to_canonical_bytes(self : SyncMessage) -> Bytes {
  let buffer = Buffer()
  buffer.write_bytes(b"event-graph-walker:tree-sync:v1")
  let inner = self.inner.to_canonical_bytes()
  write_tree_uvarint(buffer, inner.length())
  buffer.write_bytes(inner)
  buffer.to_bytes()
}
