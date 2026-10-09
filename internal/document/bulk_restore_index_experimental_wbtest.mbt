///|
fn bulk_tie_locator() -> LvLocator {
  let loc = LvLocator::new()
  loc.nodes.clear()
  for index = 0; index < 20; index = index + 1 {
    loc.nodes.push({
      priority: 7UL,
      left: -1,
      right: -1,
      parent: -1,
      size: 1,
      visible: index % 2 == 0,
      visible_span: if index % 2 == 0 {
        1
      } else {
        0
      },
    })
  }
  loc.rank_root = -1
  loc
}

///|
fn bulk_assert_siblings(
  locator : LvLocator,
  tree : LocatorSiblings,
  output : Array[Int],
) -> Int raise {
  match tree {
    Empty => 0
    Branch(left~, lv~, right~, height~) => {
      let left_height = bulk_assert_siblings(locator, left, output)
      if !output.is_empty() {
        assert_true(locator.compare_lvs(output[output.length() - 1], lv) < 0)
      }
      output.push(lv)
      let right_height = bulk_assert_siblings(locator, right, output)
      assert_true((left_height - right_height).abs() <= 1)
      assert_eq(height, 1 + left_height.max(right_height))
      height
    }
  }
}

///|
fn bulk_assert_same_index(doc : Document) -> Unit raise {
  let reference = IndexedState::from_tree(doc.tree)
  let actual = IndexedState::from_tree_bulk_experimental(doc.tree).unwrap()
  let a = actual.locator.unwrap()
  let r = reference.locator.unwrap()
  splice_assert_rank_nodes_equal(a, r)
  for (at, rt) in [(a.root_left, r.root_left), (a.root_right, r.root_right)] {
    let aa : Array[Int] = []
    let rr : Array[Int] = []
    ignore(bulk_assert_siblings(a, at, aa))
    ignore(bulk_assert_siblings(r, rt, rr))
    assert_eq(aa, rr)
  }
  for (lv, _) in doc.tree.get_all_items() {
    let ai = a.items.get(lv.0).unwrap()
    let ri = r.items.get(lv.0).unwrap()
    assert_eq(ai.open_node, ri.open_node)
    assert_eq(ai.content_node, ri.content_node)
    assert_eq(ai.close_node, ri.close_node)
    for
      (at, rt) in [
        (ai.left_children, ri.left_children),
        (ai.right_children, ri.right_children),
      ] {
      let aa : Array[Int] = []
      let rr : Array[Int] = []
      ignore(bulk_assert_siblings(a, at, aa))
      ignore(bulk_assert_siblings(r, rt, rr))
      assert_eq(aa, rr)
    }
    assert_eq(a.position(lv.0), r.position(lv.0))
  }
  assert_eq(actual.text(doc.tree), reference.text(doc.tree))
  doc.indexed_state.restore_cache(actual.take_cache())
  assert_indexed_state_matches_tree(doc)
}

///|
test "bulk derived indexes equal old builder across edits tombstones and legacy empties" {
  let doc = Document::new("bulk-oracle")
  bulk_assert_same_index(doc)
  ignore(doc.insert(0, "a😀漢b"))
  ignore(doc.insert(0, "L"))
  ignore(doc.insert(3, "xy"))
  ignore(doc.delete(2))
  bulk_assert_same_index(doc)
  ignore(doc.undelete(1))
  bulk_assert_same_index(doc)
  let deleted : Array[Int] = []
  let mut state = 17
  for step = 0; step < 200; step = step + 1 {
    state = (state * 37 + 17) % 997
    let action = state % 5
    if action < 3 || doc.visible_count() == 0 {
      let pos = state % (doc.visible_count() + 1)
      ignore(doc.insert(pos, if state % 2 == 0 { "😀" } else { "Z" }))
    } else if action == 3 {
      let pos = state % doc.visible_count()
      deleted.push(doc.lv_at_position(pos).unwrap())
      ignore(doc.delete(pos))
    } else if !deleted.is_empty() {
      ignore(doc.undelete(deleted.pop().unwrap()))
    }
    bulk_assert_same_index(doc)
  }
  let legacy = Document::new("legacy-bulk")
  ignore(
    legacy.apply_changes([
      @core.Op::insert(0, [], "legacy", 0, "", None, None),
      @core.Op::insert(
        0,
        [@core.RawVersion("legacy", 0)],
        "legacy",
        1,
        "😀",
        Some(@core.RawVersion("legacy", 0)),
        None,
      ),
    ]),
  )
  bulk_assert_same_index(legacy)
  ignore(legacy.insert(1, "X"))
  bulk_assert_same_index(legacy)
}

///|
test "bulk Cartesian build preserves deterministic equal-priority left winner" {
  let actual = bulk_tie_locator()
  let reference = bulk_tie_locator()
  let order : Array[Int] = []
  for index = 19; index >= 0; index = index - 1 {
    order.push(index)
    reference.rank_root = reference.merge_rank(reference.rank_root, index)
  }
  actual.bulk_rank_experimental(order)
  splice_assert_rank_nodes_equal(actual, reference)
}
