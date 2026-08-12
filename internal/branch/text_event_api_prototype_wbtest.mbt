///| Paper-aligned canonical text-event API prototype.
/// Events store document edits and causal parents, not Fugue origins.

///|
test "paper api: canonical events are document edits" {
  let log = TextEventLog::new("text-api-user")
  let first = try! log.append_insert(0, "a")
  let second = try! log.append_insert(1, "b")

  match (first.edit, second.edit) {
    (TextInsert(first_pos, first_text), TextInsert(second_pos, second_text)) => {
      assert_eq(first_pos, 0)
      assert_eq(first_text, "a")
      assert_eq(second_pos, 1)
      assert_eq(second_text, "b")
    }
    _ => fail("canonical event was not a document edit")
  }
  assert_eq(log.checkout_current(), "ab")
}

///|
test "paper api: delete edits use positions in their parent document" {
  let log = TextEventLog::new("text-api-delete")
  ignore(try! log.append_insert(0, "a"))
  ignore(try! log.append_insert(1, "b"))
  ignore(try! log.append_insert(2, "c"))
  let deletion = try! log.append_delete(1)

  match deletion.edit {
    TextDelete(pos) => assert_eq(pos, 1)
    TextInsert(_, _) => fail("delete event became an insert")
  }
  assert_eq(log.checkout_current(), "ac")
}

///|
test "paper api: concurrent document edits merge deterministically" {
  let left = TextEventLog::new("user-a")
  let right = TextEventLog::new("user-b")
  ignore(try! left.append_insert(0, "A"))
  ignore(try! right.append_insert(0, "B"))

  assert_true(left.merge_from(right))
  assert_eq(left.checkout_current(), "AB")
}

///|
test "paper api: concurrent insert and delete use parent positions" {
  let base = TextEventLog::new("text-api-base")
  ignore(try! base.append_insert(0, "a"))
  let left = TextEventLog::new("text-api-left")
  let right = TextEventLog::new("text-api-right")
  assert_true(left.merge_from(base))
  assert_true(right.merge_from(base))
  ignore(try! left.append_insert(1, "L"))
  ignore(try! right.append_delete(0))

  assert_true(left.merge_from(right))
  assert_eq(left.checkout_current(), "L")
}

///|
test "paper api: insertion after tombstone uses next visible anchor" {
  let log = TextEventLog::new("tombstone-anchor")
  ignore(try! log.append_insert(0, "a"))
  ignore(try! log.append_insert(1, "b"))
  ignore(try! log.append_insert(2, "c"))
  ignore(try! log.append_delete(1))
  ignore(try! log.append_insert(1, "x"))
  let trace = log.checkout_trace(log.graph.get_frontier())
  assert_eq(trace.text, "axc")
  assert_eq(trace.insert_right_parents[4], 1)
}

///|
test "paper api: Lamport timestamp orders unequal-time concurrent inserts" {
  let base = TextEventLog::new("timestamp-base")
  ignore(try! base.append_insert(0, "a"))
  let low = TextEventLog::new("z-low")
  let high = TextEventLog::new("a-high")
  assert_true(low.merge_from(base))
  assert_true(high.merge_from(base))

  ignore(try! low.append_insert(0, "L"))
  ignore(try! high.append_insert(1, "z"))
  ignore(try! high.append_delete(1))
  ignore(try! high.append_insert(0, "H"))

  assert_true(low.merge_from(high))
  assert_eq(low.checkout_current(), "LHa")
}

///|
test "paper api: transient order uses Lamport timestamp before agent" {
  let graph = @causal_graph.CausalGraph::new()
  let root = try! graph.add_version([], "root")
  let low = try! graph.add_version([root], "z-low")
  let high_first = try! graph.add_version([root], "a-high")
  let high_second = try! graph.add_version([high_first], "a-high")

  assert_true(!graph.is_ancestor(low, high_second))
  assert_true(!graph.is_ancestor(high_second, low))
  assert_true(text_walker_lv_compare(graph, low, high_second) < 0)
}

