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

cd ($env.FILE_PWD | path expand)

run-checked "Text epoch cutover baseline tests" {
  ^moon test baseline_test.mbt --target native --frozen
}
run-checked "Text epoch cutover server tests" {
  ^moon test server_test.mbt --target native --frozen
}
run-checked "Text epoch cutover check" {
  ^moon check --target native --frozen
}
