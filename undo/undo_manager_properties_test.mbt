///| Model-based QuickCheck properties for UndoManager, independent of TextState.
///
/// A generated `Program` of `Command`s runs against the real `UndoManager` and
/// a simple reference model. Each side edits its own `FakeDoc`. After every
/// command the undo/redo return values, `can_undo`, `can_redo`, `is_tracking`,
/// and the documents must agree; at the end both stacks are drained and must
/// agree group by group.

///|
const LOCAL : String = "alice"

///|
const REMOTE : String = "bob"

///|
const TIMEOUT_MS : Int32 = 500

///|
/// LVs at or above this value never exist in a `FakeDoc`.
const MISSING_LV_BASE : Int32 = 1_000_000

///|
/// Minimal `Undoable` document: each LV is visible or deleted, and every
/// applied compensating edit is logged. Missing LVs and edits that would not
/// change the LV are stale.
struct FakeDoc {
  visible : Map[Int32, Bool]
  log : Array[String]
}

///|
fn FakeDoc::new() -> FakeDoc {
  { visible: {}, log: [], }
}

///|
/// Sets `lv` to `visible` and reports whether that changed the document.
fn FakeDoc::set(self : FakeDoc, lv : Int32, visible : Bool) -> Bool {
  match self.visible.get(lv) {
    Some(current) if current != visible => {
      self.visible[lv] = visible
      self.log.push(
        (if visible { "undelete:" } else { "delete:" }) + lv.to_string(),
      )
      true
    }
    _ => false
  }
}

///|
fn FakeDoc::nth_visible(self : FakeDoc, n : Int32) -> Int32? {
  let visible = self.visible
    .iter()
    .filter(entry => entry.1)
    .map(entry => entry.0)
    .to_array()
  if visible.length() == 0 {
    None
  } else {
    Some(visible[n % visible.length()])
  }
}

///|
fn FakeDoc::nth_lv(self : FakeDoc, n : Int32) -> Int32? {
  let lvs = self.visible.keys().to_array()
  if lvs.length() == 0 {
    None
  } else {
    Some(lvs[n % lvs.length()])
  }
}

///|
fn FakeDoc::same_state(self : FakeDoc, other : FakeDoc) -> Bool {
  self.visible.to_array() == other.visible.to_array()
}

///|
fn result_of(changed : Bool) -> @undo.CompensatingEditResult {
  if changed {
    @undo.CompensatingEditResult::applied()
  } else {
    @undo.CompensatingEditResult::stale()
  }
}

///|
impl @undo.Undoable for FakeDoc with fn delete_lv(self, lv) {
  result_of(self.set(lv, false))
}

///|
impl @undo.Undoable for FakeDoc with fn undelete_lv(self, lv) {
  result_of(self.set(lv, true))
}

///|
/// One step of a generated program. Indices pick among existing LVs modulo
/// their count when the command runs, so any subsequence stays executable.
#derive(Debug)
enum Command {
  /// Insert a new LV and record it for the local agent when `mine`, else the remote one.
  Insert(mine~ : Bool, dt~ : Int32)
  /// Delete a visible LV and record it for the local agent when `mine`, else the remote one.
  Delete(pick~ : Int32, mine~ : Bool, dt~ : Int32)
  /// Record a local insert of an LV the document does not have.
  RecordMissing(dt~ : Int32)
  /// Insert `inserts` new LVs, delete up to `deletes` visible LVs, and record
  /// them with `record_group`.
  Group(inserts~ : Int32, deletes~ : Int32, join~ : Bool)
  /// Toggle an LV without recording it, making history targets stale.
  External(pick~ : Int32)
  Undo
  Redo
  SetTracking(Bool)
  StopCapturing
  Clear
}

///|
#derive(Debug)
struct Program {
  commands : Array[Command]
}

///|
fn below(rs : @quickcheck.RandomState, n : Int32) -> Int32 {
  rs.split().next_uint64().to_int().abs() % n
}

///|
/// Gaps on both sides of the 500 ms capture boundary.
let gaps : Array[Int32] = [0, 1, 250, 499, 500, 501, 1000]

///|
fn gen_command(rs : @quickcheck.RandomState) -> Command {
  let dt = gaps[below(rs, gaps.length())]
  let mine = below(rs, 4) != 0
  match below(rs, 20) {
    0 | 1 | 2 | 3 | 4 => Insert(mine~, dt~)
    5 | 6 | 7 => Delete(pick=below(rs, 16), mine~, dt~)
    8 => RecordMissing(dt~)
    9 | 10 =>
      Group(inserts=below(rs, 3), deletes=below(rs, 3), join=below(rs, 2) == 0)
    11 => External(pick=below(rs, 16))
    12 | 13 | 14 => Undo
    15 | 16 => Redo
    17 => SetTracking(below(rs, 3) != 0)
    18 => StopCapturing
    _ => if below(rs, 3) == 0 { Clear } else { Undo }
  }
}

