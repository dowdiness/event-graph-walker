// PROTOTYPE — serialized materialized-state checkpoint versus full replay.
//
// The executable deliberately stays outside the stable text facade. It uses
// the existing Document/Branch/OpLog APIs, plus the prototype-only Fugue tree
// restore seam, to measure a complete optimistic checkpoint path on JS.

///|
struct PrototypeCheckpoint {
  frontier : @core.Frontier
  operations : Array[@core.Op]
  items : Array[@fugue.Item[String]]
}

///|
struct PrototypeRestored {
  branch : @branch.Branch
  oplog : @oplog.OpLog
}

///|
struct PrototypeFixture {
  base_doc : @document.Document
  base_branch : @branch.Branch
  target_frontier : @core.Frontier
  base_ops : Array[@core.Op]
  tail_ops : Array[@core.Op]
  target_ops : Array[@core.Op]
  expected_text : String
  expected_items : Array[(@fugue.Lv, @fugue.Item[String])]
  base_tombstones : Int
  target_tombstones : Int
  target_history_encoded : String
}

///|
struct PrototypeTimingSummary {
  median : Double
  mean : Double
  min : Double
  max : Double
}

///|
fn prototype_source() -> String {
  "# Startup benchmark\n\nSame final document\n"
}

///|
fn prototype_document(cycles : Int) -> @document.Document {
  let source = prototype_source()
  let doc = @document.Document::new("prototype-writer")
  ignore(doc.insert(0, source) catch { _ => abort("prototype insert failed") })
  for i in 0..<cycles {
    let intermediate = source + "intermediate revision " + i.to_string() + "\n"
    ignore(
      doc.replace_range(0, doc.visible_count(), intermediate) catch {
        _ => abort("prototype intermediate replace failed")
      },
    )
    ignore(
      doc.replace_range(0, doc.visible_count(), source) catch {
        _ => abort("prototype final replace failed")
      },
    )
  }
  doc
}

///|
fn prototype_append_cycles(
  doc : @document.Document,
  start : Int,
  end : Int,
) -> Unit {
  let source = prototype_source()
  for i in start..<end {
    let intermediate = source + "intermediate revision " + i.to_string() + "\n"
    ignore(
      doc.replace_range(0, doc.visible_count(), intermediate) catch {
        _ => abort("prototype intermediate replace failed")
      },
    )
    ignore(
      doc.replace_range(0, doc.visible_count(), source) catch {
        _ => abort("prototype final replace failed")
      },
    )
  }
}

///|
fn prototype_tail(operations : Array[@core.Op], start : Int) -> Array[@core.Op] {
  let tail : Array[@core.Op] = []
  for index in start..<operations.length() {
    tail.push(operations[index])
  }
  tail
}

///|
fn prototype_tombstone_count(
  entries : Array[(@fugue.Lv, @fugue.Item[String])],
) -> Int {
  let mut count = 0
  for entry in entries {
    let (_, item) = entry
    if item.deleted {
      count = count + 1
    }
  }
  count
}

///|
fn prototype_fixture() -> PrototypeFixture {
  // Keep the causal-cut source document independent from the target document
  // so operation-record extraction is included in capture timing without the
  // target tail mutating the checkpoint source.
  let base_doc = prototype_document(19)
  let base_frontier = base_doc.get_frontier()
  let base_ops = base_doc.get_all_ops()
  let base_branch = try! base_doc.checkout_branch(base_frontier)
  let base_items = base_branch.inner_tree().get_all_items()
  let base_tombstones = prototype_tombstone_count(base_items)

  let doc = prototype_document(19)
  prototype_append_cycles(doc, 19, 20)
  let target_frontier = doc.get_frontier()
  let target_ops = doc.get_all_ops()
  let tail_ops = prototype_tail(target_ops, base_ops.length())
  let target_branch = try! doc.checkout_branch(target_frontier)
  let expected_text = target_branch.to_text()
  let expected_items = target_branch.inner_tree().get_all_items()
  let target_tombstones = prototype_tombstone_count(expected_items)
  {
    base_doc,
    base_branch,
    target_frontier,
    base_ops,
    tail_ops,
    target_ops,
    expected_text,
    expected_items,
    base_tombstones,
    target_tombstones,
    target_history_encoded: prototype_encode_history(
      target_ops, target_frontier,
    ),
  }
}

