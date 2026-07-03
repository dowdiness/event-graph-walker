///| Sync operations for TextState.

///|

///| ## Usage Pattern

///|

///| The sync API is asymmetric by design:

///|

///| - **Export**: Use `export_all()` for initial sync, `export_since(peer_version)` for deltas

///|

///| - **Import**: Use `apply(message)` for all incoming messages

///|

///| There is no `import_filtered()` because filtering happens on the **sender** side

///| via `export_since()`. The receiver always applies the full message - the sender

///| is responsible for sending only the operations the receiver needs.

///|

///| ```

///| // Peer A sends to Peer B

///| let message = peer_a.sync().export_since(peer_b_version)

///| peer_b.sync().apply(message)

///| ```

///| A message containing operation runs and version info for syncing between peers.

///|
/// Operations are stored as compressed OpRun arrays for efficient serialization.
pub(all) struct SyncMessage {
  priv runs : Array[@core.OpRun]
  priv heads : Array[@core.RawVersion]
} derive(Debug)

///|
/// Check if this message contains no operations.
pub fn SyncMessage::is_empty(self : SyncMessage) -> Bool {
  self.runs.is_empty()
}

///|
/// Get the total number of individual operations across all runs.
pub fn SyncMessage::op_count(self : SyncMessage) -> Int {
  let mut total = 0
  for run in self.runs {
    total = total + run.count
  }
  total
}

///|
/// Encode this message as a JSON string for cross-boundary transport (e.g. JS FFI).
pub fn SyncMessage::to_json_string(self : SyncMessage) -> String {
  let obj : Map[String, Json] = {
    "runs": self.runs.to_json(),
    "heads": self.heads.to_json(),
  }
  Json::object(obj).stringify()
}

///|
/// Decode a SyncMessage from a JSON string produced by `to_json_string`.
pub fn SyncMessage::from_json_string(
  json_str : String,
) -> SyncMessage raise TextError {
  try {
    let json = @json.parse(json_str)
    let obj = match json {
      Json::Object(m) => m
      _ => raise TextError::Internal(detail="Invalid SyncMessage JSON")
    }
    let heads_json = match obj.get("heads") {
      Some(v) => v
      None => Json::null()
    }
    let heads : Array[@core.RawVersion] = @json.from_json(heads_json)
    // Support both new "runs" format and legacy "ops" format
    let runs : Array[@core.OpRun] = match obj.get("runs") {
      Some(v) => @json.from_json(v)
      None =>
        match obj.get("ops") {
          Some(v) => {
            // Legacy format: Array[Op] — wrap each as a singleton OpRun
            let ops : Array[@core.Op] = @json.from_json(v)
            ops.map(fn(op) { @core.OpRun::from_op(op) })
          }
          None => []
        }
    }
    { runs, heads }
  } catch {
    _ => raise TextError::Internal(detail="Invalid SyncMessage JSON")
  }
}

///|
/// Deterministic binary encoding for cryptographic hashing and signing.
///
/// Every field is written in fixed order. Variable-length collections
/// (parents, heads) are sorted by `(agent, seq)` for determinism.
/// Strings use UTF-8 encoding. All lengths are unsigned LEB128 varints.
///
/// This is the canonical form consumed by BFT adapters and other
/// integrity-verification layers — it is NOT a wire format and does
/// not replace `to_json_string` for general sync.
pub fn SyncMessage::to_canonical_bytes(self : SyncMessage) -> Bytes {
  let buf = Buffer()
  write_sync_message(buf, self)
  buf.to_bytes()
}

///| A sync session providing methods to synchronize a TextState with peers.

///|
/// Obtain via `TextState::sync()`.
pub(all) struct SyncSession {
  priv doc : TextState
}

///|
/// Export all operations as a sync message (zero-copy — no decompression).
pub fn SyncSession::export_all(
  self : SyncSession,
) -> SyncMessage raise TextError {
  let inner = self.doc.inner
  let runs = inner.get_all_runs()
  try {
    let heads = inner.get_frontier_raw()
    SyncMessage::{ runs, heads }
  } catch {
    err => raise TextError::from_document_error(err, self.doc.len())
  }
}


