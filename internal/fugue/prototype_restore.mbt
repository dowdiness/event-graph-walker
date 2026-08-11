// PROTOTYPE — throwaway serialized checkpoint restore seam.
//
// This is not a production restore API. It rebuilds FugueTree's private
// indexes from a complete materialized item snapshot so the checkpoint
// experiment can measure restore rather than replaying insert operations.

///|
/// Construct one complete item record for the serialized-state prototype.
///
/// `side_name` and `state_name` are decoded outside this package, while the
/// enum constructors remain here where the internal representation is owned.
pub fn prototype_item_from_parts(
  id : Int,
  content : String,
  parent : Lv?,
  side_name : String,
  deleted : Bool,
  deleted_ts : Int,
  deleted_agent : String,
  deleted_is_undelete : Bool,
  state_name : String,
  delete_count : Int,
  timestamp : Int,
  agent : String,
) -> Item[String] {
  let side = match side_name {
    "left" => Left
    "right" => Right
    _ => abort("prototype restore has an unknown item side")
  }
  let state = match state_name {
    "not_inserted" => ItemState::NotInserted
    "inserted" => ItemState::Inserted
    "deleted" => ItemState::Deleted
    "retreated" => ItemState::Retreated
    _ => abort("prototype restore has an unknown item state")
  }
  {
    id: Lv(id),
    content,
    parent,
    side,
    deleted,
    deleted_ts,
    deleted_agent,
    deleted_is_undelete,
    state,
    delete_count,
    timestamp: Timestamp(timestamp),
    agent: ReplicaId(agent),
  }
}

///|
/// Rebuild a Fugue tree from complete item records, including tombstones and
/// the current delete winner fields.
///
/// The source snapshot is sorted by LV because admitted Fugue origins always
/// refer to items already known at admission time. The helper deliberately
/// preserves every Item field instead of deriving visibility from operations.
pub fn FugueTree::prototype_restore_from_items(
  source : Array[Item[String]],
) -> FugueTree[String] {
  let items = source.copy()
  items.sort_by(fn(a, b) { a.id.compare(b.id) })
  let tree : FugueTree[String] = {
    items: [],
    lv_index: [],
    length: 0,
    visible: 0,
    root_children: [],
    children: [],
    jump_ancestors: JumpAncestors::new(),
  }

  // Install every item and create the LV-to-dense bridge first. This keeps
  // parent lookup independent of the order in which the snapshot was walked.
  for item in items {
    let item_id = ItemId(tree.items.length())
    tree.items.push(Some(item))
    while tree.lv_index.length() <= item.id.0 {
      tree.lv_index.push(None)
    }
    tree.lv_index[item.id.0] = Some(item_id)
    tree.children.push([])
    tree.length = tree.length + 1
    if item.state.is_visible(delete_count=item.delete_count) {
      tree.visible = tree.visible + 1
    }
  }

  // Rebuild child order and binary-lifting ancestry after all identities are
  // available. LV order is also the original append order for this tree.
  for dense_id = 0; dense_id < tree.items.length(); dense_id = dense_id + 1 {
    let item = match tree.items[dense_id] {
      Some(item) => item
      None => abort("prototype restore encountered an empty item slot")
    }
    let item_id = ItemId(dense_id)
    match item.parent {
      None => ()
      Some(parent) if parent == root_lv => tree.root_children.push(item_id)
      Some(parent) =>
        match tree.lookup_item_id(parent) {
          Some(parent_id) => tree.children[parent_id.0].push(item_id)
          None => abort("prototype restore encountered a missing parent")
        }
    }
    match item.parent {
      None => ()
      Some(parent) if parent == root_lv =>
        tree.jump_ancestors.add_item_id(item_id, None)
      Some(parent) =>
        match tree.lookup_item_id(parent) {
          Some(parent_id) =>
            tree.jump_ancestors.add_item_id(item_id, Some(parent_id))
          None => abort("prototype restore encountered a missing ancestor")
        }
    }
  }
  tree
}
