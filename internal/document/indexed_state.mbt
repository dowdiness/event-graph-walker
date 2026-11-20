///| IndexedState — package-private visible projection index.
///
/// The index stores the same one-item-per-position VisibleRun projection that
/// Document previously kept directly. It is a Fugue-derived cache: callers
/// provide the Fugue tree when the lazy index needs a rebuild, while
/// incremental edits update the existing OrderTree in place. This extraction
/// creates a seam for a future lifecycle separation; Fugue remains the source
/// of truth in the current implementation.

///|
priv struct ProjectionIndex {
  cache : @order_tree.OrderTree[VisibleRun]
  locator : LvLocator
}

///|
struct IndexedState {
  mut ready : ProjectionIndex?
}

///|
fn IndexedState::new() -> IndexedState {
  {
    ready: Some({
      cache: @order_tree.OrderTree::new(),
      locator: LvLocator::new(),
    }),
  }
}

///|
/// Own a cache detached from the canonical Document slot.
fn IndexedState::from_snapshot(snapshot : ProjectionIndex?) -> IndexedState {
  { ready: snapshot, }
}

///|
/// Build an index from Fugue's visible traversal, preserving the old cache
/// construction order and run representation exactly.
fn IndexedState::from_tree(tree : @fugue.FugueTree[String]) -> IndexedState {
  let items = tree.get_visible_items()
  let runs : Array[VisibleRun] = Array(capacity=items.length())
  for i = 0; i < items.length(); i = i + 1 {
    let (lv, item) = items[i]
    runs.push({ start_lv: lv.0, text: item.content, count: 1, })
  }
  {
    ready: Some({
      cache: @order_tree.OrderTree::from_array(runs),
      locator: LvLocator::from_tree(tree),
    }),
  }
}

///|
/// Return the current index, rebuilding it lazily from the Fugue tree.
fn IndexedState::ensure(
  self : IndexedState,
  tree : @fugue.FugueTree[String],
) -> @order_tree.OrderTree[VisibleRun] {
  match self.ready {
    Some(index) => index.cache
    None => {
      let rebuilt = IndexedState::from_tree(tree)
      self.ready = rebuilt.ready
      self.ready.unwrap().cache
    }
  }
}

///|
fn IndexedState::is_ready(self : IndexedState) -> Bool {
  self.ready is Some(_)
}

///|
fn IndexedState::invalidate(self : IndexedState) -> Unit {
  self.ready = None
}

///|
/// Detach the cache for a transactional mutation. The canonical cache slot is
/// empty while the caller performs a fallible commit.
fn IndexedState::take_cache(self : IndexedState) -> ProjectionIndex? {
  let ready = self.ready
  self.ready = None
  ready
}

///|
/// Restore a cache detached by `take_cache` without cloning it.
fn IndexedState::restore_cache(
  self : IndexedState,
  snapshot : ProjectionIndex?,
) -> Unit {
  self.ready = snapshot
}

///|
/// Incrementally insert a visible item. Returns false when no warm index was
/// available, matching the old cache-validity fallback in Document.
fn IndexedState::insert_at(
  self : IndexedState,
  position : Int32,
  run : VisibleRun,
  item : @fugue.Item[String],
) -> Bool {
  match self.ready {
    Some({ cache, locator, }) => {
      let located = if locator.contains(run.start_lv) {
        locator.show(run.start_lv)
      } else {
        locator.add_item(item)
      }
      if located && locator.position(run.start_lv) == Some(position) {
        cache.insert_at(position, run)
        true
      } else {
        false
      }
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
  lv : Int32,
  run : VisibleRun,
) -> Int32? {
  match (self.ready, self.locate_visible(tree, lv)) {
    (Some(index), Some(position)) => {
      index.cache.insert_at(position, run)
      Some(position)
    }
    _ => None
  }
}

///|
/// Update topology and visibility independently from the visible run buffer.
/// A projection workspace may defer adjacent run writes until the next read.
fn IndexedState::locate_visible(
  self : IndexedState,
  tree : @fugue.FugueTree[String],
  lv : Int32,
) -> Int32? {
  match (self.ready, tree.get(@fugue.Lv(lv))) {
    (Some({ locator, .. }), Some(item)) => {
      let located = if locator.contains(lv) {
        locator.show(lv)
      } else {
        locator.add_item(item)
      }
      if located {
        locator.position(lv)
      } else {
        None
      }
    }
    _ => None
  }
}

///|
/// Incrementally remove one visible item. Returns false when the warm index
/// could not remove the requested position.
fn IndexedState::delete_at(self : IndexedState, position : Int32) -> Bool {
  match self.ready {
    Some({ cache, locator, }) =>
      match cache.delete_at(position) {
        Some(deleted) => locator.hide(deleted.start_lv)
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
  position : Int32,
) -> Int32? {
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
  position : Int32,
) -> Int32 {
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
) -> Int32 {
  @rle.Spanning::span(self.ensure(tree))
}

///|
/// Derive visible text from the indexed runs.
fn IndexedState::text(
  self : IndexedState,
  tree : @fugue.FugueTree[String],
) -> String {
  let cache = self.ensure(tree)
  let builder = StringBuilder()
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
  lv : Int32,
) -> Int32? {
  ignore(self.ensure(tree))
  match self.ready {
    Some(index) => index.locator.position(lv)
    None => None
  }
}

///|
/// Remove a prevalidated contiguous visible interval in one OrderTree edit.
/// Topology identities remain present and only their visible weights change.
fn IndexedState::delete_range_known(
  self : IndexedState,
  start : Int32,
  end : Int32,
  targets : Array[Int32],
) -> Bool {
  match self.ready {
    Some({ cache, locator, }) => {
      for lv in targets {
        if !locator.hide(lv) {
          return false
        }
      }
      let before = cache.span()
      cache.delete_range(start, end)
      cache.span() == before - targets.length()
    }
    _ => false
  }
}
