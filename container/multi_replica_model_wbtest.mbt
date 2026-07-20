///| Generated multi-replica convergence coverage for the container façade.

///|
enum ContainerModelAction {
  Create(Int)
  MoveToRoot(Int, Int)
  DeleteNode(Int, Int)
  SetProperty(Int, Int, String)
  InsertText(Int, Int, String)
  DeleteText(Int, Int)
  TransactionEdit(Int, Int, String)
  Undo(Int)
  Redo(Int)
  Sync(Int, Int)
  DuplicateSync(Int, Int)
} derive(Debug)

///|
struct ContainerModelTrace {
  replica_count : Int
  actions : Array[ContainerModelAction]
} derive(Debug)

///|
impl @quickcheck.Arbitrary for ContainerModelTrace with fn arbitrary(size, rs) {
  let replica_count = 2 + rs.split().next_uint64().to_int().abs() % 4
  let actions : Array[ContainerModelAction] = [
    Create(0),
    MoveToRoot(1 % replica_count, 1),
    SetProperty(0, 0, "base"),
    InsertText(1 % replica_count, 0, "x"),
    DeleteText(1 % replica_count, 0),
    TransactionEdit(1 % replica_count, 0, "t"),
    Undo(1 % replica_count),
    Redo(1 % replica_count),
    DeleteNode(0, 2),
    Sync(0, 1 % replica_count),
    DuplicateSync(0, 1 % replica_count),
  ]
  let count = if size < 8 { 8 } else { size.min(32) }
  let chars = ["a", "b", "c", "d"]
  for _i = 0; _i < count; _i = _i + 1 {
    let replica = rs.split().next_uint64().to_int().abs() % replica_count
    let node = rs.split().next_uint64().to_int().abs() % 3
    let choice = rs.split().next_uint64().to_int().abs() % 11
    let action = match choice {
      0 => Create(replica)
      1 => MoveToRoot(replica, node)
      2 => DeleteNode(replica, node)
      3 => SetProperty(replica, node, chars[node % chars.length()])
      4 => InsertText(replica, node, chars[node % chars.length()])
      5 => DeleteText(replica, node)
      6 => TransactionEdit(replica, node, chars[node % chars.length()])
      7 => Undo(replica)
      8 => Redo(replica)
      9 => {
        let to = (replica + 1) % replica_count
        Sync(replica, to)
      }
      _ => {
        let to = (replica + 1) % replica_count
        DuplicateSync(replica, to)
      }
    }
    actions.push(action)
  }
  { replica_count, actions }
}

///|
impl @qc.Shrink for ContainerModelTrace with fn shrink(self) {
  let results : Array[ContainerModelTrace] = []
  if self.actions.length() > 11 {
    results.push({
      replica_count: self.replica_count,
      actions: self.actions[:11].to_owned(),
    })
    results.push({
      replica_count: self.replica_count,
      actions: self.actions[:self.actions.length() - 1].to_owned(),
    })
  }
  results.iter()
}

///|
fn container_model_sync(from : Document, to : Document) -> Unit {
  let message = try! from.sync().export_all()
  let _ = try! to.sync().apply(message)
}

///|
fn run_container_model(trace : ContainerModelTrace) -> Bool {
  let documents : Array[Document] = []
  for index = 0; index < trace.replica_count; index = index + 1 {
    documents.push(try! Document::new("replica-" + index.to_string()))
  }
  let known_nodes : Array[TreeNodeId] = []
  for _i = 0; _i < 3; _i = _i + 1 {
    known_nodes.push(try! documents[0].create_node(parent=root_id))
  }
  for index = 1; index < documents.length(); index = index + 1 {
    container_model_sync(documents[0], documents[index])
  }
  for action in trace.actions {
    match action {
      Create(replica) =>
        known_nodes.push(try! documents[replica].create_node(parent=root_id))
      MoveToRoot(replica, node_index) => {
        let node = known_nodes[node_index % known_nodes.length()]
        if documents[replica].is_alive(node) {
          try! documents[replica].move_node(target=node, new_parent=root_id)
        }
      }
      DeleteNode(replica, node_index) => {
        let node = known_nodes[node_index % known_nodes.length()]
        if documents[replica].is_alive(node) {
          try! documents[replica].delete_node(node)
        }
      }
      SetProperty(replica, node_index, value) => {
        let node = known_nodes[node_index % known_nodes.length()]
        if documents[replica].is_alive(node) {
          documents[replica].set_property(node, "model", value)
        }
      }
      InsertText(replica, node_index, value) => {
        let node = known_nodes[node_index % known_nodes.length()]
        if documents[replica].is_alive(node) {
          let position = documents[replica].text_len(node)
          try! documents[replica].insert_text(node, position, value)
        }
      }
      DeleteText(replica, node_index) => {
        let node = known_nodes[node_index % known_nodes.length()]
        if documents[replica].is_alive(node) &&
          documents[replica].text_len(node) > 0 {
          try! documents[replica].delete_text(node, 0)
        }
      }
      TransactionEdit(replica, node_index, value) => {
        let document = documents[replica]
        let node = known_nodes[node_index % known_nodes.length()]
        if document.is_alive(node) {
          try! document.transaction(fn() {
            document.set_property(node, "transaction", value)
            try! document.insert_text(node, document.text_len(node), value)
          })
        }
      }
      Undo(replica) =>
        if documents[replica].can_undo() {
          let _ = try! documents[replica].undo()
        }
      Redo(replica) =>
        if documents[replica].can_redo() {
          let _ = try! documents[replica].redo()
        }
      Sync(from, to) => container_model_sync(documents[from], documents[to])
      DuplicateSync(from, to) => {
        let message = try! documents[from].sync().export_all()
        let _ = try! documents[to].sync().apply(message)
        let replay = try! documents[to].sync().apply(message)
        if replay.applied_tree_operations() != 0 ||
          replay.applied_text_operations() != 0 {
          return false
        }
      }
    }
  }
  for _round = 0; _round < 3; _round = _round + 1 {
    let messages : Array[SyncMessage] = []
    for document in documents {
      messages.push(try! document.sync().export_all())
    }
    for document in documents {
      for message in messages {
        let _ = try! document.sync().apply(message)
      }
    }
  }
  let expected = documents[0]
  for index = 1; index < documents.length(); index = index + 1 {
    let document = documents[index]
    if document.version() != expected.version() ||
      document.children(root_id) != expected.children(root_id) ||
      document.sync().pending_sync_count() != 0 {
      return false
    }
    for node in known_nodes {
      if document.is_alive(node) != expected.is_alive(node) ||
        document.children(node) != expected.children(node) ||
        document.get_property(node, "model") !=
        expected.get_property(node, "model") ||
        document.get_property(node, "transaction") !=
        expected.get_property(node, "transaction") ||
        document.get_text(node) != expected.get_text(node) {
        return false
      }
    }
  }
  let observer = try! Document::new("observer")
  let _ = try! observer.sync().apply(try! expected.sync().export_all())
  !observer.can_undo() &&
  !observer.can_redo() &&
  observer.version() == expected.version() &&
  observer.sync().pending_sync_count() == 0
}

///|
test "property: 2-5 replica container model converges" {
  @qc.quick_check_fn(run_container_model)
}