///|
test "paper api: fresh writer edits plain text state after merge" {
  let authority = TextEventLog::new("authority")
  ignore(try! authority.append_insert(0, "a"))
  let page = TextEventLog::new("fresh-page")
  ignore(try! page.append_insert(0, "b"))
  assert_true(authority.merge_from(page))

  let fresh_edit = try! authority.append_insert(2, "c")
  match fresh_edit.edit {
    TextInsert(pos, text) => {
      assert_eq(pos, 2)
      assert_eq(text, "c")
    }
    TextDelete(_) => fail("fresh writer edit was not an insert")
  }
  assert_eq(authority.checkout_current(), "abc")
}

///|
test "paper api: pending event admission drains after its parent" {
  let source = TextEventLog::new("pending-source")
  let parent = try! source.append_insert(0, "p")
  let child = try! source.append_insert(1, "c")
  let target = TextEventLog::new("pending-target")

  assert_true(target.merge_event(child))
  assert_eq(target.checkout_current(), "")
  assert_true(target.merge_event(parent))
  assert_eq(target.checkout_current(), "pc")
}

///|
test "paper api: raw text snapshot is separate from transient merge state" {
  let log = TextEventLog::new("snapshot-api")
  ignore(try! log.append_insert(0, "a"))
  let snapshot = TextEventSnapshot::capture(log)
  assert_eq(snapshot.open(), "a")
  assert_eq(snapshot.frontier.length(), 1)

  let remote = TextEventLog::new("snapshot-remote")
  ignore(try! remote.append_insert(0, "b"))
  assert_true(log.merge_from(remote))
  let merged = TextEventSnapshot::capture(log)
  assert_eq(merged.open(), "ab")
}

///|
priv enum TextEventEdit {
  TextInsert(Int, String)
  TextDelete(Int)
} derive(Eq)

///|
priv struct TextEvent {
  id : @core.RawVersion
  parents : Array[@core.RawVersion]
  edit : TextEventEdit
} derive(Eq)

///|
priv struct TextEventLog {
  graph : @causal_graph.CausalGraph
  events : Array[TextEvent]
  mut pending : Array[TextEvent]
  mut text : String
  agent : String
}

///|
priv enum TextAdmission {
  Applied
  Already
  Pending
  Conflict
}

///|
fn TextEventLog::new(agent : String) -> TextEventLog {
  {
    graph: @causal_graph.CausalGraph::new(),
    events: [],
    pending: [],
    text: "",
    agent,
  }
}

///|
fn TextEventLog::append_insert(
  self : TextEventLog,
  position : Int,
  content : String,
) -> TextEvent raise @causal_graph.CausalGraphError {
  self.append(TextInsert(position, content))
}

///|
fn TextEventLog::append_delete(
  self : TextEventLog,
  position : Int,
) -> TextEvent raise @causal_graph.CausalGraphError {
  self.append(TextDelete(position))
}

///|
fn TextEventLog::append(
  self : TextEventLog,
  edit : TextEventEdit,
) -> TextEvent raise @causal_graph.CausalGraphError {
  match edit {
    TextInsert(position, content) => {
      let chars = content.to_array()
      if chars.length() != 1 {
        abort("text event prototype accepts one scalar per insert event")
      }
      let length = self.text.to_array().length()
      if position < 0 || position > length {
        abort("text event insert position is outside the local document")
      }
    }
    TextDelete(position) => {
      let length = self.text.to_array().length()
      if position < 0 || position >= length {
        abort("text event delete position is outside the local document")
      }
    }
  }
  let frontier = self.graph.get_frontier()
  let parents = text_event_raw_frontier(self.graph, frontier)
  let lv = self.graph.add_version(frontier.to_array(), self.agent)
  let id = match self.graph.lv_to_raw(lv) {
    Some(raw) => raw
    None => raise @causal_graph.CausalGraphError::MissingEntry(lv~)
  }
  let event = { id, parents, edit }
  self.events.push(event)
  self.text = text_event_apply_local_edit(self.text, edit)
  event
}

///|
fn text_event_apply_local_edit(text : String, edit : TextEventEdit) -> String {
  let chars = text.to_array()
  match edit {
    TextInsert(position, content) =>
      chars.insert(position, content.to_array()[0])
    TextDelete(position) => ignore(chars.remove(position))
  }
  String::from_array(chars)
}

