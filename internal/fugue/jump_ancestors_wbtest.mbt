///|
test "jump: root children have depth 1" {
  let ja = JumpAncestors::new()
  ja.add_item_id(ItemId(0), None)
  inspect(ja.depth[0], content="1")
  inspect(ja.jump[0].length(), content="0")
}

///|
test "jump: deep chain — all ancestor pairs" {
  let ja = JumpAncestors::new()
  ja.add_item_id(ItemId(0), None)
  for i = 1; i < 10; i = i + 1 {
    ja.add_item_id(ItemId(i), Some(ItemId(i - 1)))
  }
  for a = 0; a < 10; a = a + 1 {
    for b = a; b < 10; b = b + 1 {
      assert_true(ja.is_ancestor_item_id(ItemId(a), ItemId(b)))
    }
  }
  assert_false(ja.is_ancestor_item_id(ItemId(5), ItemId(2)))
  assert_false(ja.is_ancestor_item_id(ItemId(9), ItemId(0)))
}

///|
test "jump: branching tree — cross-branch is not ancestor" {
  let ja = JumpAncestors::new()
  ja.add_item_id(ItemId(0), None)
  ja.add_item_id(ItemId(1), None)
  ja.add_item_id(ItemId(2), Some(ItemId(0)))
  ja.add_item_id(ItemId(3), Some(ItemId(0)))
  ja.add_item_id(ItemId(4), Some(ItemId(1)))
  assert_true(ja.is_ancestor_item_id(ItemId(0), ItemId(2)))
  assert_true(ja.is_ancestor_item_id(ItemId(0), ItemId(3)))
  assert_true(ja.is_ancestor_item_id(ItemId(1), ItemId(4)))
  assert_false(ja.is_ancestor_item_id(ItemId(0), ItemId(4)))
  assert_false(ja.is_ancestor_item_id(ItemId(1), ItemId(2)))
  assert_false(ja.is_ancestor_item_id(ItemId(2), ItemId(3)))
  assert_false(ja.is_ancestor_item_id(ItemId(3), ItemId(2)))
}

///|
test "jump: sparse LVs — gaps from non-insert ops" {
  let ja = JumpAncestors::new()
  ja.add_item_id(ItemId(0), None)
  ja.add_item_id(ItemId(2), Some(ItemId(0)))
  ja.add_item_id(ItemId(5), Some(ItemId(2)))
  assert_true(ja.is_ancestor_item_id(ItemId(0), ItemId(5)))
  assert_true(ja.is_ancestor_item_id(ItemId(2), ItemId(5)))
  assert_false(ja.is_ancestor_item_id(ItemId(1), ItemId(5)))
  assert_false(ja.is_ancestor_item_id(ItemId(0), ItemId(1)))
  assert_false(ja.is_ancestor_item_id(ItemId(3), ItemId(5)))
}

///|
test "jump: wide tree — siblings are not ancestors" {
  let ja = JumpAncestors::new()
  for i = 0; i < 10; i = i + 1 {
    ja.add_item_id(ItemId(i), None)
  }
  for i = 0; i < 10; i = i + 1 {
    inspect(ja.depth[i], content="1")
  }
  for i = 0; i < 10; i = i + 1 {
    for j = 0; j < 10; j = j + 1 {
      if i != j {
        assert_false(ja.is_ancestor_item_id(ItemId(i), ItemId(j)))
      }
    }
  }
}

///|
test "jump: absent LV returns false" {
  let ja = JumpAncestors::new()
  ja.add_item_id(ItemId(0), None)
  assert_false(ja.is_ancestor_item_id(ItemId(999), ItemId(0)))
  assert_false(ja.is_ancestor_item_id(ItemId(0), ItemId(999)))
  assert_false(ja.is_ancestor_item_id(ItemId(999), ItemId(888)))
}
