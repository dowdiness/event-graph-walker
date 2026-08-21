///| Test-only text materializer prototype over a retained Document authority.

///|
test "prototype: fresh text session replays, edits, and publishes" {
  let authority = Document::new("authority-text")
  ignore(try! authority.insert(0, "hello"))

  let page = try! ReplicaTextSession::attach(authority, "page-text")
  assert_eq(page.text(), "hello")
  assert_eq(page.replayed_operations(), 5)

  let operation = try! page.insert(5, "!")
  assert_eq(operation.agent(), "page-text")
  assert_eq(page.text(), "hello!")
  assert_eq(try! page.publish(), 1)
  assert_eq(authority.to_text(), "hello!")

  let second = try! ReplicaTextSession::attach(authority, "second-page")
  assert_eq(second.text(), "hello!")
  assert_eq(second.replayed_operations(), 6)
}

///|
test "prototype: text session pulls an authority advance incrementally" {
  let authority = Document::new("authority-pull")
  ignore(try! authority.insert(0, "a"))
  let page = try! ReplicaTextSession::attach(authority, "page-pull")

  ignore(try! authority.insert(1, "b"))
  assert_eq(try! page.pull(), 1)
  assert_eq(page.text(), "ab")
  assert_eq(page.replayed_operations(), 1)
}

///|
test "prototype: duplicate publish is idempotent" {
  let authority = Document::new("authority-duplicate")
  let page = try! ReplicaTextSession::attach(authority, "page-duplicate")
  ignore(try! page.insert(0, "x"))

  assert_eq(try! page.publish(), 1)
  assert_eq(try! page.publish(), 0)
  assert_eq(authority.to_text(), "x")
}

///|
test "prototype: conflicting identity is not silently filtered" {
  let authority = Document::new("authority-conflict")
  let admitted = try! authority.insert(0, "a")
  let conflict = @core.Op::insert(
    -1,
    [],
    admitted.agent(),
    admitted.seq(),
    "different",
    None,
    None,
  )
  let candidates = replica_text_unadmitted_operations(authority, [conflict])
  assert_eq(candidates.length(), 1)
}

///|
test "prototype: concurrent authority advance merges by raw identity" {
  let authority = Document::new("authority-rebase")
  ignore(try! authority.insert(0, "a"))
  let page = try! ReplicaTextSession::attach(authority, "page-rebase")

  ignore(try! page.insert(1, "p"))
  ignore(try! authority.insert(1, "q"))
  assert_eq(try! page.publish(), 1)
  assert_eq(try! page.pull(), 1)
  assert_eq(page.text(), authority.to_text())
  assert_eq(page.replayed_operations(), 1)
}

///|
priv struct ReplicaTextSession {
  authority : Document
  session : Document
  replayed_operations : Int
}

///|
fn ReplicaTextSession::attach(
  authority : Document,
  agent_id : String,
) -> ReplicaTextSession raise DocumentError {
  let session = Document::new(agent_id)
  let operations = authority.get_all_ops()
  if !operations.is_empty() {
    session.merge_remote(operations, authority.get_frontier_raw())
  }
  { authority, session, replayed_operations: operations.length() }
}

///|
fn ReplicaTextSession::text(self : ReplicaTextSession) -> String {
  self.session.to_text()
}

///|
fn ReplicaTextSession::replayed_operations(self : ReplicaTextSession) -> Int {
  self.replayed_operations
}

///|
fn ReplicaTextSession::insert(
  self : ReplicaTextSession,
  position : Int,
  text : String,
) -> @core.Op raise DocumentError {
  self.session.insert(position, text)
}

///|
fn ReplicaTextSession::publish(
  self : ReplicaTextSession,
) -> Int raise DocumentError {
  let operations = replica_text_unadmitted_operations(
    self.authority,
    self.session.get_all_ops(),
  )
  if operations.is_empty() {
    return 0
  }
  self.authority.merge_remote(operations, self.session.get_frontier_raw())
  operations.length()
}

///|
fn ReplicaTextSession::pull(
  self : ReplicaTextSession,
) -> Int raise DocumentError {
  let operations = replica_text_unadmitted_operations(
    self.session,
    self.authority.get_all_ops(),
  )
  if operations.is_empty() {
    return 0
  }
  self.session.merge_remote(operations, self.authority.get_frontier_raw())
  operations.length()
}

///|
/// Compare causal identity, not destination-local LVs.
fn replica_text_unadmitted_operations(
  destination : Document,
  source_operations : Array[@core.Op],
) -> Array[@core.Op] {
  let known : Map[@core.RawVersion, @core.Op] = Default::default()
  for operation in destination.get_all_ops() {
    known.set(@core.RawVersion(operation.agent(), operation.seq()), operation)
  }
  source_operations.filter(operation => {
    let raw = @core.RawVersion(operation.agent(), operation.seq())
    match known.get(raw) {
      None => true
      Some(existing) =>
        !replica_text_same_logical_operation(existing, operation)
    }
  })
}

///|
/// Match OpLog's identity rule while ignoring destination-local LV.
fn replica_text_same_logical_operation(
  left : @core.Op,
  right : @core.Op,
) -> Bool {
  let left_parents = left.parents()
  let right_parents = right.parents()
  left_parents.sort()
  right_parents.sort()
  left.agent() == right.agent() &&
  left.seq() == right.seq() &&
  left_parents == right_parents &&
  left.content() == right.content() &&
  left.origin_left() == right.origin_left() &&
  left.origin_right() == right.origin_right()
}