///|
fn TextEventLog::merge_from(self : TextEventLog, source : TextEventLog) -> Bool {
  for incoming in source.events {
    if !self.merge_event(incoming) {
      return false
    }
  }
  true
}

///|
fn TextEventLog::merge_event(self : TextEventLog, incoming : TextEvent) -> Bool {
  for pending in self.pending {
    if pending.id == incoming.id {
      return pending == incoming
    }
  }
  let before_count = self.graph.op_count()
  let accepted = match self.text_event_try_admit(incoming) {
    Applied => self.text_event_drain_pending()
    Already => true
    Pending => {
      if !self.pending.contains(incoming) {
        self.pending.push(incoming)
      }
      true
    }
    Conflict => false
  }
  if accepted || self.graph.op_count() != before_count {
    self.text = self.checkout(self.graph.get_frontier())
  }
  accepted
}

///|
fn TextEventLog::text_event_try_admit(
  self : TextEventLog,
  incoming : TextEvent,
) -> TextAdmission {
  match self.graph.raw_to_lv(incoming.id) {
    Some(existing_lv) =>
      if self.events[existing_lv].edit == incoming.edit &&
        self.events[existing_lv].parents == incoming.parents {
        Already
      } else {
        Conflict
      }
    None => {
      let parent_lvs : Array[Int] = []
      for parent in incoming.parents {
        match self.graph.raw_to_lv(parent) {
          Some(parent_lv) => parent_lvs.push(parent_lv)
          None => return Pending
        }
      }
      let lv = self.graph.add_version_with_seq(
        parent_lvs,
        incoming.id.agent,
        incoming.id.seq,
      ) catch {
        _ => return Conflict
      }
      if lv != self.events.length() {
        return Conflict
      }
      self.events.push({
        id: incoming.id,
        parents: incoming.parents,
        edit: incoming.edit,
      })
      Applied
    }
  }
}

///|
fn TextEventLog::text_event_drain_pending(self : TextEventLog) -> Bool {
  let mut changed = true
  while changed {
    changed = false
    let remaining : Array[TextEvent] = []
    for pending in self.pending {
      match self.text_event_try_admit(pending) {
        Applied => changed = true
        Already => changed = true
        Pending => remaining.push(pending)
        Conflict => {
          self.pending = remaining
          return false
        }
      }
    }
    self.pending = remaining
  }
  true
}

///|
priv struct TextCheckoutTrace {
  text : String
  insert_left_parents : Array[Int]
  insert_right_parents : Array[Int]
  delete_targets : Array[Int]
}

///|
fn TextEventLog::checkout_trace(
  self : TextEventLog,
  target : @core.Frontier,
) -> TextCheckoutTrace {
  let item_capacity = self.events.length()
  let items_by_lv : Array[TextWalkerItem?] = Array::make(item_capacity, None)
  let ctx : TextWalkerContext = {
    items: [],
    items_by_lv,
    delete_targets: Array::make(item_capacity, -1),
    cur_version: @core.Frontier::from_array([]),
    snapshot: [],
    insert_left_parents: Array::make(item_capacity, -1),
    insert_right_parents: Array::make(item_capacity, -1),
  }
  for lv in self.graph.walk_from_frontier(target).iter_units() {
    let event = self.events[lv]
    let parent_frontier = text_event_local_frontier(self.graph, event.parents)
    let (retreat, advance) = self.graph.diff_frontiers_lvs(
      ctx.cur_version,
      parent_frontier,
    )
    for old_lv in retreat.iter_units() {
      text_walker_retreat(ctx, self.events[old_lv], old_lv)
    }
    for new_lv in advance.iter_units() {
      text_walker_advance(ctx, self.events[new_lv], new_lv)
    }
    text_walker_apply(ctx, self.graph, event, lv)
    ctx.cur_version = @core.Frontier::from_array([lv])
  }
  {
    text: ctx.snapshot.join(""),
    insert_left_parents: ctx.insert_left_parents,
    insert_right_parents: ctx.insert_right_parents,
    delete_targets: ctx.delete_targets,
  }
}

