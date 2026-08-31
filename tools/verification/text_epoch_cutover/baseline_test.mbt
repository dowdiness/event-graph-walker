///|
test "baseline pages converge through public text sync" {
  let baseline = try! @text_epoch_cutover_verification.Baseline::build(
    "a😀bc界d",
    baseline_agent="baseline:2",
    chunk_scalars=2,
  )
  inspect(baseline.page_count(), content="3")
  let pages = baseline.page_json()
  for page in pages {
    let message = try! @text.SyncMessage::from_json_string(page)
    inspect(message.op_count(), content="2")
  }
  ignore(pages.pop())
  inspect(baseline.page_count(), content="3")
  let receiver = try! baseline.apply_to("receiver")
  inspect(receiver.text(), content="a😀bc界d")
  assert_eq(receiver.version(), baseline.version())
}
