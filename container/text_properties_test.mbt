///| Property-based tests for current container text behavior.
///
/// These are characterization tests for the pre-refactor container text path.
/// They verify visible semantics only, not internal storage shape.

///|
enum BlockEdit {
  Insert(Int, Int, String)
  Delete(Int, Int)
  Replace(Int, String)
  DeleteNode(Int)
} derive(Debug)

///|
pub impl Show for BlockEdit with output(self, logger) {
  logger.write_string(@debug.to_string(self))
}

///|
struct BlockScenario {
  edits : Array[BlockEdit]
} derive(Debug)

///|
pub impl Show for BlockScenario with output(self, logger) {
  logger.write_string(@debug.to_string(self))
}

///|
fn insert_string(text : String, pos : Int, chunk : String) -> String {
  text[:pos].to_string() + chunk + text[pos:].to_string()
}

///|
fn delete_string_at(text : String, pos : Int) -> String {
  text[:pos].to_string() + text[pos + 1:].to_string()
}

///|
impl @quickcheck.Arbitrary for BlockScenario with arbitrary(size, rs) {
  let size_cap = if size < 0 { 0 } else { size }
  let count = size_cap % 8 + 1
  let chars : Array[Char] = ['a', 'b', 'c', 'd', 'e', 'f']
  let edits : Array[BlockEdit] = []
  let texts = ["", ""]
  let alive = [true, true]
  for _i = 0; _i < count; _i = _i + 1 {
    let live_blocks : Array[Int] = []
    for block = 0; block < 2; block = block + 1 {
      if alive[block] {
        live_blocks.push(block)
      }
    }
    if live_blocks.is_empty() {
      break
    }
    let requested = rs.split().next_uint64().to_int().abs() % 2
    let block = if alive[requested] {
      requested
    } else {
      let live_idx = rs.split().next_uint64().to_int().abs() %
        live_blocks.length()
      live_blocks[live_idx]
    }
    let len = texts[block].length()
    let choice = if len == 0 {
      rs.split().next_uint64().to_int().abs() % 3
    } else {
      rs.split().next_uint64().to_int().abs() % 4
    }
    if choice == 0 {
      let pos = rs.split().next_uint64().to_int().abs() % (len + 1)
      let char_idx = rs.split().next_uint64().to_int().abs() % chars.length()
      let chunk = chars[char_idx].to_string()
      texts[block] = insert_string(texts[block], pos, chunk)
      edits.push(Insert(block, pos, chunk))
    } else if choice == 1 && len > 0 {
      let pos = rs.split().next_uint64().to_int().abs() % len
      texts[block] = delete_string_at(texts[block], pos)
      edits.push(Delete(block, pos))
    } else if choice == 2 {
      let repl_len = rs.split().next_uint64().to_int().abs() % 3 + 1
      let sb = StringBuilder::new()
      for i = 0; i < repl_len; i = i + 1 {
        let char_idx = (rs.split().next_uint64().to_int().abs() + i) %
          chars.length()
        sb.write_string(chars[char_idx].to_string())
      }
      let replacement = sb.to_string()
      texts[block] = replacement
      edits.push(Replace(block, replacement))
    } else {
      alive[block] = false
      edits.push(DeleteNode(block))
    }
  }
  { edits, }
}

///|
impl @qc.Shrink for BlockScenario with shrink(self) {
  let results : Array[BlockScenario] = []
  let len = self.edits.length()
  if len > 0 {
    results.push({ edits: [] })
    let half = len / 2
    if half > 0 {
      results.push({ edits: self.edits[:half].to_array() })
    }
    if len > 1 {
      results.push({ edits: self.edits[:len - 1].to_array() })
    }
  }
  results.iter()
}

///|
fn model_apply(
  texts : Array[String],
  alive : Array[Bool],
  edit : BlockEdit,
) -> Unit {
  match edit {
    Insert(block, pos, chunk) =>
      if alive[block] {
        texts[block] = insert_string(texts[block], pos, chunk)
      }
    Delete(block, pos) =>
      if alive[block] {
        texts[block] = delete_string_at(texts[block], pos)
      }
    Replace(block, replacement) =>
      if alive[block] {
        texts[block] = replacement
      }
    DeleteNode(block) => alive[block] = false
  }
}

///|
fn doc_apply(
  doc : @container.Document,
  nodes : Array[@container.TreeNodeId],
  edit : BlockEdit,
) -> Bool {
  try {
    match edit {
      Insert(block, pos, chunk) => doc.insert_text(nodes[block], pos, chunk)
      Delete(block, pos) => doc.delete_text(nodes[block], pos)
      Replace(block, replacement) => doc.replace_text(nodes[block], replacement)
      DeleteNode(block) => doc.delete_node(nodes[block])
    }
    true
  } catch {
    _ => false
  }
}

