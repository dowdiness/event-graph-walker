///| JSON serialization for OpRun types.
///
/// OpRunContent::Inserts(Array[Char]) serializes as {"Inserts": "hello"}
/// (chars joined to string for compact JSON). Deletes/Undeletes as strings.

///|
pub impl ToJson for OpRunContent with fn to_json(self) {
  match self {
    Inserts(chars) => {
      let text = String::from_array(chars)
      Json::object({ "Inserts": Json(text) })
    }
    Deletes => Json::string("Deletes")
    Undeletes => Json::string("Undeletes")
  }
}

///|
pub impl @json.FromJson for OpRunContent with fn from_json(json, path) {
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
pub impl ToJson for OpRun with fn to_json(self) {
  Json::object({
    "start_lv": Json(self.start_lv),
    "agent": Json(self.agent),
    "start_seq": Json(self.start_seq),
    "content": self.content.to_json(),
    "parents": Json(self.parents),
    "origin_left": Json(self.origin_left),
    "origin_right": Json(self.origin_right),
    "count": Json(self.count),
  })
}

///|
pub impl @json.FromJson for OpRun with fn from_json(json, path) {
  match json {
    Json::Object(m) => {
      let start_lv : Int = @json.from_json(
        m.get("start_lv").unwrap_or(Json::null()),
        path=path.add_key("start_lv"),
      )
      let agent : String = @json.from_json(
        m.get("agent").unwrap_or(Json::null()),
        path=path.add_key("agent"),
      )
      let start_seq : Int = @json.from_json(
        m.get("start_seq").unwrap_or(Json::null()),
        path=path.add_key("start_seq"),
      )
      let content : OpRunContent = @json.from_json(
        m.get("content").unwrap_or(Json::null()),
        path=path.add_key("content"),
      )
      let parents : Array[RawVersion] = @json.from_json(
        m.get("parents").unwrap_or(Json::null()),
        path=path.add_key("parents"),
      )
      let origin_left : RawVersion? = @json.from_json(
        m.get("origin_left").unwrap_or(Json::null()),
        path=path.add_key("origin_left"),
      )
      let origin_right : RawVersion? = @json.from_json(
        m.get("origin_right").unwrap_or(Json::null()),
        path=path.add_key("origin_right"),
      )
      let count : Int = @json.from_json(
        m.get("count").unwrap_or(Json::null()),
        path=path.add_key("count"),
      )
      if agent.is_empty() {
        raise @json.JsonDecodeError(
          (path.add_key("agent"), "OpRun agent must not be empty"),
        )
      }
      if start_lv < 0 {
        raise @json.JsonDecodeError(
          (path.add_key("start_lv"), "OpRun start_lv must be non-negative"),
        )
      }
      if start_seq < 0 {
        raise @json.JsonDecodeError(
          (path.add_key("start_seq"), "OpRun start_seq must be non-negative"),
        )
      }
      if count <= 0 {
        raise @json.JsonDecodeError(
          (path.add_key("count"), "OpRun count must be positive, got \{count}"),
        )
      }
      let last_offset = count - 1
      let last_lv = start_lv + last_offset
      if last_lv < start_lv {
        raise @json.JsonDecodeError(
          (
            path.add_key("start_lv"),
            "OpRun start_lv/count overflows during decompression",
          ),
        )
      }
      let last_seq = start_seq + last_offset
      if last_seq < start_seq {
        raise @json.JsonDecodeError(
          (
            path.add_key("start_seq"),
            "OpRun start_seq/count overflows during decompression",
          ),
        )
      }
      match content {
        Inserts(chars) =>
          if count != 1 && chars.length() != count {
            raise @json.JsonDecodeError(
              (
                path.add_key("content"),
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

// ---------------------------------------------------------------------------
// Explicit trait-method promotions (E0079).
// `#doc(hidden)` keeps these out of the generated interface while preserving
// dot-syntax and cross-package use.
// ---------------------------------------------------------------------------

///|
#doc(hidden)
pub extend OpRun with @json.FromJson::{from_json}

///|
#doc(hidden)
pub extend OpRun with ToJson::{to_json}

///|
#doc(hidden)
pub extend OpRunContent with @json.FromJson::{from_json}

///|
#doc(hidden)
pub extend OpRunContent with ToJson::{to_json}
