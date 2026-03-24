///|
test "jump: root children have depth 1" {
  let ja = JumpAncestors::new()
  ja.add(Lv(0), root_lv)
  inspect(ja.depth[0], content="1")
  inspect(ja.jump[0].length(), content="1")
  inspect(ja.jump[0][0], content="Lv(-1)")
}

///|
test "jump: deep chain — all ancestor pairs" {
  let ja = JumpAncestors::new()
  ja.add(Lv(0), root_lv)
  for i = 1; i < 10; i = i + 1 {
    ja.add(Lv(i), Lv(i - 1))
  }
  for a = 0; a < 10; a = a + 1 {
    for b = a; b < 10; b = b + 1 {
      assert_true(ja.is_ancestor(Lv(a), Lv(b)))
    }
  }
  assert_false(ja.is_ancestor(Lv(5), Lv(2)))
  assert_false(ja.is_ancestor(Lv(9), Lv(0)))
}

///|
test "jump: branching tree — cross-branch is not ancestor" {
  let ja = JumpAncestors::new()
  ja.add(Lv(0), root_lv)
  ja.add(Lv(1), root_lv)
  ja.add(Lv(2), Lv(0))
  ja.add(Lv(3), Lv(0))
  ja.add(Lv(4), Lv(1))
  assert_true(ja.is_ancestor(Lv(0), Lv(2)))
  assert_true(ja.is_ancestor(Lv(0), Lv(3)))
  assert_true(ja.is_ancestor(Lv(1), Lv(4)))
  assert_false(ja.is_ancestor(Lv(0), Lv(4)))
  assert_false(ja.is_ancestor(Lv(1), Lv(2)))
  assert_false(ja.is_ancestor(Lv(2), Lv(3)))
  assert_false(ja.is_ancestor(Lv(3), Lv(2)))
}

///|
test "jump: sparse LVs — gaps from non-insert ops" {
  let ja = JumpAncestors::new()
  ja.add(Lv(0), root_lv)
  ja.add(Lv(2), Lv(0))
  ja.add(Lv(5), Lv(2))
  assert_true(ja.is_ancestor(Lv(0), Lv(5)))
  assert_true(ja.is_ancestor(Lv(2), Lv(5)))
  assert_false(ja.is_ancestor(Lv(1), Lv(5)))
  assert_false(ja.is_ancestor(Lv(0), Lv(1)))
  assert_false(ja.is_ancestor(Lv(3), Lv(5)))
}

///|
test "jump: wide tree — siblings are not ancestors" {
  let ja = JumpAncestors::new()
  for i = 0; i < 10; i = i + 1 {
    ja.add(Lv(i), root_lv)
  }
  for i = 0; i < 10; i = i + 1 {
    inspect(ja.depth[i], content="1")
  }
  for i = 0; i < 10; i = i + 1 {
    for j = 0; j < 10; j = j + 1 {
      if i != j {
        assert_false(ja.is_ancestor(Lv(i), Lv(j)))
      }
    }
  }
}

///|
test "jump: absent LV returns false" {
  let ja = JumpAncestors::new()
  ja.add(Lv(0), root_lv)
  assert_false(ja.is_ancestor(Lv(999), Lv(0)))
  assert_false(ja.is_ancestor(Lv(0), Lv(999)))
  assert_false(ja.is_ancestor(Lv(999), Lv(888)))
}
