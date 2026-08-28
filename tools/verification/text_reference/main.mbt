///|
/// PROTOTYPE: replay one command trace through the public text façade.
struct Driver {
  documents : Array[@text.TextState]
  indexes : Map[String, Int]
  mut step : Int
}

///|
fn Driver::Driver() -> Driver {
  { documents: [], indexes: Map([]), step: 0 }
}

///|
fn Driver::required_index(
  self : Driver,
  name : String,
  line_number : Int,
) -> Int raise Failure {
  match self.indexes.get(name) {
    Some(index) => index
    None =>
      raise Failure::Failure("line \{line_number}: unknown replica \{name}")
  }
}

///|
fn Driver::emit(self : Driver) -> Unit {
  let fields = [self.step.to_string()]
  for document in self.documents {
    fields.push(document.text())
  }
  println(fields.join("\t"))
}

///|
fn Driver::apply_line(
  self : Driver,
  line : StringView,
  line_number : Int,
) -> Unit raise {
  let parts : Array[String] = line
    .split(" ")
    .map(part => part.to_owned())
    .collect()
  match parts {
    ["replica", name] => {
      if self.indexes.get(name) is Some(_) {
        raise Failure::Failure("line \{line_number}: duplicate replica \{name}")
      }
      let index = self.documents.length()
      self.indexes[name] = index
      self.documents.push(@text.TextState::new(name))
    }
    ["insert", name, raw_position, content] => {
      let index = self.required_index(name, line_number)
      let position : Int = @strconv.from_str(raw_position)
      self.documents[index].insert(@text.Pos::at(position), content)
    }
    ["delete", name, raw_position] => {
      let index = self.required_index(name, line_number)
      let position : Int = @strconv.from_str(raw_position)
      self.documents[index].delete(@text.Pos::at(position))
    }
    ["sync", from, to] | ["sync-duplicate", from, to] => {
      let from_index = self.required_index(from, line_number)
      let to_index = self.required_index(to, line_number)
      let message = self.documents[from_index].sync().export_all()
      let report = self.documents[to_index].sync().apply(message)
      if parts[0] == "sync-duplicate" &&
        (
          report.applied_operations() != 0 ||
          report.duplicate_operations() == 0 ||
          report.pending_operations() != 0
        ) {
        raise Failure::Failure(
          "line \{line_number}: duplicate sync was not an idempotent admission",
        )
      }
    }
    ["expect-converged", first, .. rest] => {
      let first_index = self.required_index(first, line_number)
      let expected_text = self.documents[first_index].text()
      let expected_version = self.documents[first_index].version()
      for name in rest {
        let index = self.required_index(name, line_number)
        if self.documents[index].text() != expected_text ||
          self.documents[index].version() != expected_version ||
          self.documents[index].sync().pending_sync_count() != 0 {
          raise Failure::Failure(
            "line \{line_number}: replica \{name} did not converge",
          )
        }
      }
    }
    _ => raise Failure::Failure("line \{line_number}: invalid command")
  }
  self.step += 1
  self.emit()
}

///|
struct CorpusCase {
  expected : String
  message : Json
} derive(FromJson)

///|
fn validate_corpus_checkpoint(
  document : @text.TextState,
  expected : String,
  context : String,
) -> Unit raise {
  let version = document.version()
  let decoded = @text.Version::from_json_string(version.to_json_string())
  let view = document.checkout(decoded)
  if decoded != version || view.version() != version || view.text() != expected {
    raise Failure::Failure("\{context}: Version round-trip or checkout diverged")
  }
}

///|
fn replay_corpus(encoded : String) -> Unit raise {
  let cases : Array[CorpusCase] = @json.from_json(@json.parse(encoded))
  for index, case in cases {
    let document = @text.TextState::new("corpus-receiver-\{index}")
    let message = @text.SyncMessage::from_json_string(case.message.stringify())
    let report = document.sync().apply(message) catch {
        error =>
          raise Failure::Failure(
            "corpus run \{index}: sync failed: \{error.debug()}",
          )
      }
    if report.pending_operations() != 0 {
      raise Failure::Failure(
        "corpus run \{index}: \{report.pending_operations()} pending operations",
      )
    }
    let actual = document.text()
    if actual != case.expected {
      raise Failure::Failure(
        "corpus run \{index}: expected \{@debug.to_string(case.expected)}, " +
        "got \{@debug.to_string(actual)}",
      )
    }
    validate_corpus_checkpoint(
      document,
      case.expected,
      "corpus run \{index}",
    )
  }
  println(
    "PASS: \{cases.length()} official conformance runs matched (full batch)",
  )
}

///|
struct CorpusMessage {
  operations : Array[Json]
  heads : Array[Json]
} derive(FromJson)

///|
fn single_operation_message(operation : Json, heads : Array[Json]) -> String {
  Json::object({
    "schema": (2).to_json(),
    "format": "event-graph-walker/text-sync".to_json(),
    "operations": [operation].to_json(),
    "heads": heads.to_json(),
  }).stringify()
}

///|
fn replay_corpus_reversed_duplicates(encoded : String) -> Unit raise {
  let cases : Array[CorpusCase] = @json.from_json(@json.parse(encoded))
  for index, case in cases {
    let wire : CorpusMessage = @json.from_json(case.message)
    let document = @text.TextState::new("corpus-receiver-reversed-\{index}")
    let mut delivery = wire.operations.length() - 1
    while delivery >= 0 {
      let heads = if delivery == 0 { wire.heads } else { [] }
      let message = @text.SyncMessage::from_json_string(
        single_operation_message(wire.operations[delivery], heads),
      )
      let _first = document.sync().apply(message) catch {
          error =>
            raise Failure::Failure(
              "reversed corpus run \{index}, operation \{delivery}: sync failed: " +
              error.debug(),
            )
        }
      let duplicate = document.sync().apply(message) catch {
          error =>
            raise Failure::Failure(
              "reversed corpus run \{index}, operation \{delivery}: duplicate failed: " +
              error.debug(),
            )
        }
      if duplicate.applied_operations() != 0 ||
        duplicate.duplicate_operations() == 0 {
        raise Failure::Failure(
          "reversed corpus run \{index}, operation \{delivery}: duplicate was not idempotent",
        )
      }
      delivery = delivery - 1
    }
    if document.sync().pending_sync_count() != 0 ||
      document.text() != case.expected {
      raise Failure::Failure(
        "reversed corpus run \{index}: final pending/text check failed",
      )
    }
    validate_corpus_checkpoint(
      document,
      case.expected,
      "reversed corpus run \{index}",
    )
  }
  println(
    "PASS: \{cases.length()} official conformance runs matched " +
    "(reversed duplicate delivery)",
  )
}

///|
async fn main {
  let args = @env.args()
  if args is [_, "--corpus", corpus_path] {
    replay_corpus(@fs.read_file(corpus_path).text())
    return
  }
  if args is [_, "--corpus-reversed-duplicates", corpus_path] {
    replay_corpus_reversed_duplicates(@fs.read_file(corpus_path).text())
    return
  }
  guard args is [_, trace_path] else {
    raise Failure::Failure(
      "usage: moon run . -- TRACE | --corpus TRANSLATED_JSON | " +
      "--corpus-reversed-duplicates TRANSLATED_JSON",
    )
  }
  let trace = @fs.read_file(trace_path).text()
  let driver = Driver()
  for index, raw_line in trace.split("\n") {
    let line = raw_line.trim()
    if line.length() == 0 || line[0] == '#' {
      continue
    }
    driver.apply_line(line, index + 1)
  }
}