///|
fn prototype_object(value : Json) -> Map[String, Json] {
  match value {
    Json::Object(object) => object
    _ => abort("prototype checkpoint expected a JSON object")
  }
}

///|
fn prototype_field(object : Map[String, Json], key : String) -> Json {
  match object.get(key) {
    Some(value) => value
    None => abort("prototype checkpoint missing field: " + key)
  }
}

///|
fn prototype_lv_option_to_json(value : @fugue.Lv?) -> Json {
  match value {
    None => Json::null()
    Some(lv) => lv.0.to_json()
  }
}

///|
fn prototype_side_to_json(side : @fugue.Side) -> Json {
  match side {
    @fugue.Side::Left => "left".to_json()
    @fugue.Side::Right => "right".to_json()
  }
}

///|
fn prototype_state_to_json(state : @fugue.ItemState) -> Json {
  match state {
    @fugue.ItemState::NotInserted => "not_inserted".to_json()
    @fugue.ItemState::Inserted => "inserted".to_json()
    @fugue.ItemState::Deleted => "deleted".to_json()
    @fugue.ItemState::Retreated => "retreated".to_json()
  }
}

///|
fn prototype_encode_op(op : @core.Op) -> Json {
  let content = match op.content() {
    @core.Insert(text) =>
      Json::object({ "kind": "insert".to_json(), "text": text.to_json() })
    @core.Delete => Json::object({ "kind": "delete".to_json() })
    @core.Undelete => Json::object({ "kind": "undelete".to_json() })
  }
  Json::object({
    // Keep LV as well as the stable agent/sequence identity so this snapshot
    // records the exact admitted operation record, not only its payload.
    "lv": op.lv().to_json(),
    "parents": op.parents().to_json(),
    "agent": op.agent().to_json(),
    "seq": op.seq().to_json(),
    "content": content,
    "origin_left": op.origin_left().to_json(),
    "origin_right": op.origin_right().to_json(),
  })
}

///|
fn prototype_encode_item(item : @fugue.Item[String]) -> Json {
  Json::object({
    "id": item.id.0.to_json(),
    "content": item.content.to_json(),
    "parent": prototype_lv_option_to_json(item.parent),
    "side": prototype_side_to_json(item.side),
    // These fields are intentionally redundant with ItemState. The checkpoint
    // must retain both the tombstone bit and the LWW winner metadata.
    "deleted": item.deleted.to_json(),
    "deleted_ts": item.deleted_ts.to_json(),
    "deleted_agent": item.deleted_agent.to_json(),
    "deleted_is_undelete": item.deleted_is_undelete.to_json(),
    "state": prototype_state_to_json(item.state),
    "delete_count": item.delete_count.to_json(),
    "timestamp": item.timestamp.0.to_json(),
    "agent": item.agent.0.to_json(),
  })
}

///|
fn prototype_encode_history(
  operations : Array[@core.Op],
  frontier : @core.Frontier,
) -> String {
  let encoded_operations : Array[Json] = []
  for op in operations {
    encoded_operations.push(prototype_encode_op(op))
  }
  Json::object({
    "schema": (1).to_json(),
    "frontier": frontier.to_json(),
    "operations": encoded_operations.to_json(),
  }).stringify()
}

