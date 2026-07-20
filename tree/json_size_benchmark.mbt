// Benchmark the allocation-sensitive tree JSON size preflight.
// Run with: moon bench --package tree --release

///|
test "tree JSON size - 1 MiB ASCII" (b : @bench.T) {
  let json = "x".repeat(1024 * 1024)
  let limits = try! @sync.Limits()
  b.bench(fn() {
    let size = try! tree_json_size(json, limits)
    b.keep(size)
  })
}

///|
test "tree JSON size - 1 MiB UTF-16" (b : @bench.T) {
  let json = "文".repeat(1024 * 1024)
  let limits = try! @sync.Limits()
  b.bench(fn() {
    let size = try! tree_json_size(json, limits)
    b.keep(size)
  })
}
