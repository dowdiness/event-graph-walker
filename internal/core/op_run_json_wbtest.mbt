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

///|
test "OpRun JSON roundtrip protects nested identities" {
  let run : OpRun = {
    start_lv: 9,
    agent: "alice",
    start_seq: 11,
    content: Inserts(['a', 'b']),
    parents: [RawVersion::new("parent", 4)],
    origin_left: Some(RawVersion::new("left", 5)),
    origin_right: Some(RawVersion::new("right", 6)),
    count: 2,
  }
  let decoded : OpRun = @json.from_json(run.to_json())
  inspect(decoded == run, content="true")
}

///|
test "OpRun JSON rejects empty agent" {
  let json_str =
    #|{"start_lv":0,"agent":"","start_seq":0,"content":"Deletes","parents":[],"origin_left":null,"origin_right":null,"count":1}
  let result : Result[OpRun, _] = Ok(@json.from_json(@json.parse(json_str))) catch {
    e => Err(e)
  }
  inspect(result is Err(_), content="true")
}

///|
test "OpRun JSON rejects negative start_seq" {
  let json_str =
    #|{"start_lv":0,"agent":"alice","start_seq":-1,"content":"Deletes","parents":[],"origin_left":null,"origin_right":null,"count":1}
  let result : Result[OpRun, _] = Ok(@json.from_json(@json.parse(json_str))) catch {
    e => Err(e)
  }
  inspect(result is Err(_), content="true")
}

///|
test "OpRun JSON rejects negative start_lv" {
  let json_str =
    #|{"start_lv":-1,"agent":"alice","start_seq":0,"content":"Deletes","parents":[],"origin_left":null,"origin_right":null,"count":1}
  let result : Result[OpRun, _] = Ok(@json.from_json(@json.parse(json_str))) catch {
    e => Err(e)
  }
  inspect(result is Err(_), content="true")
}

///|
test "OpRun JSON rejects start_lv decompression overflow" {
  let json_str =
    #|{"start_lv":2147483647,"agent":"alice","start_seq":0,"content":"Deletes","parents":[],"origin_left":null,"origin_right":null,"count":2}
  let result : Result[OpRun, _] = Ok(@json.from_json(@json.parse(json_str))) catch {
    e => Err(e)
  }
  inspect(result is Err(_), content="true")
}

///|
test "OpRun JSON rejects invalid nested parent identity" {
  let json_str =
    #|{"start_lv":0,"agent":"alice","start_seq":0,"content":"Deletes","parents":[{"agent":"","seq":0}],"origin_left":null,"origin_right":null,"count":1}
  let result : Result[OpRun, _] = Ok(@json.from_json(@json.parse(json_str))) catch {
    e => Err(e)
  }
  inspect(result is Err(_), content="true")
}

///|
test "OpRun JSON rejects invalid nested origin identity" {
  let json_str =
    #|{"start_lv":0,"agent":"alice","start_seq":0,"content":"Deletes","parents":[],"origin_left":null,"origin_right":{"agent":"right","seq":-1},"count":1}
  let result : Result[OpRun, _] = Ok(@json.from_json(@json.parse(json_str))) catch {
    e => Err(e)
  }
  inspect(result is Err(_), content="true")
}

///|
test "OpRun JSON rejects sequence decompression overflow" {
  let json_str =
    #|{"start_lv":0,"agent":"alice","start_seq":2147483647,"content":"Deletes","parents":[],"origin_left":null,"origin_right":null,"count":2}
  let result : Result[OpRun, _] = Ok(@json.from_json(@json.parse(json_str))) catch {
    e => Err(e)
  }
  inspect(result is Err(_), content="true")
}