///|
fn TextEventLog::checkout_current(self : TextEventLog) -> String {
  self.text
}

///|
fn TextEventLog::checkout(
  self : TextEventLog,
  target : @core.Frontier,
) -> String {
  self.checkout_trace(target).text
}

///|
priv struct TextEventSnapshot {
  text : String
  frontier : Array[@core.RawVersion]
}

///|
fn TextEventSnapshot::capture(log : TextEventLog) -> TextEventSnapshot {
  {
    text: log.text,
    frontier: text_event_raw_frontier(log.graph, log.graph.get_frontier()),
  }
}

///|
fn TextEventSnapshot::open(self : TextEventSnapshot) -> String {
  self.text
}

///|
priv struct TextWalkerItem {
  op_id : Int
  mut current_state : Int
  mut end_state : Int
  origin_left : Int
  right_parent : Int
}

///|
priv struct TextWalkerContext {
  items : Array[TextWalkerItem]
  items_by_lv : Array[TextWalkerItem?]
  delete_targets : Array[Int]
  mut cur_version : @core.Frontier
  snapshot : Array[String]
  insert_left_parents : Array[Int]
  insert_right_parents : Array[Int]
}

///|
fn text_walker_width(state : Int) -> Int {
  if state == 0 {
    1
  } else {
    0
  }
}

///|
fn text_walker_find_cursor(
  ctx : TextWalkerContext,
  target_position : Int,
) -> (Int, Int) {
  let mut current_position = 0
  let mut end_position = 0
  let mut index = 0
  while current_position < target_position {
    if index >= ctx.items.length() {
      abort("text event position is outside the parent document")
    }
    let item = ctx.items[index]
    current_position = current_position + text_walker_width(item.current_state)
    end_position = end_position + text_walker_width(item.end_state)
    index = index + 1
  }
  (index, end_position)
}

///|
fn text_walker_find_item_index(ctx : TextWalkerContext, op_id : Int) -> Int {
  for index, item in ctx.items {
    if item.op_id == op_id {
      return index
    }
  }
  abort("text event origin is not in transient materializer")
}

///|
fn text_walker_lv_compare(
  graph : @causal_graph.CausalGraph,
  left : Int,
  right : Int,
) -> Int {
  if left == right {
    return 0
  }
  if graph.is_ancestor(left, right) {
    return -1
  }
  if graph.is_ancestor(right, left) {
    return 1
  }
  match (graph.get_entry(left), graph.get_entry(right)) {
    (Some(left_entry), Some(right_entry)) => {
      let timestamp_order = left_entry.timestamp.compare(right_entry.timestamp)
      if timestamp_order != 0 {
        return timestamp_order
      }
      let agent_order = left_entry.agent.compare(right_entry.agent)
      if agent_order != 0 {
        return agent_order
      }
      left_entry.seq.compare(right_entry.seq)
    }
    _ => left.compare(right)
  }
}

///|
fn text_walker_integrate(
  ctx : TextWalkerContext,
  graph : @causal_graph.CausalGraph,
  new_item : TextWalkerItem,
  cursor_index : Int,
  cursor_end : Int,
) -> (Int, Int) {
  if cursor_index >= ctx.items.length() ||
    ctx.items[cursor_index].current_state != -1 {
    return (cursor_index, cursor_end)
  }
  let left_index = cursor_index - 1
  let right_index = if new_item.right_parent == -1 {
    ctx.items.length()
  } else {
    text_walker_find_item_index(ctx, new_item.right_parent)
  }
  let mut scanning = false
  let mut scan_index = cursor_index
  let mut scan_end = cursor_end
  let mut result_index = cursor_index
  let mut result_end = cursor_end
  while scan_index < ctx.items.length() {
    let other = ctx.items[scan_index]
    if other.current_state != -1 {
      break
    }
    if other.op_id == new_item.right_parent {
      abort("text event integration encountered its right parent")
    }
    let other_left = if other.origin_left == -1 {
      -1
    } else {
      text_walker_find_item_index(ctx, other.origin_left)
    }
    if other_left < left_index {
      break
    } else if other_left == left_index {
      let other_right = if other.right_parent == -1 {
        ctx.items.length()
      } else {
        text_walker_find_item_index(ctx, other.right_parent)
      }
      if other_right == right_index &&
        text_walker_lv_compare(graph, new_item.op_id, other.op_id) < 0 {
        break
      }
      scanning = other_right < right_index
    }
    scan_end = scan_end + text_walker_width(other.end_state)
    scan_index = scan_index + 1
    if !scanning {
      result_index = scan_index
      result_end = scan_end
    }
  }
  (result_index, result_end)
}