///|
fn prototype_capture_checkpoint(
  branch : @branch.Branch,
  frontier : @core.Frontier,
  source_doc : @document.Document,
) -> String {
  // Expand the complete admitted operation records inside the timed capture
  // stage rather than charging only JSON formatting.
  let operations = source_doc.get_all_ops()
  let entries = branch.inner_tree().get_all_items()
  let items : Array[Json] = []
  for entry in entries {
    let (_, item) = entry
    items.push(prototype_encode_item(item))
  }
  let encoded_operations : Array[Json] = []
  for op in operations {
    encoded_operations.push(prototype_encode_op(op))
  }
  Json::object({
    "schema": (1).to_json(),
    "frontier": frontier.to_json(),
    "operations": encoded_operations.to_json(),
    "items": items.to_json(),
  }).stringify()
}

///|
fn prototype_decode_op(value : Json) -> @core.Op {
  let object = prototype_object(value)
  let lv : Int = try! @json.from_json(prototype_field(object, "lv"))
  let parents : Array[@core.RawVersion] = try! @json.from_json(
    prototype_field(object, "parents"),
  )
  let agent : String = try! @json.from_json(prototype_field(object, "agent"))
  let seq : Int = try! @json.from_json(prototype_field(object, "seq"))
  let content_object = prototype_object(prototype_field(object, "content"))
  let kind : String = try! @json.from_json(
    prototype_field(content_object, "kind"),
  )
  let origin_left : @core.RawVersion? = try! @json.from_json(
    prototype_field(object, "origin_left"),
  )
  let origin_right : @core.RawVersion? = try! @json.from_json(
    prototype_field(object, "origin_right"),
  )
  match kind {
    "insert" => {
      let text : String = try! @json.from_json(
        prototype_field(content_object, "text"),
      )
      @core.Op::new_insert(
        lv, parents, agent, seq, text, origin_left, origin_right,
      )
    }
    "delete" => {
      if origin_right is Some(_) {
        abort("prototype delete unexpectedly has a right origin")
      }
      @core.Op::new_delete(lv, parents, agent, seq, origin_left)
    }
    "undelete" => {
      if origin_right is Some(_) {
        abort("prototype undelete unexpectedly has a right origin")
      }
      @core.Op::new_undelete(lv, parents, agent, seq, origin_left)
    }
    _ => abort("prototype checkpoint has an unknown operation kind")
  }
}

///|
fn prototype_decode_item(value : Json) -> @fugue.Item[String] {
  let object = prototype_object(value)
  let id : Int = try! @json.from_json(prototype_field(object, "id"))
  let content : String = try! @json.from_json(
    prototype_field(object, "content"),
  )
  let parent : @fugue.Lv? = match prototype_field(object, "parent") {
    Json::Null => None
    Json::Number(_, ..) => {
      let value : Int = try! @json.from_json(prototype_field(object, "parent"))
      Some(@fugue.Lv(value))
    }
    _ => abort("prototype checkpoint has an invalid item parent")
  }
  let side_name : String = try! @json.from_json(prototype_field(object, "side"))
  let deleted : Bool = try! @json.from_json(prototype_field(object, "deleted"))
  let deleted_ts : Int = try! @json.from_json(
    prototype_field(object, "deleted_ts"),
  )
  let deleted_agent : String = try! @json.from_json(
    prototype_field(object, "deleted_agent"),
  )
  let deleted_is_undelete : Bool = try! @json.from_json(
    prototype_field(object, "deleted_is_undelete"),
  )
  let state_name : String = try! @json.from_json(
    prototype_field(object, "state"),
  )
  let delete_count : Int = try! @json.from_json(
    prototype_field(object, "delete_count"),
  )
  let timestamp : Int = try! @json.from_json(
    prototype_field(object, "timestamp"),
  )
  let agent_name : String = try! @json.from_json(
    prototype_field(object, "agent"),
  )
  @fugue.prototype_item_from_parts(
    id, content, parent, side_name, deleted, deleted_ts, deleted_agent, deleted_is_undelete,
    state_name, delete_count, timestamp, agent_name,
  )
}

