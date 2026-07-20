#!/usr/bin/env nu

def run-checked [description: string, command: closure] {
  let result = (do $command | complete)
  print --raw --no-newline $result.stdout
  print --raw --no-newline --stderr $result.stderr
  if $result.exit_code != 0 {
    error make {
      msg: $"($description) failed with exit code ($result.exit_code)"
    }
  }
}

let repo_root = ($env.FILE_PWD | path dirname | path expand)
cd $repo_root

run-checked "MoonBit check" {
  ^moon check --target all --fmt --deny-warn --frozen
}
run-checked "MoonBit tests" {
  ^moon test --target all --frozen
}
run-checked "MoonBit interface generation" {
  ^moon info --frozen
}

let generated_interfaces = [
  "text/pkg.generated.mbti"
  "tree/pkg.generated.mbti"
  "container/pkg.generated.mbti"
  "history/pkg.generated.mbti"
]
let leak_check = (
  ^rg -n "event-graph-walker/internal" ...$generated_interfaces | complete
)
print --raw --no-newline $leak_check.stdout
print --raw --no-newline --stderr $leak_check.stderr
match $leak_check.exit_code {
  0 => {
    error make {
      msg: "public generated interfaces import internal packages"
    }
  }
  1 => {}
  _ => {
    error make {
      msg: $"generated interface leak check failed with exit code ($leak_check.exit_code)"
    }
  }
}

run-checked "generated interface freshness check" {
  ^git diff --exit-code -- ...$generated_interfaces
}
