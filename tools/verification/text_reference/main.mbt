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
async fn main {
  let args = @env.args()
  guard args.length() == 2 else {
    raise Failure::Failure("usage: moon run . -- TRACE")
  }
  let trace = @fs.read_file(args[1]).text()
  let driver = Driver()
  for index, raw_line in trace.split("\n") {
    let line = raw_line.trim()
    if line.length() == 0 || line[0] == '#' {
      continue
    }
    driver.apply_line(line, index + 1)
  }
}
