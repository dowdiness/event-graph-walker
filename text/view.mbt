///| TextView - Read-only historical view of a document

///|
/// A read-only view of the document at a specific version
pub(all) struct TextView {
  priv branch : @branch.Branch
}

///|
/// Wrap a Branch as a read-only TextView.
///
/// Prefer `TextDoc::checkout(version)` over calling this directly;
/// this constructor is exposed for advanced use-cases where a Branch
/// has already been constructed (e.g. from `Branch::checkout` or
/// `Branch::advance`).
pub fn TextView::from_branch(branch : @branch.Branch) -> TextView {
  TextView::{ branch, }
}

///|
/// Get the text content at this version
pub fn TextView::text(self : TextView) -> String {
  self.branch.to_text()
}

///|
/// Get the version of this view
pub fn TextView::version(self : TextView) -> Version {
  Version::from_frontier(self.branch.get_frontier())
}

///|
/// Get the number of visible characters at this version
pub fn TextView::len(self : TextView) -> Int {
  self.branch.visible_count()
}

///|
/// Iterates over text runs.
/// For a plain text view, this yields a single run containing all text.
/// Future styled-text support would yield multiple runs with different attributes.
pub fn TextView::runs(self : TextView) -> Iter[String] {
  let text = self.text()
  if text.is_empty() {
    Iter::empty()
  } else {
    [text].iter()
  }
}

///|
pub impl Show for TextView with output(self, logger) {
  logger.write_string("TextView { text: \"")
  let text = self.text()
  let display_text = if text.length() > 50 {
    text
    .iter()
    .take(50)
    .fold(init=StringBuilder::new(), fn(sb, c) {
      sb.write_char(c)
      sb
    })
    .to_string() +
    "..."
  } else {
    text
  }
  logger.write_string(display_text)
  logger.write_string("\", version: ")
  self.version().to_frontier().output(logger)
  logger.write_string(" }")
}
