#!/usr/bin/env nu

const scenarios = {
  empty-4: { prepare: 1, commit: 8, fixture: 15 }
  records-128-4: { prepare: 2, commit: 9, fixture: 16 }
  records-499-4: { prepare: 3, commit: 10, fixture: 17 }
  ops-1: { prepare: 4, commit: 11, fixture: 18 }
  ops-4: { prepare: 5, commit: 12, fixture: 19 }
  ops-16: { prepare: 6, commit: 13, fixture: 20 }
  ops-64: { prepare: 7, commit: 14, fixture: 21 }
}

const package = "dowdiness/event-graph-walker/container"
const fixture_file = "prepared_local_mutation_memory_wbtest.mbt"
const repetitions = 5


def median [values: list] {
  let sorted = ($values | sort)
  let middle = ((($sorted | length) / 2) | math floor | into int)
  $sorted | get $middle
}


def driver_args [index: int] {
  {
    package: $package
    file_and_index: [
      [$fixture_file, [{ start: $index, end: ($index + 1) }]]
    ]
  } | to json --raw
}


def measure_once [target: string, index: int, timing_file: string] {
  let args = (driver_args $index)
  let completed = if $target == "js" {
    do {
      ^/usr/bin/time -f "%M\t%e" -o $timing_file node --enable-source-maps ./_build/js/release/test/container/container.whitebox_test.js $args
    } | complete
  } else {
    do {
      ^/usr/bin/time -f "%M\t%e" -o $timing_file moonrun --test-args $args ./_build/wasm-gc/release/test/container/container.whitebox_test.wasm --
    } | complete
  }
  if $completed.exit_code != 0 {
    error make {
      msg: $"memory child failed for ($target), test index ($index): ($completed.stderr)"
    }
  }
  let fields = (open --raw $timing_file | str trim | split row "\t")
  if ($fields | length) != 2 {
    error make { msg: "GNU time did not produce peak RSS and wall time" }
  }
  {
    rss_kib: ($fields.0 | into int)
    wall_seconds: ($fields.1 | into float)
  }
}


def main [target: string, scenario: string] {
  if $target not-in ["js", "wasm-gc"] {
    error make { msg: $"unsupported target '($target)'; expected js or wasm-gc" }
  }
  if $scenario not-in ($scenarios | columns) {
    error make {
      msg: $"unsupported scenario '($scenario)'; expected (($scenarios | columns) | str join ', ')"
    }
  }
  if (which /usr/bin/time | is-empty) {
    error make { msg: "unsupported: /usr/bin/time is required for child peak RSS" }
  }

  let build = (
    ^moon test --release --target $target --frozen --build-only container/prepared_local_mutation_memory_wbtest.mbt | complete
  )
  if $build.exit_code != 0 {
    error make { msg: $"memory fixture build failed: ($build.stderr)" }
  }

  let selected = ($scenarios | get $scenario)
  let output_dir = "docs/benchmarks/raw"
  mkdir $output_dir
  let raw_path = ($output_dir | path join $"prepared-local-mutation-memory-($target)-($scenario).tsv")
  let metadata_path = ($output_dir | path join $"prepared-local-mutation-memory-($target)-($scenario).meta.txt")
  let timing_file = "/tmp/egw-107-memory-time.tsv"
  mut rows = []

  for stage in ["baseline", "fixture", "prepare", "commit"] {
    let index = if $stage == "baseline" { 0 } else { $selected | get $stage }
    for run in 1..$repetitions {
      let measured = (measure_once $target $index $timing_file)
      $rows = ($rows | append {
        target: $target
        scenario: $scenario
        stage: $stage
        run: $run
        rss_kib: $measured.rss_kib
        wall_seconds: $measured.wall_seconds
      })
    }
  }
  rm -f $timing_file
  $rows | to tsv | save --force $raw_path

  let baseline = (median ($rows | where stage == baseline | get rss_kib))
  let fixture = (median ($rows | where stage == fixture | get rss_kib))
  let prepare = (median ($rows | where stage == prepare | get rss_kib))
  let commit = (median ($rows | where stage == commit | get rss_kib))
  let summary = [
    {
      target: $target
      scenario: $scenario
      stage: "fixture"
      median_rss_kib: $fixture
      baseline_adjusted_kib: ($fixture - $baseline)
      incremental_vs_fixture_kib: 0
    }
    {
      target: $target
      scenario: $scenario
      stage: "prepare"
      median_rss_kib: $prepare
      baseline_adjusted_kib: ($prepare - $baseline)
      incremental_vs_fixture_kib: ($prepare - $fixture)
    }
    {
      target: $target
      scenario: $scenario
      stage: "commit"
      median_rss_kib: $commit
      baseline_adjusted_kib: ($commit - $baseline)
      incremental_vs_fixture_kib: ($commit - $fixture)
    }
  ]

  let moon_version = (^moon version --all | complete | get stdout | str trim)
  let source_revision = (^git rev-parse HEAD | str trim)
  let node_version = if $target == "js" { ^node --version | str trim } else { "unsupported" }
  let time_version = (^/usr/bin/time --version | lines | first | str trim)
  let child_runner = if $target == "js" {
    "node --enable-source-maps _build/js/release/test/container/container.whitebox_test.js <driver-args>"
  } else {
    "moonrun --test-args <driver-args> _build/wasm-gc/release/test/container/container.whitebox_test.wasm --"
  }
  let metadata = (
    [
      $"target=($target)"
      $"scenario=($scenario)"
      $"repetitions=($repetitions)"
      $"timestamp=(date now | format date '%Y-%m-%dT%H:%M:%S%:z')"
      $"source_revision=($source_revision)"
      $"measurement_command=nu scripts/measure-prepared-local-mutation-memory.nu ($target) ($scenario)"
      $"child_runner=($child_runner)"
      $"kernel=(sys host | get long_os_version)"
      $"cpu=(sys cpu | first | get brand)"
      $"node=($node_version)"
      $"gnu_time=($time_version)"
      $"moon=($moon_version)"
    ] | str join "\n"
  )
  $metadata | save --force $metadata_path

  print $"raw=($raw_path)"
  print $"metadata=($metadata_path)"
  $summary | table | print
}
