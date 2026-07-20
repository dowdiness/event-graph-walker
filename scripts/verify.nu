#!/usr/bin/env nu

def run-checked [description: string, command: closure] {
  try {
    do $command
  } catch {|error|
    let exit_code = ($error | get --optional exit_code)
    if $exit_code == null {
      error make $error
    }
    error make {
      msg: $"($description) failed with exit code ($exit_code)"
    }
  }
}

def find-internal-imports [files: list<string>] {
  $files
  | each {|file|
      open --raw $file
      | lines
      | enumerate
      | where item =~ "event-graph-walker/internal"
      | each {|match|
          {
            file: $file
            line: ($match.index + 1)
            text: $match.item
          }
        }
    }
  | flatten
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
let internal_imports = (find-internal-imports $generated_interfaces)
if not ($internal_imports | is-empty) {
  $internal_imports | each {|import|
    print --stderr $"($import.file):($import.line):($import.text)"
  }
  error make {
    msg: "public generated interfaces import internal packages"
  }
}

run-checked "generated interface freshness check" {
  ^git diff --exit-code -- ...$generated_interfaces
}