///|
impl @quickcheck.Arbitrary for Program with fn arbitrary(size, rs) {
  let length = 5 + below(rs, size.max(1) * 2 + 1)
  { commands: Array::makei(length, _ => gen_command(rs)), }
}

///|
impl @shrink.Shrink for Program with fn shrink(self) {
  let len = self.commands.length()
  let candidates : Array[Program] = []
  if len > 1 {
    candidates.push({ commands: self.commands[:len / 2].to_owned(), })
    candidates.push({ commands: self.commands[len / 2:].to_owned(), })
  }
  for i in 0..<len {
    let commands = self.commands.copy()
    commands.remove(i) |> ignore
    candidates.push({ commands, })
  }
  candidates.iter()
}

///|
#derive(Debug, Eq)
struct ModelItem {
  lv : Int32
  insert : Bool
}

///|
/// Reference model of the documented UndoManager rules.
struct Model {
  mut undo : Array[Array[ModelItem]]
  mut redo : Array[Array[ModelItem]]
  mut last_ms : Int32
  mut capture_open : Bool
  mut tracking : Bool
}

///|
fn Model::new() -> Model {
  { undo: [], redo: [], last_ms: 0, capture_open: false, tracking: true, }
}

///|
/// Behaviour counts across all generated programs, checked after the run so
/// the generator is known to reach each rule.
let coverage : Map[String, Int32] = Map([])

///|
fn hit(event : String) -> Unit {
  coverage[event] = coverage.get(event).unwrap_or(0) + 1
}

///|
fn Model::record(
  self : Model,
  item : ModelItem,
  agent : String,
  now : Int32,
) -> Unit {
  if !self.tracking {
    hit("suppressed while tracking off")
    return
  }
  if agent != LOCAL {
    hit("wrong agent ignored")
    return
  }
  if self.redo.length() > 0 {
    hit("redo cleared by record")
  }
  let gap = now - self.last_ms
  if self.capture_open && self.undo.length() > 0 && gap < TIMEOUT_MS {
    hit(if gap == TIMEOUT_MS - 1 { "merged at boundary" } else { "merged" })
    self.undo[self.undo.length() - 1].push(item)
  } else {
    if self.capture_open && self.undo.length() > 0 && gap == TIMEOUT_MS {
      hit("split at boundary")
    }
    self.undo.push([item])
  }
  self.last_ms = now
  self.capture_open = true
  self.redo = []
}

///|
fn Model::record_group(
  self : Model,
  items : Array[ModelItem],
  join : Bool,
) -> Unit {
  if items.length() == 0 || !self.tracking {
    return
  }
  if join && self.undo.length() > 0 {
    hit("group joined")
    self.undo[self.undo.length() - 1].append(items)
  } else {
    self.undo.push(items)
  }
  self.redo = []
  self.capture_open = false
}

///|
/// Applies `group` in reverse with inverted effects; the applied items, in
/// original order, form the opposite-direction group.
fn invert(doc : FakeDoc, group : Array[ModelItem]) -> Array[ModelItem] {
  let applied = group.rev().filter(item => doc.set(item.lv, !item.insert))
  applied.rev()
}

///|
/// Replays `group` in original order.
fn replay(doc : FakeDoc, group : Array[ModelItem]) -> Array[ModelItem] {
  group.filter(item => doc.set(item.lv, item.insert))
}

///|
/// Undo and redo always close time-based capture, so the next local edit
/// starts its own group.
fn Model::undo(self : Model, doc : FakeDoc) -> Bool {
  self.capture_open = false
  guard self.undo.pop() is Some(group) else {
    hit("undo on empty stack")
    return false
  }
  let applied = invert(doc, group)
  if applied.length() == 0 {
    hit("stale undo group dropped")
    return false
  }
  if applied.length() < group.length() {
    hit("partly stale undo")
  }
  self.redo.push(applied)
  true
}

///|
fn Model::redo(self : Model, doc : FakeDoc) -> Bool {
  self.capture_open = false
  guard self.redo.pop() is Some(group) else {
    hit("redo on empty stack")
    return false
  }
  let applied = replay(doc, group)
  if applied.length() == 0 {
    hit("stale redo group dropped")
    return false
  }
  self.undo.push(applied)
  true
}

///|
/// The real manager, the model, and their documents.
struct World {
  manager : @undo.UndoManager
  doc : FakeDoc
  model : Model
  model_doc : FakeDoc
  mut now : Int32
  mut next_lv : Int32
}

///|
fn World::new() -> World {
  {
    manager: @undo.UndoManager::new(LOCAL, capture_timeout_ms=TIMEOUT_MS),
    doc: FakeDoc::new(),
    model: Model::new(),
    model_doc: FakeDoc::new(),
    now: 0,
    next_lv: 0,
  }
}

///|
fn World::new_lv(self : World) -> Int32 {
  let lv = self.next_lv
  self.next_lv += 1
  self.doc.visible[lv] = true
  self.model_doc.visible[lv] = true
  lv
}

