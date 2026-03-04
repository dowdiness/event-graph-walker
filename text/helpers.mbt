///| Shared helpers for the text package

///|
/// Truncate text to 50 chars for display purposes (used by Show impls).
fn truncate_display(text : String) -> String {
  if text.length() > 50 {
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
}
