///|
test "sparse subtraction work ignores numerical hole length" {
  let left = HaveSummary::{
    entries: [
      {
        agent: "a",
        ranges: [
          { start: 0U, end: 1U, },
          { start: 2147483647U, end: 2147483648U, },
        ],
      },
    ],
  }
  let right = HaveSummary::{
    entries: [{ agent: "a", ranges: [{ start: 0U, end: 1U, }], }],
  }
  let (difference, agent_steps, range_steps) = left.subtract_counted(right)
  assert_eq(difference.entries.length(), 1)
  assert_eq(difference.entries[0].agent, "a")
  assert_eq(difference.entries[0].ranges.length(), 1)
  assert_eq(difference.entries[0].ranges[0].start, 2147483647U)
  assert_eq(difference.entries[0].ranges[0].end, 2147483648U)
  assert_eq(agent_steps, 1)
  assert_eq(range_steps, 4)
}
