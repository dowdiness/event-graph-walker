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
  }
  println("PASS: \{cases.length()} official conformance runs matched")
}

///|
async fn main {
  let args = @env.args()
  if args is [_, "--corpus", corpus_path] {
    replay_corpus(@fs.read_file(corpus_path).text())
    return
  }
  guard args is [_, trace_path] else {
    raise Failure::Failure(
      "usage: moon run . -- TRACE | --corpus TRANSLATED_JSON",
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
