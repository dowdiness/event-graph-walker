///| IndexedState — package-private visible projection index.
///
/// The index stores the same one-item-per-position VisibleRun projection that
/// Document previously kept directly. It is a Fugue-derived cache: callers
/// provide the Fugue tree when the lazy index needs a rebuild, while
/// incremental edits update the existing OrderTree in place. This extraction
/// creates a seam for a future lifecycle separation; Fugue remains the source
/// of truth in the current implementation.

///|
struct IndexedState {
  mut cache : @order_tree.OrderTree[VisibleRun]?
}

///|
fn IndexedState::new() -> IndexedState {
  { cache: None }
}

///|
/// Build an index from Fugue's visible traversal, preserving the old cache
/// construction order and run representation exactly.
fn IndexedState::from_tree(tree : @fugue.FugueTree[String]) -> IndexedState {
  let items = tree.get_visible_items()
  let runs : Array[VisibleRun] = Array::new(capacity=items.length())
  for i = 0; i < items.length(); i = i + 1 {
    let (lv, item) = items[i]
    runs.push({ start_lv: lv.0, text: item.content, count: 1 })
  }
  { cache: Some(@order_tree.OrderTree::from_array(runs)) }
}

///|
/// Return the current index, rebuilding it lazily from the Fugue tree.
fn IndexedState::ensure(
  self : IndexedState,
  tree : @fugue.FugueTree[String],
) -> @order_tree.OrderTree[VisibleRun] {
  match self.cache {
    Some(cache) => cache
    None => {
      let rebuilt = IndexedState::from_tree(tree)
      self.cache = rebuilt.cache
      self.cache.unwrap()
    }
  }
}

///|
fn IndexedState::is_ready(self : IndexedState) -> Bool {
  self.cache is Some(_)
}

///|
fn IndexedState::invalidate(self : IndexedState) -> Unit {
  self.cache = None
}

///|
/// Incrementally insert a visible item. Returns false when no warm index was
/// available, matching the old cache-validity fallback in Document.
fn IndexedState::insert_at(
  self : IndexedState,
  position : Int,
  run : VisibleRun,
) -> Bool {
  match self.cache {
    Some(cache) => {
      cache.insert_at(position, run)
      true
    }
    None => false
  }
}

///|
/// Incrementally remove one visible item. Returns false when the warm index
/// could not remove the requested position.
fn IndexedState::delete_at(self : IndexedState, position : Int) -> Bool {
  match self.cache {
    Some(cache) =>
      match cache.delete_at(position) {
        Some(_) => true
        None => false
      }
    None => false
  }
}

///|
/// Get the LV at a visible item position.
fn IndexedState::lv_at_position(
  self : IndexedState,
  tree : @fugue.FugueTree[String],
  position : Int,
) -> Int? {
  let cache = self.ensure(tree)
  match cache.find(position) {
    Some(fr) => Some(fr.elem.start_lv + fr.offset)
    None => None
  }
}

///|
/// Map a cursor position to the LV immediately before it.
fn IndexedState::position_to_lv(
  self : IndexedState,
  tree : @fugue.FugueTree[String],
  position : Int,
) -> Int {
  if position == 0 {
    return -1
  }
  let total = self.visible_span(tree)
  let target = if position > total { total - 1 } else { position - 1 }
  if target < 0 {
    return -1
  }
  match self.lv_at_position(tree, target) {
    Some(lv) => lv
    None => -1
  }
}

///|
/// Return the visible item-space span represented by the index.
fn IndexedState::visible_span(
  self : IndexedState,
  tree : @fugue.FugueTree[String],
) -> Int {
  @rle.Spanning::span(self.ensure(tree))
}

///|
/// Derive visible text from the indexed runs.
fn IndexedState::text(
  self : IndexedState,
  tree : @fugue.FugueTree[String],
) -> String {
  let cache = self.ensure(tree)
  let builder = StringBuilder::new()
  for run in cache.iter() {
    builder.write_string(run.text)
  }
  builder.to_string()
}

///|
/// Map a visible LV back to its item-space position.
fn IndexedState::lv_to_position(
  self : IndexedState,
  tree : @fugue.FugueTree[String],
  lv : Int,
) -> Int? {
  let cache = self.ensure(tree)
  let mut position = 0
  for run in cache.iter() {
    if lv >= run.start_lv && lv < run.start_lv + run.count {
      return Some(position + (lv - run.start_lv))
    }
    position = position + run.count
  }
  None
}