///|
fn text_walker_retreat(
  ctx : TextWalkerContext,
  event : TextEvent,
  lv : Int,
) -> Unit {
  let target = match event.edit {
    TextDelete(_) => ctx.delete_targets[lv]
    TextInsert(_, _) => lv
  }
  let item = match ctx.items_by_lv[target] {
    Some(value) => value
    None => abort("text event retreat target is missing")
  }
  match event.edit {
    TextDelete(_) => item.current_state = item.current_state - 1
    TextInsert(_, _) => item.current_state = -1
  }
}

///|
fn text_walker_advance(
  ctx : TextWalkerContext,
  event : TextEvent,
  lv : Int,
) -> Unit {
  let target = match event.edit {
    TextDelete(_) => ctx.delete_targets[lv]
    TextInsert(_, _) => lv
  }
  let item = match ctx.items_by_lv[target] {
    Some(value) => value
    None => abort("text event advance target is missing")
  }
  match event.edit {
    TextDelete(_) => item.current_state = item.current_state + 1
    TextInsert(_, _) => item.current_state = 0
  }
}

///|
fn text_walker_apply(
  ctx : TextWalkerContext,
  graph : @causal_graph.CausalGraph,
  event : TextEvent,
  lv : Int,
) -> Unit {
  match event.edit {
    TextDelete(position) => {
      let (start, end) = text_walker_find_cursor(ctx, position)
      let mut index = start
      let mut end_position = end
      while index < ctx.items.length() && ctx.items[index].current_state != 0 {
        end_position = end_position +
          text_walker_width(ctx.items[index].end_state)
        index = index + 1
      }
      if index >= ctx.items.length() {
        abort("text event delete position is outside the parent document")
      }
      let item = ctx.items[index]
      if item.end_state == 0 {
        ignore(ctx.snapshot.remove(end_position))
      }
      item.current_state = 1
      item.end_state = 1
      ctx.delete_targets[lv] = item.op_id
    }
    TextInsert(position, content) => {
      let (start, end) = text_walker_find_cursor(ctx, position)
      let origin_left = if start == 0 { -1 } else { ctx.items[start - 1].op_id }
      ctx.insert_left_parents[lv] = origin_left
      let mut right_parent = -1
      for index = start; index < ctx.items.length(); index = index + 1 {
        let next = ctx.items[index]
        if next.current_state != -1 {
          right_parent = next.op_id
          break
        }
      }
      ctx.insert_right_parents[lv] = right_parent
      let new_item = TextWalkerItem::{
        op_id: lv,
        current_state: 0,
        end_state: 0,
        origin_left,
        right_parent,
      }
      let (insert_index, insert_end) = text_walker_integrate(
        ctx, graph, new_item, start, end,
      )
      ctx.items_by_lv[lv] = Some(new_item)
      ctx.items.insert(insert_index, new_item)
      ctx.snapshot.insert(insert_end, content)
    }
  }
}

///|
fn text_event_raw_frontier(
  graph : @causal_graph.CausalGraph,
  frontier : @core.Frontier,
) -> Array[@core.RawVersion] {
  let result = []
  for lv in frontier.iter() {
    match graph.lv_to_raw(lv) {
      Some(raw) => result.push(raw)
      None => abort("text event frontier is missing from graph")
    }
  }
  result
}

///|
fn text_event_local_frontier(
  graph : @causal_graph.CausalGraph,
  parents : Array[@core.RawVersion],
) -> @core.Frontier {
  let result = []
  for raw in parents {
    match graph.raw_to_lv(raw) {
      Some(lv) => result.push(lv)
      None => abort("text event parent is missing from graph")
    }
  }
  @core.Frontier::from_array(result)
}
