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
  mut locator : LvLocator?
}

///|
fn IndexedState::new() -> IndexedState {
  { cache: Some(@order_tree.OrderTree::new()), locator: Some(LvLocator::new()) }
}

///|
/// Own a cache detached from the canonical Document slot.
fn IndexedState::from_snapshot(
  snapshot : (@order_tree.OrderTree[VisibleRun]?, LvLocator?),
) -> IndexedState {
  let (cache, locator) = snapshot
  { cache, locator }
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
  {
    cache: Some(@order_tree.OrderTree::from_array(runs)),
    locator: Some(LvLocator::from_tree(tree)),
  }
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
      self.locator = rebuilt.locator
      self.cache.unwrap()
    }
  }
}

///|
fn IndexedState::is_ready(self : IndexedState) -> Bool {
  self.cache is Some(_) && self.locator is Some(_)
}

///|
fn IndexedState::invalidate(self : IndexedState) -> Unit {
  self.cache = None
  self.locator = None
}

///|
/// Detach the cache for a transactional mutation. The canonical cache slot is
/// empty while the caller performs a fallible commit.
fn IndexedState::take_cache(
  self : IndexedState,
) -> (@order_tree.OrderTree[VisibleRun]?, LvLocator?) {
  let cache = self.cache
  let locator = self.locator
  self.cache = None
  self.locator = None
  (cache, locator)
}

///|
/// Restore a cache detached by `take_cache` without cloning it.
fn IndexedState::restore_cache(
  self : IndexedState,
  snapshot : (@order_tree.OrderTree[VisibleRun]?, LvLocator?),
) -> Unit {
  let (cache, locator) = snapshot
  self.cache = cache
  self.locator = locator
}

///|
/// Incrementally insert a visible item. Returns false when no warm index was
/// available, matching the old cache-validity fallback in Document.
fn IndexedState::insert_at(
  self : IndexedState,
  position : Int,
  run : VisibleRun,
  item : @fugue.Item[String],
) -> Bool {
  match (self.cache, self.locator) {
    (Some(cache), Some(locator)) => {
      let located = if locator.contains(run.start_lv) {
        locator.show(run.start_lv)
      } else {
        locator.add_item(item)
      }
      if located {
        cache.insert_at(position, run)
      }
      located
    }
    _ => false
  }
}

///|
/// Integrate one became-visible identity into the warm topology locator and
/// visible sequence, returning its authority-owned sequential scalar rank.
fn IndexedState::insert_visible(
  self : IndexedState,
  tree : @fugue.FugueTree[String],
  lv : Int,
  run : VisibleRun,
) -> Int? {
  match (self.cache, self.locator, tree.get(@fugue.Lv(lv))) {
    (Some(cache), Some(locator), Some(item)) => {
      let located = if locator.contains(lv) {
        locator.show(lv)
      } else {
        locator.add_item(item)
      }
      if !located {
        return None
      }
      match locator.position(lv) {
        Some(position) => {
          cache.insert_at(position, run)
          Some(position)
        }
        None => None
      }
    }
    _ => None
  }
}

///|
/// Incrementally remove one visible item. Returns false when the warm index
/// could not remove the requested position.
fn IndexedState::delete_at(self : IndexedState, position : Int) -> Bool {
  match self.cache {
    Some(cache) =>
      match cache.delete_at(position) {
        Some(deleted) =>
          match self.locator {
            Some(locator) => locator.hide(deleted.start_lv)
            None => false
          }
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
  ignore(self.ensure(tree))
  match self.locator {
    Some(locator) => locator.position(lv)
    None => None
  }
}