///|
fn prototype_decode_operations(object : Map[String, Json]) -> Array[@core.Op] {
  let operation_values : Array[Json] = try! @json.from_json(
    prototype_field(object, "operations"),
  )
  let operations : Array[@core.Op] = []
  for value in operation_values {
    operations.push(prototype_decode_op(value))
  }
  operations
}

///|
fn prototype_restore_oplog(operations : Array[@core.Op]) -> @oplog.OpLog {
  let oplog = @oplog.OpLog::new("prototype-checkpoint-restorer")
  for op in operations {
    ignore(
      oplog.apply_remote(op) catch {
        _ => abort("prototype checkpoint operation admission failed")
      },
    )
  }
  if oplog.op_count() != operations.length() {
    abort("prototype checkpoint operation count changed during restore")
  }
  let restored_operations = oplog.get_all_ops()
  if !prototype_operations_equal(restored_operations, operations) {
    abort("prototype checkpoint operation records changed during restore")
  }
  oplog
}

///|
fn prototype_decode_checkpoint(encoded : String) -> PrototypeCheckpoint {
  let root = prototype_object(try! @json.parse(encoded))
  let schema : Int = try! @json.from_json(prototype_field(root, "schema"))
  if schema != 1 {
    abort("prototype checkpoint has an unsupported schema")
  }
  let frontier : @core.Frontier = try! @json.from_json(
    prototype_field(root, "frontier"),
  )
  let operations = prototype_decode_operations(root)
  let item_values : Array[Json] = try! @json.from_json(
    prototype_field(root, "items"),
  )
  let items : Array[@fugue.Item[String]] = []
  for value in item_values {
    items.push(prototype_decode_item(value))
  }
  { frontier, operations, items }
}

///|
fn prototype_restore_checkpoint(
  checkpoint : PrototypeCheckpoint,
) -> PrototypeRestored {
  // Reconstruct the causal graph and full admitted log from the serialized
  // records. The materialized tree is restored separately, then joined at the
  // checkpoint frontier. This is the causal/log reconstruction cost measured
  // by the decode + restore row.
  let oplog = prototype_restore_oplog(checkpoint.operations)
  let tree = @fugue.FugueTree::prototype_restore_from_items(checkpoint.items)
  let branch = @branch.Branch::from_tree_and_oplog(tree, oplog)
  if !branch.at_frontier(checkpoint.frontier) {
    abort("prototype checkpoint frontier changed during restore")
  }
  { branch, oplog }
}

///|
fn prototype_full_replay_from_history(
  encoded : String,
  frontier : @core.Frontier,
) -> @branch.Branch {
  let root = prototype_object(try! @json.parse(encoded))
  let schema : Int = try! @json.from_json(prototype_field(root, "schema"))
  if schema != 1 {
    abort("prototype history has an unsupported schema")
  }
  let operations = prototype_decode_operations(root)
  let oplog = prototype_restore_oplog(operations)
  try! @branch.Branch::checkout(oplog, frontier)
}

///|
fn prototype_raw_versions_equal(
  lhs : Array[@core.RawVersion],
  rhs : Array[@core.RawVersion],
) -> Bool {
  if lhs.length() != rhs.length() {
    return false
  }
  for index in 0..<lhs.length() {
    if lhs[index] != rhs[index] {
      return false
    }
  }
  true
}

///|
fn prototype_optional_raw_versions_equal(
  lhs : @core.RawVersion?,
  rhs : @core.RawVersion?,
) -> Bool {
  match (lhs, rhs) {
    (None, None) => true
    (Some(lhs), Some(rhs)) => lhs == rhs
    _ => false
  }
}

///|
fn prototype_operations_equal(
  lhs : Array[@core.Op],
  rhs : Array[@core.Op],
) -> Bool {
  if lhs.length() != rhs.length() {
    return false
  }
  for index in 0..<lhs.length() {
    let left = lhs[index]
    let right = rhs[index]
    if left.lv() != right.lv() ||
      left.agent() != right.agent() ||
      left.seq() != right.seq() ||
      !prototype_raw_versions_equal(left.parents(), right.parents()) ||
      !prototype_optional_raw_versions_equal(
        left.origin_left(),
        right.origin_left(),
      ) ||
      !prototype_optional_raw_versions_equal(
        left.origin_right(),
        right.origin_right(),
      ) ||
      left.content() != right.content() {
      return false
    }
  }
  true
}

