///| MergeCache — wraps a position cache (OrderTree[VisibleRun]) for
/// incremental updates during merge operations.
///
/// If the merge is too large relative to the document, the cache is dropped
/// and rebuilt after merge completes. This avoids O(n) incremental updates
/// when a bulk merge would be cheaper to rebuild from scratch.

///|
/// Wraps a position cache for incremental updates during merge.
/// If the merge is too large, the cache is dropped and rebuilt after merge completes.
pub struct MergeCache {
  cache : @order_tree.OrderTree[VisibleRun]?
  mut dirty : Bool
}

///|
/// Create from an existing position cache.
/// If merge_size > doc_size / 2, skip incremental and rebuild after.
pub fn MergeCache::new(
  cache : @order_tree.OrderTree[VisibleRun]?,
  doc_size : Int,
  merge_size : Int,
) -> MergeCache {
  if merge_size > doc_size / 2 {
    { cache: None, dirty: true }
  } else {
    { cache, dirty: cache is None }
  }
}

///|
/// Remove an item at a known document position.
pub fn MergeCache::remove_at(self : MergeCache, position : Int) -> Unit {
  match self.cache {
    Some(cache) => {
      let _ = cache.delete_at(position)
    }
    None => self.dirty = true
  }
}

///|
/// Insert an item at a document position.
pub fn MergeCache::insert_at(
  self : MergeCache,
  position : Int,
  run : VisibleRun,
) -> Unit {
  match self.cache {
    Some(cache) => cache.insert_at(position, run)
    None => self.dirty = true
  }
}

///|
/// Get the final cache. Returns None if dirty (needs full rebuild).
pub fn MergeCache::take(
  self : MergeCache,
) -> @order_tree.OrderTree[VisibleRun]? {
  if self.dirty && self.cache is None {
    None
  } else {
    self.cache
  }
}
