///|
test "10k sequential container records have linear preparation comparisons" {
  let records : Array[SyncOpRecord] = []
  for sequence = 0; sequence < 10_000; sequence = sequence + 1 {
    let version = @core.RawVersion::new("alice", sequence)
    let parents = if sequence == 0 {
      []
    } else {
      [@core.RawVersion::new("alice", sequence - 1)]
    }
    records.push(
      Tree({
        version,
        parents,
        op: @mt.SetProperty({
          timestamp: sequence,
          target: { agent: "node", counter: 0 },
          key: "k",
          value: sequence.to_string(),
          agent: "alice",
        }),
      }),
    )
  }
  let (ordered, comparisons) = try! canonical_sync_order_with_block_creates(
    records.rev(),
    Map([]),
  )
  inspect(ordered.length(), content="10000")
  inspect(comparisons <= 10_000, content="true")
}

///|
test "text ordering uses block-create sequence instead of node counter" {
  let alice_predecessor = SyncOpRecord::Tree({
    version: @core.RawVersion::new("alice", 0),
    parents: [],
    op: @mt.Move({
      timestamp: 0,
      target: { agent: "alice", counter: 0 },
      new_parent: @mt.root_id,
      position: @fi.FractionalIndex::between(left=None, right=None),
      agent: "alice",
    }),
  })
  let ghost_prior_create = SyncOpRecord::Tree({
    version: @core.RawVersion::new("ghost", 0),
    parents: [],
    op: @mt.Move({
      timestamp: 0,
      target: { agent: "ghost", counter: 99 },
      new_parent: @mt.root_id,
      position: @fi.FractionalIndex::between(left=None, right=None),
      agent: "ghost",
    }),
  })
  let ghost_prior_property = SyncOpRecord::Tree({
    version: @core.RawVersion::new("ghost", 1),
    parents: [@core.RawVersion::new("ghost", 0)],
    op: @mt.SetProperty({
      timestamp: 1,
      target: { agent: "ghost", counter: 99 },
      key: "prior",
      value: "operation",
      agent: "ghost",
    }),
  })
  let block_create = SyncOpRecord::Tree({
    version: @core.RawVersion::new("ghost", 2),
    parents: [@core.RawVersion::new("ghost", 1)],
    op: @mt.Move({
      timestamp: 2,
      target: { agent: "ghost", counter: 0 },
      new_parent: @mt.root_id,
      position: @fi.FractionalIndex::between(left=None, right=None),
      agent: "ghost",
    }),
  })
  let text = SyncOpRecord::Text({
    version: @core.RawVersion::new("alice", 1),
    parents: [@core.RawVersion::new("alice", 0)],
    block: { agent: "ghost", counter: 0 },
    op: Insert({
      id: @core.RawVersion::new("alice", 1),
      origin_left: None,
      origin_right: None,
      content: "A",
      timestamp: 1,
      agent: "alice",
    }),
  })
  let records = [
    text, block_create, ghost_prior_property, ghost_prior_create, alice_predecessor,
  ]
  let known_records : Map[String, SyncOpRecord] = Map([])
  for record in records {
    known_records[sync_record_key(record)] = record
  }
  let ordered = try! canonical_sync_order_with_block_creates(
      records,
      sync_block_create_versions(known_records),
    ).0
  let mut block_index = -1
  let mut text_index = -1
  for index, record in ordered {
    if sync_record_version(record) == @core.RawVersion::new("ghost", 2) {
      block_index = index
    }
    if sync_record_version(record) == @core.RawVersion::new("alice", 1) {
      text_index = index
    }
  }
  inspect(block_index < text_index, content="true")
}
