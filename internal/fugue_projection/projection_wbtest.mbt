///|
test "visibility encoding is total at maximum LV" {
  let maximum = @fugue.Lv(2147483647)
  let visible = encode_visible(maximum)
  inspect(is_became_visible(visible), content="true")
  inspect(visibility_identity(visible), content="Lv(2147483647)")
  let hidden = encode_hidden(maximum)
  inspect(is_became_hidden(hidden), content="true")
  inspect(visibility_identity(hidden), content="Lv(2147483647)")
  let no_change = encode_unchanged()
  inspect(is_became_visible(no_change), content="false")
  inspect(is_became_hidden(no_change), content="false")
}