///|
fn prop_container_text_matches_model(scenario : BlockScenario) -> Bool {
  let doc = @container.Document::new("alice") catch { _ => return false }
  let n0 = doc.create_node(parent=@container.root_id) catch {
    _ => return false
  }
  let n1 = doc.create_node(parent=@container.root_id) catch {
    _ => return false
  }
  let nodes = [n0, n1]
  let texts = ["", ""]
  let alive = [true, true]
  for edit in scenario.edits {
    model_apply(texts, alive, edit)
    if !doc_apply(doc, nodes, edit) {
      return false
    }
  }
  for block = 0; block < 2; block = block + 1 {
    if doc.get_text(nodes[block]) != texts[block] {
      return false
    }
    if doc.text_len(nodes[block]) != texts[block].length() {
      return false
    }
  }
  true
}

///|
test "property: container text matches simple two-block model" {
  @qc.quick_check_fn(prop_container_text_matches_model)
}

///|
fn prop_block_independence(scenario : BlockScenario) -> Bool {
  let doc = @container.Document::new("alice") catch { _ => return false }
  let n0 = doc.create_node(parent=@container.root_id) catch {
    _ => return false
  }
  let n1 = doc.create_node(parent=@container.root_id) catch {
    _ => return false
  }
  let nodes = [n0, n1]
  for edit in scenario.edits {
    let other = match edit {
      Insert(block, _, _) => 1 - block
      Delete(block, _) => 1 - block
      Replace(block, _) => 1 - block
      DeleteNode(block) => 1 - block
    }
    let before_other = doc.get_text(nodes[other])
    if !doc_apply(doc, nodes, edit) {
      return false
    }
    if doc.get_text(nodes[other]) != before_other {
      return false
    }
  }
  true
}

///|
test "property: editing one block does not change sibling block text" {
  @qc.quick_check_fn(prop_block_independence)
}

///|
fn prop_delete_node_preserves_text_and_rejects_writes(
  scenario : BlockScenario,
) -> Bool {
  let doc = @container.Document::new("alice") catch { _ => return false }
  let n0 = doc.create_node(parent=@container.root_id) catch {
    _ => return false
  }
  let n1 = doc.create_node(parent=@container.root_id) catch {
    _ => return false
  }
  let nodes = [n0, n1]

  for edit in scenario.edits {
    match edit {
      DeleteNode(block) => {
        let before = doc.get_text(nodes[block])
        if !doc_apply(doc, nodes, edit) {
          return false
        }
        if doc.get_text(nodes[block]) != before {
          return false
        }
        let insert_result = try {
          doc.insert_text(nodes[block], 0, "z")
          true
        } catch {
          _ => false
        }
        if insert_result {
          return false
        }
      }
      _ => if !doc_apply(doc, nodes, edit) { return false }
    }
  }
  true
}

///|
test "property: delete_node preserves existing text and rejects later writes" {
  @qc.quick_check_fn(prop_delete_node_preserves_text_and_rejects_writes)
}

///|
fn prop_sync_message_replays_mixed_tree_and_text(
  scenario : BlockScenario,
) -> Bool {
  let doc_a = @container.Document::new("alice") catch { _ => return false }
  let doc_b = @container.Document::new("bob") catch { _ => return false }
  let n0 = doc_a.create_node(parent=@container.root_id) catch {
    _ => return false
  }
  let n1 = doc_a.create_node(parent=@container.root_id) catch {
    _ => return false
  }
  let nodes = [n0, n1]

  for edit in scenario.edits {
    if !doc_apply(doc_a, nodes, edit) {
      return false
    }
  }

  ignore(
    doc_b.apply_remote_sync_message(
      doc_a.export_sync_message() catch {
        _ => return false
      },
    ),
  )

  for block = 0; block < 2; block = block + 1 {
    if doc_b.get_text(nodes[block]) != doc_a.get_text(nodes[block]) {
      return false
    }
    if doc_b.text_len(nodes[block]) != doc_a.text_len(nodes[block]) {
      return false
    }
    if doc_b.is_alive(nodes[block]) != doc_a.is_alive(nodes[block]) {
      return false
    }
  }
  true
}

///|
test "property: sync message converges mixed tree and text edits" {
  @qc.quick_check_fn(prop_sync_message_replays_mixed_tree_and_text)
}
