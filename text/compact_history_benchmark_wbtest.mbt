///|
/// Setup is outside the timed closures; both lanes receive identical archive bytes.
fn compact_benchmark_archive(churn : Bool) -> (String, String) raise {
  let count = if churn { 5000 } else { 100000 }
  let pattern = "# Header\n- item `code` | 0123456789\nText [link](example) **bold**\n"
  let chars = pattern.to_array()
  let content = StringBuilder()
  for i = 0; i < count; i = i + 1 {
    content.write_char(chars[i % chars.length()])
  }
  let source = TextState::new("benchmark-seed")
  source.insert(Pos::at(0), content.to_string())
  if churn {
    let operations : Array[@core.Op] = []
    for i = 0; i < 90000; i = i + 1 {
      let parent = if i == 0 {
        @core.RawVersion("benchmark-seed", count - 1)
      } else {
        @core.RawVersion("benchmark-churn", i - 1)
      }
      let target = Some(@core.RawVersion("benchmark-seed", i / 2 % count))
      operations.push(
        if i % 2 == 0 {
          @core.Op::delete(-1, [parent], "benchmark-churn", i, target)
        } else {
          @core.Op::undelete(-1, [parent], "benchmark-churn", i, target)
        },
      )
      if operations.length() == 10000 {
        ignore(
          source
          .sync()
          .apply(
            SyncMessage::SyncMessage(
              operations,
              [@core.RawVersion("benchmark-churn", i)],
              None,
            ),
          ),
        )
        operations.clear()
      }
    }
  }
  (source.export_compact_experimental(), source.version().to_json_string())
}

///|
test "compact restore 100k operations direct" (b : @bench.T) {
  let (archive, version) = try! compact_benchmark_archive(false)
  b.bench(fn() {
    b.keep(
      (try! TextState::restore_compact_direct_experimental(
        archive, "fresh", version,
      )).text(),
    )
  })
}

///|
test "compact restore 100k operations ordinary change application" (
  b : @bench.T,
) {
  let (archive, version) = try! compact_benchmark_archive(false)
  b.bench(fn() {
    b.keep(
      (try! compact_restore_replay_for_test(archive, "fresh", version)).text(),
    )
  })
}

///|
test "compact restore 95k operations 5k visible direct" (b : @bench.T) {
  let (archive, version) = try! compact_benchmark_archive(true)
  b.bench(fn() {
    b.keep(
      (try! TextState::restore_compact_direct_experimental(
        archive, "fresh", version,
      )).text(),
    )
  })
}

///|
test "compact restore 95k operations 5k visible ordinary change application" (
  b : @bench.T,
) {
  let (archive, version) = try! compact_benchmark_archive(true)
  b.bench(fn() {
    b.keep(
      (try! compact_restore_replay_for_test(archive, "fresh", version)).text(),
    )
  })
}
