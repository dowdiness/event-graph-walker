///|
/// Capture/oracle-only production history bytes for the provider envelope.
/// Candidate validation never calls this helper or decodes these bytes.
fn legacy_oracle_history_bytes(fixture : GeneratedFixture) -> Bytes {
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
  raw_heads.sort_by(legacy_compare_raw)
  for head in raw_heads {
    heads.push(legacy_identity_json(head))
  }
  let json = Json::object({
    "schema": (1).to_json(),
    "format": "event-graph-walker/text-sync".to_json(),
    "operations": operations.to_json(),
    "heads": heads.to_json(),
  }).stringify()
  let message = try! @text.SyncMessage::from_json_string(json)
  message.to_canonical_bytes()
}
