///| JSON serialization for OpRun types.
///
/// OpRunContent::Inserts(Array[Char]) serializes as {"Inserts": "hello"}
/// (chars joined to string for compact JSON). Deletes/Undeletes as strings.

///|
pub impl ToJson for OpRunContent with to_json(self) {
  match self {
    Inserts(chars) => {
      let text = String::from_array(chars)
      Json::object({ "Inserts": text.to_json() })
    }
    Deletes => Json::string("Deletes")
    Undeletes => Json::string("Undeletes")
  }
}

///|
pub impl @json.FromJson for OpRunContent with from_json(json, path) {
  match json {
    Json::String("Deletes") => Deletes
    Json::String("Undeletes") => Undeletes
    Json::Object(m) =>
      match m.get("Inserts") {
        Some(Json::String(text)) => {
          let chars : Array[Char] = []
          for ch in text {
            chars.push(ch)
          }
          Inserts(chars)
        }
        _ => raise @json.JsonDecodeError((path, "expected Inserts string"))
      }
    _ =>
      raise @json.JsonDecodeError(
        (path, "expected OpRunContent string or object"),
      )
  }
}

///|
pub impl ToJson for OpRun with to_json(self) {
  Json::object({
    "start_lv": self.start_lv.to_json(),
    "agent": self.agent.to_json(),
    "start_seq": self.start_seq.to_json(),
    "content": self.content.to_json(),
    "parents": self.parents.to_json(),
    "origin_left": self.origin_left.to_json(),
    "origin_right": self.origin_right.to_json(),
    "count": self.count.to_json(),
  })
}

///|
pub impl @json.FromJson for OpRun with from_json(json, path) {
  match json {
    Json::Object(m) => {
      let start_lv : Int = @json.from_json(
        m.get("start_lv").unwrap_or(Json::null()),
        path~,
      )
      let agent : String = @json.from_json(
        m.get("agent").unwrap_or(Json::null()),
        path~,
      )
      let start_seq : Int = @json.from_json(
        m.get("start_seq").unwrap_or(Json::null()),
        path~,
      )
      let content : OpRunContent = @json.from_json(
        m.get("content").unwrap_or(Json::null()),
        path~,
      )
      let parents : Array[RawVersion] = @json.from_json(
        m.get("parents").unwrap_or(Json::null()),
        path~,
      )
      let origin_left : RawVersion? = @json.from_json(
        m.get("origin_left").unwrap_or(Json::null()),
        path~,
      )
      let origin_right : RawVersion? = @json.from_json(
        m.get("origin_right").unwrap_or(Json::null()),
        path~,
      )
      let count : Int = @json.from_json(
        m.get("count").unwrap_or(Json::null()),
        path~,
      )
      // Validate run invariants
      if count <= 0 {
        raise @json.JsonDecodeError(
          (path, "OpRun count must be positive, got \{count}"),
        )
      }
      match content {
        Inserts(chars) =>
          if chars.length() != count {
            raise @json.JsonDecodeError(
              (
                path,
                "OpRun Inserts length (\{chars.length()}) != count (\{count})",
              ),
            )
          }
        Deletes | Undeletes => ()
      }
      {
        start_lv,
        agent,
        start_seq,
        content,
        parents,
        origin_left,
        origin_right,
        count,
      }
    }
    _ => raise @json.JsonDecodeError((path, "expected OpRun object"))
  }
}
