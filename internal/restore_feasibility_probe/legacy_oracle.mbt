///|
/// Test-only canonical-event adapter through the production Document.
fn legacy_raw(identity : RawIdentity) -> @core.RawVersion {
  @core.RawVersion(identity.agent, identity.sequence)
}

///|
/// Stable ordering and equality for raw frontiers.
fn legacy_compare_raw(a : @core.RawVersion, b : @core.RawVersion) -> Int {
  let by_agent = a.agent.compare(b.agent)
  if by_agent != 0 {
    by_agent
  } else {
    a.seq.compare(b.seq)
  }
}

///|
fn legacy_same_frontier(
  left : Array[@core.RawVersion],
  right : Array[@core.RawVersion],
) -> Bool {
  if left.length() != right.length() {
    return false
  }
  let sorted_left = left.copy()
  let sorted_right = right.copy()
  sorted_left.sort_by(legacy_compare_raw)
  sorted_right.sort_by(legacy_compare_raw)
  for index = 0; index < sorted_left.length(); index = index + 1 {
    if sorted_left[index] != sorted_right[index] {
      return false
    }
  }
  true
}

///|
/// Resolve the declared raw parent frontier against admission-order local IDs.
fn legacy_frontier(
  admitted : Array[@core.RawVersion],
  parents : Array[RawIdentity],
) -> @core.Frontier {
  let local_versions : Array[Int] = []
  for parent in parents {
    let raw = legacy_raw(parent)
    let mut found : Int? = None
    for index = 0; index < admitted.length(); index = index + 1 {
      if admitted[index] == raw {
        found = Some(index)
      }
    }
    guard found is Some(local_version) else { panic() }
    local_versions.push(local_version)
  }
  @core.Frontier::from_array_dedup(local_versions)
}

///|
/// Read visible identities, avoiding branch materialization on the current head.
fn legacy_visible_at(
  document : @document.Document,
  admitted : Array[@core.RawVersion],
  parents : Array[RawIdentity],
  current_frontier : Array[@core.RawVersion],
  current_visible : Array[@core.RawVersion]?,
) -> Array[@core.RawVersion] {
  let raw_parents = parents.map(legacy_raw)
  if legacy_same_frontier(raw_parents, current_frontier) {
    match current_visible {
      Some(visible) => return visible
      None => ()
    }
  }
  let branch = try! document.checkout_branch(legacy_frontier(admitted, parents))
  let visible : Array[@core.RawVersion] = []
  for item in branch.inner_tree().get_visible_items() {
    visible.push(admitted[item.0.0])
  }
  visible
}

///|
/// Lower one CanonicalTextEventV1 into the separately tagged legacy operation.
fn lower_legacy_oracle_event(
  document : @document.Document,
  admitted : Array[@core.RawVersion],
  event : FixtureEvent,
  current_frontier : Array[@core.RawVersion],
  current_visible : Array[@core.RawVersion]?,
) -> @core.Op {
  let parents = event.parents.map(legacy_raw)
  let identity = legacy_raw(event.identity)
  match event.body {
    InsertScalar(position, scalar) => {
      let visible = legacy_visible_at(
        document,
        admitted,
        event.parents,
        current_frontier,
        current_visible,
      )
      if position < 0 || position > visible.length() {
        panic()
      }
      let origin_left = if position == 0 {
        None
      } else {
        Some(visible[position - 1])
      }
      let origin_right = if position == visible.length() {
        None
      } else {
        Some(visible[position])
      }
      @core.Op::insert(
        -1,
        parents,
        identity.agent,
        identity.seq,
        scalar,
        origin_left,
        origin_right,
      )
    }
    DeleteScalar(position) => {
      let visible = legacy_visible_at(
        document,
        admitted,
        event.parents,
        current_frontier,
        current_visible,
      )
      if position < 0 || position >= visible.length() {
        panic()
      }
      @core.Op::delete(
        -1,
        parents,
        identity.agent,
        identity.seq,
        Some(visible[position]),
      )
    }
    Undelete(target) =>
      @core.Op::undelete(
        -1,
        parents,
        identity.agent,
        identity.seq,
        Some(legacy_raw(target)),
      )
  }
}

///|
fn legacy_advance_frontier(
  frontier : Array[@core.RawVersion],
  event : FixtureEvent,
) -> Array[@core.RawVersion] {
  let parents = event.parents.map(legacy_raw)
  let next : Array[@core.RawVersion] = []
  for head in frontier {
    if !parents.contains(head) {
      next.push(head)
    }
  }
  next.push(legacy_raw(event.identity))
  next
}

