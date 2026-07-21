///| Focused JSON tests for RawVersion decoding

///|
test "RawVersion JSON roundtrip preserves wire shape" {
  let version = RawVersion::new("alice", 7)
  let decoded : RawVersion = @json.from_json(version.to_json())
  inspect(decoded == version, content="true")
  inspect(
    version.to_json().stringify(),
    content="{\"agent\":\"alice\",\"seq\":7}",
  )
}

///|
test "RawVersion JSON rejects empty agent" {
  let result : Result[RawVersion, _] = Ok(
    @json.from_json(@json.parse("{\"agent\":\"\",\"seq\":0}")),
  ) catch {
    e => Err(e)
  }
  inspect(result is Err(_), content="true")
}

///|
test "RawVersion JSON rejects negative seq" {
  let result : Result[RawVersion, _] = Ok(
    @json.from_json(@json.parse("{\"agent\":\"alice\",\"seq\":-1}")),
  ) catch {
    e => Err(e)
  }
  inspect(result is Err(_), content="true")
}