///|
/// Export operations since a peer's version
pub fn SyncSession::export_since(
  self : SyncSession,
  peer_version : Version,
) -> SyncMessage raise TextError {
  let inner = self.doc.inner
  let peer_frontier = peer_version.to_frontier()
  let current_frontier = inner.get_frontier()
  let (_, advance_ops) = inner.diff_and_collect(peer_frontier, current_frontier)
  // Re-compress individual ops into runs via Rle::append (auto-merges adjacent)
  let rle : @rle.Rle[@core.OpRun] = @rle.Rle::Rle()
  for op in advance_ops {
    let _ = rle.append(@core.OpRun::from_op(op))
  }
  let runs : Array[@core.OpRun] = []
  for run in rle.iter() {
    runs.push(run)
  }
  try {
    let heads = inner.get_frontier_raw()
    SyncMessage::{ runs, heads }
  } catch {
    err => raise TextError::from_document_error(err, self.doc.len())
  }
}

///|
/// Apply a sync message from a peer
pub fn SyncSession::apply(
  self : SyncSession,
  message : SyncMessage,
) -> Unit raise TextError {
  if message.is_empty() {
    return
  }
  // Expand runs to individual ops for merge_remote
  let ops : Array[@core.Op] = Array::new(capacity=message.op_count())
  for run in message.runs {
    run.decompress_into(ops)
  }
  self.doc.inner.merge_remote(ops, message.heads) catch {
    err => raise TextError::from_document_error(err, self.doc.len())
  }
}

///|
/// Get the current version after sync operations
pub fn SyncSession::current_version(self : SyncSession) -> Version {
  self.doc.version()
}

///| Private helpers for `to_canonical_bytes`.

/// Write a UTF-8 string prefixed with a uvarint byte-length.
fn write_string_utf8(buf : Buffer, s : String) -> Unit {
  let bytes = @utf8.encode(s)
  @bytecodec.write_uvarint(buf, bytes.length().to_uint64())
  buf.write_bytes(bytes)
}

/// Write a single `RawVersion` as (agent, seq).
fn write_raw_version(buf : Buffer, rv : @core.RawVersion) -> Unit {
  write_string_utf8(buf, rv.agent)
  @bytecodec.write_uvarint(buf, rv.seq.to_uint64())
}

/// Sort `RawVersion` array by (agent, seq) for determinism.
fn sort_raw_versions(vs : Array[@core.RawVersion]) -> Array[@core.RawVersion] {
  let sorted = vs.copy()
  sorted.sort_by(fn(a, b) {
    match a.agent.compare(b.agent) {
      0 => a.seq.compare(b.seq)
      other => other
    }
  })
  sorted
}

/// Write a full SyncMessage in canonical binary form.
fn write_sync_message(buf : Buffer, msg : SyncMessage) -> Unit {
  // Runs
  @bytecodec.write_uvarint(buf, msg.runs.length().to_uint64())
  for run in msg.runs {
    write_string_utf8(buf, run.agent)
    @bytecodec.write_uvarint(buf, run.start_seq.to_uint64())
    @bytecodec.write_uvarint(buf, run.start_lv.to_uint64())
    @bytecodec.write_uvarint(buf, run.count.to_uint64())
    // Content
    match run.content {
      @core.Inserts(chars) => {
        buf.write_byte(b'\x00')
        @bytecodec.write_uvarint(buf, chars.length().to_uint64())
        for ch in chars {
          buf.write_bytes(@utf8.encode(ch.to_string()))
        }
      }
      @core.Deletes => buf.write_byte(b'\x01')
      @core.Undeletes => buf.write_byte(b'\x02')
    }
    // Parents (sorted)
    let parents = sort_raw_versions(run.parents)
    @bytecodec.write_uvarint(buf, parents.length().to_uint64())
    for p in parents {
      write_raw_version(buf, p)
    }
    // origin_left
    match run.origin_left {
      Some(o) => {
        buf.write_byte(b'\x01')
        write_raw_version(buf, o)
      }
      None => buf.write_byte(b'\x00')
    }
    // origin_right
    match run.origin_right {
      Some(o) => {
        buf.write_byte(b'\x01')
        write_raw_version(buf, o)
      }
      None => buf.write_byte(b'\x00')
    }
  }
  // Heads (sorted)
  let heads = sort_raw_versions(msg.heads)
  @bytecodec.write_uvarint(buf, heads.length().to_uint64())
  for h in heads {
    write_raw_version(buf, h)
  }
}
