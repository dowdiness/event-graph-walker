///| JSON roundtrip tests for OpRun serialization

///|
test "OpRunContent::Inserts JSON roundtrip" {
  let content : OpRunContent = Inserts(['h', 'e', 'l', 'l', 'o'])
  let json = content.to_json()
  let decoded : OpRunContent = @json.from_json(json)
  inspect(decoded == content, content="true")
}

///|
test "OpRunContent::Deletes JSON roundtrip" {
  let content : OpRunContent = Deletes
  let json = content.to_json()
  let decoded : OpRunContent = @json.from_json(json)
  inspect(decoded == content, content="true")
}

///|
test "OpRunContent::Undeletes JSON roundtrip" {
  let content : OpRunContent = Undeletes
  let json = content.to_json()
  let decoded : OpRunContent = @json.from_json(json)
  inspect(decoded == content, content="true")
}

///|
test "OpRun insert run JSON roundtrip" {
  let run : OpRun = {
    start_lv: 0,
    agent: "alice",
    start_seq: 0,
    content: Inserts(['a', 'b', 'c']),
    parents: [],
    origin_left: None,
    origin_right: Some(RawVersion::new("bob", 0)),
    count: 3,
  }
  let json = run.to_json()
  let decoded : OpRun = @json.from_json(json)
  inspect(decoded == run, content="true")
}

///|
test "OpRun delete run JSON roundtrip" {
  let run : OpRun = {
    start_lv: 5,
    agent: "bob",
    start_seq: 3,
    content: Deletes,
    parents: [RawVersion::new("alice", 4)],
    origin_left: Some(RawVersion::new("alice", 2)),
    origin_right: None,
    count: 2,
  }
  let json = run.to_json()
  let decoded : OpRun = @json.from_json(json)
  inspect(decoded == run, content="true")
}

///|
test "OpRun JSON format is compact" {
  let run : OpRun = {
    start_lv: 0,
    agent: "alice",
    start_seq: 0,
    content: Inserts(['h', 'i']),
    parents: [],
    origin_left: None,
    origin_right: None,
    count: 2,
  }
  let json_str = run.to_json().stringify()
  // Inserts should be a string, not array of chars
  inspect(json_str.contains("\"Inserts\":\"hi\""), content="true")
}

///|
test "OpRun JSON rejects count <= 0" {
  let json_str =
    #|{"start_lv":0,"agent":"a","start_seq":0,"content":"Deletes","parents":[],"origin_left":null,"origin_right":null,"count":0}
  let result : Result[OpRun, _] = Ok(@json.from_json(@json.parse(json_str))) catch {
    e => Err(e)
  }
  inspect(result is Err(_), content="true")
}

///|
test "OpRun JSON rejects Inserts length mismatch" {
  let json_str =
    #|{"start_lv":0,"agent":"a","start_seq":0,"content":{"Inserts":"hi"},"parents":[],"origin_left":null,"origin_right":null,"count":5}
  let result : Result[OpRun, _] = Ok(@json.from_json(@json.parse(json_str))) catch {
    e => Err(e)
  }
  inspect(result is Err(_), content="true")
}