///|
fn prototype_items_equal(
  lhs : Array[(@fugue.Lv, @fugue.Item[String])],
  rhs : Array[(@fugue.Lv, @fugue.Item[String])],
) -> Bool {
  if lhs.length() != rhs.length() {
    return false
  }
  for index in 0..<lhs.length() {
    let (left_lv, left) = lhs[index]
    let (right_lv, right) = rhs[index]
    if left_lv != right_lv ||
      left.id != right.id ||
      left.content != right.content ||
      left.parent != right.parent ||
      left.side != right.side ||
      left.deleted != right.deleted ||
      left.deleted_ts != right.deleted_ts ||
      left.deleted_agent != right.deleted_agent ||
      left.deleted_is_undelete != right.deleted_is_undelete ||
      left.state != right.state ||
      left.delete_count != right.delete_count ||
      left.timestamp != right.timestamp ||
      left.agent != right.agent {
      return false
    }
  }
  true
}

///|
fn prototype_timing_summary(values : Array[Double]) -> PrototypeTimingSummary {
  let sorted = values.copy()
  sorted.sort()
  let mut total = 0.0
  for value in values {
    total = total + value
  }
  let length = values.length()
  let median = if length % 2 == 1 {
    sorted[length / 2]
  } else {
    (sorted[length / 2 - 1] + sorted[length / 2]) / 2.0
  }
  {
    median,
    mean: total / length.to_double(),
    min: sorted[0],
    max: sorted[length - 1],
  }
}

///|
fn prototype_print_timing(
  name : String,
  values : Array[Double],
) -> PrototypeTimingSummary {
  let summary = prototype_timing_summary(values)
  println(
    "\{name}: median_us=\{summary.median.to_string()}, " +
    "mean_us=\{summary.mean.to_string()}, " +
    "min_us=\{summary.min.to_string()}, " +
    "max_us=\{summary.max.to_string()}, " +
    "samples=\{values.length().to_string()}",
  )
  summary
}

///|
fn prototype_warmup(fixture : PrototypeFixture) -> Unit {
  let encoded = prototype_capture_checkpoint(
    fixture.base_branch,
    fixture.base_branch.get_frontier(),
    fixture.base_doc,
  )
  let checkpoint = prototype_decode_checkpoint(encoded)
  let restored = prototype_restore_checkpoint(checkpoint)
  let final_branch = try! restored.branch.merge_remote_ops(fixture.tail_ops)
  ignore(final_branch.to_text())
}