///|
/// Runs `command` on both sides and returns whether they still agree.
fn World::step(self : World, command : Command) -> Bool {
  let (real_result, model_result) = match command {
    Insert(mine~, dt~) => {
      self.now += dt
      let lv = self.new_lv()
      let agent = if mine { LOCAL } else { REMOTE }
      self.manager.record_insert(lv, agent, self.now)
      self.model.record({ lv, insert: true, }, agent, self.now)
      (false, false)
    }
    Delete(pick~, mine~, dt~) => {
      self.now += dt
      if self.doc.nth_visible(pick) is Some(lv) {
        self.doc.set(lv, false) |> ignore
        self.model_doc.set(lv, false) |> ignore
        let agent = if mine { LOCAL } else { REMOTE }
        self.manager.record_delete(lv, agent, self.now)
        self.model.record({ lv, insert: false, }, agent, self.now)
      }
      (false, false)
    }
    RecordMissing(dt~) => {
      self.now += dt
      let lv = MISSING_LV_BASE + self.next_lv
      self.next_lv += 1
      self.manager.record_insert(lv, LOCAL, self.now)
      self.model.record({ lv, insert: true, }, LOCAL, self.now)
      (false, false)
    }
    Group(inserts~, deletes~, join~) => {
      let items : Array[@undo.UndoItem] = []
      let model_items : Array[ModelItem] = []
      for _ in 0..<inserts {
        let lv = self.new_lv()
        items.push(@undo.UndoItem::insert(lv, "x"))
        model_items.push({ lv, insert: true, })
      }
      for i in 0..<deletes {
        if self.doc.nth_visible(i) is Some(lv) {
          self.doc.set(lv, false) |> ignore
          self.model_doc.set(lv, false) |> ignore
          items.push(@undo.UndoItem::delete(lv, "x"))
          model_items.push({ lv, insert: false, })
        }
      }
      self.manager.record_group(items[:], join~)
      self.model.record_group(model_items, join)
      (false, false)
    }
    External(pick~) => {
      if self.doc.nth_lv(pick) is Some(lv) {
        let visible = !self.doc.visible[lv]
        self.doc.set(lv, visible) |> ignore
        self.model_doc.set(lv, visible) |> ignore
      }
      (false, false)
    }
    Undo => (try! self.manager.undo(self.doc), self.model.undo(self.model_doc))
    Redo => (try! self.manager.redo(self.doc), self.model.redo(self.model_doc))
    SetTracking(enabled) => {
      self.manager.set_tracking(enabled)
      self.model.tracking = enabled
      (false, false)
    }
    StopCapturing => {
      self.manager.stop_capturing()
      self.model.capture_open = false
      (false, false)
    }
    Clear => {
      self.manager.clear()
      self.model.undo = []
      self.model.redo = []
      (false, false)
    }
  }
  real_result == model_result &&
  self.manager.can_undo() == (self.model.undo.length() > 0) &&
  self.manager.can_redo() == (self.model.redo.length() > 0) &&
  self.manager.is_tracking() == self.model.tracking &&
  self.doc.same_state(self.model_doc) &&
  self.doc.log == self.model_doc.log
}

///|
fn prop_matches_model(program : Program) -> Bool {
  let world = World::new()
  for command in program.commands {
    if !world.step(command) {
      return false
    }
  }
  // Draining both stacks compares the remaining groups one at a time.
  while world.manager.can_undo() || world.model.undo.length() > 0 {
    if !world.step(Undo) {
      return false
    }
  }
  while world.manager.can_redo() || world.model.redo.length() > 0 {
    if !world.step(Redo) {
      return false
    }
  }
  true
}

///|
test "property: UndoManager matches the reference model" {
  coverage.clear()
  @qc.quick_check_fn(prop_matches_model, max_success=500)
  for
    event in [
      "wrong agent ignored", "suppressed while tracking off", "merged", "merged at boundary",
      "split at boundary", "group joined", "redo cleared by record", "undo on empty stack",
      "redo on empty stack", "stale undo group dropped", "partly stale undo",
    ] {
    assert_true(
      coverage.get(event).unwrap_or(0) > 0,
      msg="never generated: \{event}",
    )
  }
}

///|
/// Model-free oracle: after any history, undoing everything and then redoing
/// everything returns the document to its state before the undos.
fn prop_undo_all_redo_all_round_trip(program : Program) -> Bool {
  let world = World::new()
  for command in program.commands {
    world.step(command) |> ignore
  }
  let manager = world.manager
  let doc = world.doc
  // Start from an empty redo stack so the final redos only undo our undos.
  while manager.can_redo() {
    ignore(try! manager.redo(doc))
  }
  let before = doc.visible.to_array()
  let mut undone = 0
  while manager.can_undo() {
    if (try! manager.undo(doc)) {
      undone += 1
    }
  }
  let mut redone = 0
  while manager.can_redo() {
    if (try! manager.redo(doc)) {
      redone += 1
    } else {
      return false
    }
  }
  doc.visible.to_array() == before && undone == redone
}

///|
test "property: undo all then redo all restores the document" {
  @qc.quick_check_fn(prop_undo_all_redo_all_round_trip, max_success=300)
}
