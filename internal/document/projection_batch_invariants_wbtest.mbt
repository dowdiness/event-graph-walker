///| Regression gates for delayed OrderTree publication inside project_all.

///|
fn batch_assert_effect(
  actual : ProjectionEffect,
  expected : ProjectionEffect,
) -> Unit raise {
  match (actual, expected) {
    (Insert(position=a, text=at), Insert(position=e, text=et)) => {
      assert_eq(a, e)
      assert_eq(at, et)
    }
    (Delete(start=a, end=b), Delete(start=c, end=d)) => {
      assert_eq(a, c)
      assert_eq(b, d)
    }
    _ => fail("batch projection changed the effect kind")
  }
}

///|
/// Reproduce the consumer contract independently of VisibleRun UTF-16 slicing.
fn batch_replay_effects(
  before : String,
  effects : ArrayView[ProjectionEffect],
) -> String raise {
  let chars = before.to_array()
  for effect in effects {
    match effect {
      Insert(position~, text~) => {
        assert_true(position >= 0 && position <= chars.length())
        let inserted = text.to_array()
        assert_eq(inserted.length(), 1)
        chars.insert(position, inserted[0])
      }
      Delete(start~, end~) => {
        assert_true(start >= 0 && end <= chars.length())
        assert_eq(end, start + 1)
        ignore(chars.remove(start))
      }
    }
  }
  String::from_array(chars[:])
}

///|
fn batch_assert_exact(
  change : DocumentChanges,
  before : String,
  expected : Array[ProjectionEffect],
  after : String,
) -> Unit raise {
  assert_true(change.projection is Projected)
  match change.effect_availability {
    Exact(effects) => {
      assert_eq(effects.length(), expected.length())
      assert_eq(change.effects.length(), expected.length())
      for index = 0; index < effects.length(); index = index + 1 {
        batch_assert_effect(effects[index], expected[index])
        batch_assert_effect(change.effects[index], expected[index])
      }
      assert_eq(batch_replay_effects(before, effects), after)
    }
    SnapshotRequired | Unavailable =>
      fail("warm valid batch must publish complete exact effects")
  }
}

///|
/// Compare every scalar and tombstone rank to a fresh authoritative replay.
fn batch_assert_canonical(doc : Document, expected : String) -> Unit raise {
  let fresh = try! @branch.Branch::checkout(doc.oplog, doc.get_frontier())
  let canonical = fresh.inner_tree()
  assert_eq(fresh.get_frontier(), doc.get_frontier())
  assert_eq(canonical.to_text(), expected)
  assert_eq(doc.tree.to_text(), expected)
  assert_eq(doc.to_text(), expected)
  assert_eq(doc.visible_count(), canonical.visible_count())
  assert_indexed_state_matches_tree(doc)
  let actual_items = doc.tree.get_all_items()
  assert_eq(actual_items.length(), canonical.get_all_items().length())
  for entry in actual_items {
    let (lv, item) = entry
    let canonical_item = canonical.get(lv).unwrap()
    assert_eq(item.content, canonical_item.content)
    assert_eq(item.deleted, canonical_item.deleted)
    assert_eq(doc.lv_to_position(lv.0), canonical.lv_to_position(lv))
  }
  let visible = canonical.get_visible_items()
  for index = 0; index < visible.length(); index = index + 1 {
    let (lv, _) = visible[index]
    assert_eq(doc.lv_at_position(index), Some(lv.0))
  }
}

///|
/// Exercise new local origins and run slicing after publishing the batch.
fn batch_assert_later_edits(doc : Document) -> Unit raise {
  let replay = Document::new(doc.agent_id())
  ignore(try! replay.apply_changes(doc.get_all_ops()))
  try! replay.recover_projection(replay.get_frontier())
  assert_eq(replay.to_text(), doc.to_text())
  let middle = doc.visible_count() / 2
  ignore(try! doc.insert(middle, "🧭!"))
  ignore(try! replay.insert(middle, "🧭!"))
  assert_true(doc.indexed_state.is_ready())
  assert_eq(doc.to_text(), replay.to_text())
  p2_assert_same_operations(doc.get_all_ops(), replay.get_all_ops())
  batch_assert_canonical(doc, replay.to_text())
  ignore(try! doc.delete(middle))
  ignore(try! replay.delete(middle))
  assert_true(doc.indexed_state.is_ready())
  assert_eq(doc.to_text(), replay.to_text())
  p2_assert_same_operations(doc.get_all_ops(), replay.get_all_ops())
  batch_assert_canonical(doc, replay.to_text())
}

///|
test "batch projection flushes an insert run before deleting inside it" {
  let source = Document::new("batch-buffer-delete-source")
  ignore(try! source.insert(0, "abcd"))
  ignore(try! source.delete(1))
  let doc = Document::new("batch-buffer-delete-destination")
  let before = doc.to_text()
  let change = try! doc.apply_changes(source.get_all_ops())
  assert_true(doc.indexed_state.is_ready())
  batch_assert_exact(
    change,
    before,
    [
      Insert(position=0, text="a"),
      Insert(position=1, text="b"),
      Insert(position=2, text="c"),
      Insert(position=3, text="d"),
      Delete(start=1, end=2),
    ],
    "acd",
  )
  batch_assert_canonical(doc, "acd")
  batch_assert_later_edits(doc)
}