///|
fn main {
  let fixture = prototype_fixture()
  let sample_count = 7
  // Warm the JS runtime and the MoonBit-generated code before recording the
  // deterministic repeated batch. No fixture construction is timed.
  for _ in 0..<2 {
    prototype_warmup(fixture)
  }

  let full_replay_us : Array[Double] = []
  let capture_encode_us : Array[Double] = []
  let decode_restore_us : Array[Double] = []
  let tail_apply_us : Array[Double] = []
  let checkpoint_reopen_us : Array[Double] = []
  let total_checkpoint_us : Array[Double] = []
  let mut checkpoint_encoded_bytes = 0
  let mut final_text_equivalent = true
  let mut final_operation_count_equivalent = true
  let mut final_operation_records_equivalent = true
  let mut final_materialized_state_equivalent = true

  for _ in 0..<sample_count {
    let full_start = @bench.monotonic_clock_start()
    let full_branch = prototype_full_replay_from_history(
      fixture.target_history_encoded,
      fixture.target_frontier,
    )
    let full_elapsed = @bench.monotonic_clock_end(full_start)
    full_replay_us.push(full_elapsed)
    if full_branch.to_text() != fixture.expected_text {
      final_text_equivalent = false
    }
    if !prototype_items_equal(
        full_branch.inner_tree().get_all_items(),
        fixture.expected_items,
      ) {
      final_materialized_state_equivalent = false
    }

    let capture_start = @bench.monotonic_clock_start()
    let encoded = prototype_capture_checkpoint(
      fixture.base_branch,
      fixture.base_branch.get_frontier(),
      fixture.base_doc,
    )
    let capture_elapsed = @bench.monotonic_clock_end(capture_start)
    capture_encode_us.push(capture_elapsed)
    if checkpoint_encoded_bytes == 0 {
      checkpoint_encoded_bytes = @utf8.encode(encoded).length()
    }

    let restore_start = @bench.monotonic_clock_start()
    let checkpoint = prototype_decode_checkpoint(encoded)
    let restored = prototype_restore_checkpoint(checkpoint)
    let restore_elapsed = @bench.monotonic_clock_end(restore_start)
    decode_restore_us.push(restore_elapsed)

    let tail_start = @bench.monotonic_clock_start()
    let final_branch = try! restored.branch.merge_remote_ops(fixture.tail_ops)
    let tail_elapsed = @bench.monotonic_clock_end(tail_start)
    tail_apply_us.push(tail_elapsed)
    checkpoint_reopen_us.push(restore_elapsed + tail_elapsed)
    total_checkpoint_us.push(capture_elapsed + restore_elapsed + tail_elapsed)

    if final_branch.to_text() != fixture.expected_text {
      final_text_equivalent = false
    }
    if restored.oplog.op_count() != fixture.target_ops.length() {
      final_operation_count_equivalent = false
    }
    if !prototype_operations_equal(
        restored.oplog.get_all_ops(),
        fixture.target_ops,
      ) {
      final_operation_records_equivalent = false
    }
    if !prototype_items_equal(
        final_branch.inner_tree().get_all_items(),
        fixture.expected_items,
      ) {
      final_materialized_state_equivalent = false
    }
  }

  let full_summary = prototype_print_timing("full replay", full_replay_us)
  ignore(
    prototype_print_timing("checkpoint capture + encode", capture_encode_us),
  )
  ignore(
    prototype_print_timing("checkpoint decode + restore", decode_restore_us),
  )
  ignore(prototype_print_timing("tail apply", tail_apply_us))
  let reopen_summary = prototype_print_timing(
    "checkpoint decode + restore + tail", checkpoint_reopen_us,
  )
  let total_summary = prototype_print_timing(
    "total checkpoint path", total_checkpoint_us,
  )

  println(
    "fixture: target_operations=" +
    fixture.target_ops.length().to_string() +
    ", checkpoint_operations=" +
    fixture.base_ops.length().to_string() +
    ", tail_operations=" +
    fixture.tail_ops.length().to_string() +
    ", checkpoint_encoded_bytes=" +
    checkpoint_encoded_bytes.to_string(),
  )
  println(
    "state: checkpoint_tombstones=" +
    fixture.base_tombstones.to_string() +
    ", final_tombstones=" +
    fixture.target_tombstones.to_string() +
    ", history_encoded_bytes=" +
    @utf8.encode(fixture.target_history_encoded).length().to_string(),
  )
  println(
    "median_checkpoint_cost_over_full_replay=" +
    (reopen_summary.median / full_summary.median).to_string() +
    "x (reopen), total_with_capture=" +
    (total_summary.median / full_summary.median).to_string() +
    "x",
  )
  println(
    "equivalence: final_text=" +
    final_text_equivalent.to_string() +
    ", operation_count=" +
    final_operation_count_equivalent.to_string() +
    ", operation_records=" +
    final_operation_records_equivalent.to_string() +
    ", materialized_tree_and_tombstones=" +
    final_materialized_state_equivalent.to_string(),
  )
}
