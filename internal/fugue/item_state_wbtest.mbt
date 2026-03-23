///| Whitebox tests for ItemState enum and transition functions

///|
test "ItemState - valid transitions" {
  // NotInserted -> Inserted (advance_insert)
  inspect(ItemState::NotInserted.advance_insert(), content="Inserted")
  // Retreated -> Inserted (advance_insert after retreat)
  inspect(ItemState::Retreated.advance_insert(), content="Inserted")
  // Inserted -> Retreated (retreat_insert)
  inspect(ItemState::Inserted.retreat_insert(), content="Retreated")
  // Deleted -> Retreated (retreat_insert on tombstoned item)
  inspect(ItemState::Deleted.retreat_insert(), content="Retreated")
}

///|
test "ItemState - visibility" {
  inspect(ItemState::NotInserted.is_visible(delete_count=0), content="false")
  inspect(ItemState::Inserted.is_visible(delete_count=0), content="true")
  inspect(ItemState::Inserted.is_visible(delete_count=1), content="false")
  inspect(ItemState::Deleted.is_visible(delete_count=0), content="false")
  inspect(ItemState::Retreated.is_visible(delete_count=0), content="false")
}

///|
test "ItemState - update_from_delete_count" {
  // Inserted with delete_count > 0 -> Deleted
  inspect(ItemState::Inserted.update_from_delete_count(1), content="Deleted")
  // Deleted with delete_count == 0 -> Inserted
  inspect(ItemState::Deleted.update_from_delete_count(0), content="Inserted")
  // Inserted with delete_count == 0 -> Inserted (no change)
  inspect(ItemState::Inserted.update_from_delete_count(0), content="Inserted")
  // Retreated is unaffected by delete_count
  inspect(ItemState::Retreated.update_from_delete_count(0), content="Retreated")
}

///|
test "Item - new fields initialized correctly" {
  let item = Item::new(Lv(0), "A", None, Left, Timestamp(0), ReplicaId("a"))
  inspect(item.state, content="Inserted")
  inspect(item.delete_count, content="0")
}

///|
test "Item - delete_count and state after operations" {
  let item = Item::new(Lv(0), "A", None, Left, Timestamp(0), ReplicaId("a"))
  // Simulate retreat_insert
  item.state = item.state.retreat_insert()
  inspect(item.state, content="Retreated")
  inspect(item.is_visible(), content="false")
  // Simulate advance_insert
  item.state = item.state.advance_insert()
  inspect(item.state, content="Inserted")
  inspect(item.is_visible(), content="true")
  // Simulate advance_delete
  item.delete_count = item.delete_count + 1
  item.state = item.state.update_from_delete_count(item.delete_count)
  inspect(item.state, content="Deleted")
  inspect(item.is_visible(), content="false")
  // Simulate retreat_delete
  item.delete_count = item.delete_count - 1
  item.state = item.state.update_from_delete_count(item.delete_count)
  inspect(item.state, content="Inserted")
  inspect(item.is_visible(), content="true")
}