///|
test "batch projection flushes before prepend and middle insertions" {
  for position in [0, 2] {
    let source = Document::new("batch-nonconsecutive-source")
    ignore(try! source.insert(0, "abcd"))
    ignore(try! source.insert(position, "XY"))
    let doc = Document::new("batch-nonconsecutive-destination")
    let before = doc.to_text()
    let change = try! doc.apply_changes(source.get_all_ops())
    let expected = if position == 0 { "XYabcd" } else { "abXYcd" }
    assert_true(doc.indexed_state.is_ready())
    batch_assert_exact(
      change,
      before,
      [
        Insert(position=0, text="a"),
        Insert(position=1, text="b"),
        Insert(position=2, text="c"),
        Insert(position=3, text="d"),
        Insert(position~, text="X"),
        Insert(position=position + 1, text="Y"),
      ],
      expected,
    )
    batch_assert_canonical(doc, expected)
    batch_assert_later_edits(doc)
  }
}

///|
test "batch projection handles repeated hide show and unchanged visibility" {
  let source = Document::new("batch-visibility-source")
  ignore(try! source.insert(0, "ABC"))
  ignore(try! source.delete_by_lv(1))
  ignore(try! source.undelete(1))
  ignore(try! source.undelete(1))
  ignore(try! source.delete_by_lv(1))
  ignore(try! source.delete_by_lv(1))
  ignore(try! source.undelete(1))
  let doc = Document::new("batch-visibility-destination")
  let before = doc.to_text()
  let change = try! doc.apply_changes(source.get_all_ops())
  assert_true(doc.indexed_state.is_ready())
  batch_assert_exact(
    change,
    before,
    [
      Insert(position=0, text="A"),
      Insert(position=1, text="B"),
      Insert(position=2, text="C"),
      Delete(start=1, end=2),
      Insert(position=1, text="B"),
      Delete(start=1, end=2),
      Insert(position=1, text="B"),
    ],
    "ABC",
  )
  batch_assert_canonical(doc, "ABC")
  batch_assert_later_edits(doc)
}

///|
test "batch projection splits and deletes astral runs in scalar coordinates" {
  let source = Document::new("batch-astral-source")
  ignore(try! source.insert(0, "L🌱R"))
  let doc = Document::new("batch-astral-destination")
  ignore(try! doc.apply_changes(source.get_all_ops()))
  let before = doc.to_text()
  assert_eq(before, "L🌱R")
  let baseline_count = source.get_all_ops().length()
  ignore(try! source.insert(1, "😀🚀𝄞"))
  ignore(try! source.insert(2, "🧪"))
  ignore(try! source.delete(3))
  let operations = source.get_all_ops()
  let change = try! doc.apply_changes(operations[baseline_count:].to_owned())
  assert_true(doc.indexed_state.is_ready())
  batch_assert_exact(
    change,
    before,
    [
      Insert(position=1, text="😀"),
      Insert(position=2, text="🚀"),
      Insert(position=3, text="𝄞"),
      Insert(position=2, text="🧪"),
      Delete(start=3, end=4),
    ],
    "L😀🧪𝄞🌱R",
  )
  batch_assert_canonical(doc, "L😀🧪𝄞🌱R")
  batch_assert_later_edits(doc)
}

///|
test "batch projection consumes a pending drain larger than its incoming packet" {
  let source = Document::new("batch-pending-source")
  ignore(try! source.insert(0, "pqrs"))
  ignore(try! source.delete(1))
  let operations = source.get_all_ops()
  let doc = Document::new("batch-pending-destination")
  let pending = try! doc.apply_changes(operations[1:].to_owned())
  assert_true(pending.projection is Skipped)
  assert_eq(doc.pending_count(), 4)
  assert_true(doc.indexed_state.is_ready())
  let before = doc.to_text()
  let incoming = [operations[0]]
  let change = try! doc.apply_changes(incoming)
  match change.outcome {
    @oplog.ApplyChangesOutcome::Succeeded(receipt) => {
      assert_eq(receipt.committed().length(), 5)
      assert_true(receipt.committed().length() > incoming.length())
    }
    @oplog.ApplyChangesOutcome::Failed(..) =>
      fail("pending drain must complete")
  }
  assert_eq(doc.pending_count(), 0)
  assert_true(doc.indexed_state.is_ready())
  batch_assert_exact(
    change,
    before,
    [
      Insert(position=0, text="p"),
      Insert(position=1, text="q"),
      Insert(position=2, text="r"),
      Insert(position=3, text="s"),
      Delete(start=1, end=2),
    ],
    "prs",
  )
  batch_assert_canonical(doc, "prs")
  batch_assert_later_edits(doc)
}

///|
test "batch projection drops buffered effects after locator invariant failure" {
  let source = Document::new("batch-fallback-source")
  ignore(try! source.insert(0, "AB"))
  let doc = Document::new("batch-fallback-destination")
  ignore(try! doc.apply_changes(source.get_all_ops()))
  assert_eq(doc.to_text(), "AB")
  let baseline_count = source.get_all_ops().length()
  ignore(try! source.insert(2, "xy"))
  ignore(try! source.delete(0))
  ignore(try! source.insert(3, "z"))
  // The missing identity is not needed while buffering x/y, but the following
  // delete cannot prove its rank. All earlier effects and the detached cache
  // must be discarded, while z must still reach the authoritative tree.
  doc.indexed_state.locator.unwrap().items.remove(0)
  let operations = source.get_all_ops()
  let change = try! doc.apply_changes(operations[baseline_count:].to_owned())
  assert_true(change.projection is Projected)
  assert_true(change.effect_availability is SnapshotRequired)
  assert_eq(change.effects.length(), 0)
  assert_true(!doc.indexed_state.is_ready())
  assert_eq(doc.tree.to_text(), "Bxyz")
  batch_assert_canonical(doc, "Bxyz")
  assert_true(doc.indexed_state.is_ready())
  batch_assert_later_edits(doc)
}
