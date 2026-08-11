///| Benchmarks for the test-only text materializer boundary.

///|
fn build_replica_text_authority(count : Int) -> Document {
  let document = Document::new("materializer-benchmark")
  for position in 0..<count {
    ignore(
      document.insert(position, "x") catch {
        _ => abort("materializer fixture construction failed")
      },
    )
  }
  document
}

///|
test "bench: text materializer attach replay (100 operations)" (b : @bench.T) {
  let authority = build_replica_text_authority(100)
  b.bench(
    fn() {
      let session = ReplicaTextSession::attach(authority, "materializer-page") catch {
        _ => abort("materializer attach failed")
      }
      b.keep(session.replayed_operations())
    },
    count=1,
  )
}

///|
test "bench: text materializer attach replay (1000 operations)" (b : @bench.T) {
  let authority = build_replica_text_authority(1000)
  b.bench(
    fn() {
      let session = ReplicaTextSession::attach(authority, "materializer-page") catch {
        _ => abort("materializer attach failed")
      }
      b.keep(session.replayed_operations())
    },
    count=1,
  )
}