///|
fn legacy_advance_visible(
  visible : Array[@core.RawVersion],
  event : FixtureEvent,
) -> Array[@core.RawVersion]? {
  match event.body {
    InsertScalar(position, _) => {
      let next : Array[@core.RawVersion] = []
      for index = 0; index < visible.length(); index = index + 1 {
        if index == position {
          next.push(legacy_raw(event.identity))
        }
        next.push(visible[index])
      }
      if position == visible.length() {
        next.push(legacy_raw(event.identity))
      }
      Some(next)
    }
    DeleteScalar(position) => {
      let next : Array[@core.RawVersion] = []
      for index = 0; index < visible.length(); index = index + 1 {
        if index != position {
          next.push(visible[index])
        }
      }
      Some(next)
    }
    Undelete(_) => None
  }
}

///|
fn legacy_identity_json(raw : @core.RawVersion) -> Json {
  Json::object({
    "replica_id": raw.agent.to_json(),
    "sequence": raw.seq.to_json(),
  })
}

///|
fn legacy_optional_identity_json(raw : @core.RawVersion?) -> Json {
  match raw {
    Some(value) => legacy_identity_json(value)
    None => Json::null()
  }
}

///|
fn legacy_operation_json(operation : @core.Op) -> Json {
  let parents : Array[Json] = []
  let sorted_parents = operation.parents()
  sorted_parents.sort_by(fn(a, b) {
    let by_agent = a.agent.compare(b.agent)
    if by_agent != 0 {
      by_agent
    } else {
      a.seq.compare(b.seq)
    }
  })
  for parent in sorted_parents {
    parents.push(legacy_identity_json(parent))
  }
  let (kind, content) = match operation.content() {
    @core.Insert(text) => ("insert", text.to_json())
    @core.Delete => ("delete", Json::null())
    @core.Undelete => ("undelete", Json::null())
  }
  Json::object({
    "id": legacy_identity_json(
      @core.RawVersion(operation.agent(), operation.seq()),
    ),
    "parents": parents.to_json(),
    "kind": kind.to_json(),
    "content": content,
    "origin_left": legacy_optional_identity_json(operation.origin_left()),
    "origin_right": legacy_optional_identity_json(operation.origin_right()),
  })
}

///|
/// Replay a fixed fixture through production Document and emit text-sync v1 JSON.
fn generate_legacy_oracle_history(case_id : String) -> String {
  let fixture = try! generate_required_fixture(case_id)
  let document = @document.Document::new("gate-r0-legacy-oracle")
  let admitted : Array[@core.RawVersion] = []
  let mut current_frontier : Array[@core.RawVersion] = []
  let mut current_visible : Array[@core.RawVersion]? = Some([])
  for identity in fixture.replay_order {
    let mut selected : FixtureEvent? = None
    for event in fixture.events {
      if event.identity == identity {
        selected = Some(event)
      }
    }
    guard selected is Some(event) else { panic() }
    let follows_current = legacy_same_frontier(
      event.parents.map(legacy_raw),
      current_frontier,
    )
    let operation = lower_legacy_oracle_event(
      document, admitted, event, current_frontier, current_visible,
    )
    try! document.apply_remote(operation)
    admitted.push(legacy_raw(event.identity))
    current_frontier = legacy_advance_frontier(current_frontier, event)
    current_visible = if follows_current {
      match current_visible {
        Some(visible) => legacy_advance_visible(visible, event)
        None => None
      }
    } else {
      None
    }
  }
  if document.to_text() != fixture.final_text {
    panic()
  }
  let operations : Array[Json] = []
  for operation in document.get_all_ops() {
    operations.push(legacy_operation_json(operation))
  }
  let heads : Array[Json] = []
  let raw_heads = try! document.get_frontier_raw()
  raw_heads.sort_by(fn(a, b) {
    let by_agent = a.agent.compare(b.agent)
    if by_agent != 0 {
      by_agent
    } else {
      a.seq.compare(b.seq)
    }
  })
  for head in raw_heads {
    heads.push(legacy_identity_json(head))
  }
  Json::object({
    "schema": (1).to_json(),
    "format": "event-graph-walker/text-sync".to_json(),
    "operations": operations.to_json(),
    "heads": heads.to_json(),
  }).stringify()
}
