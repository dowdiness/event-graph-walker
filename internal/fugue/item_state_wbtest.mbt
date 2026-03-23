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
