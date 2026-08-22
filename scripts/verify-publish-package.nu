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

let repo_root = ($env.FILE_PWD | path dirname | path expand)
cd $repo_root

let work_dir = (mktemp --directory)
try {
  let target_dir = ($work_dir | path join "build")
  run-checked "moon package" {
    ^moon package --list --frozen --target-dir $target_dir
  }

  let archive_pattern = ($target_dir | path join "publish" "*.zip")
  let archives = (glob $archive_pattern)
  if ($archives | length) != 1 {
    error make {
      msg: $"moon package produced ($archives | length) publish archives; expected 1"
    }
  }

  let archive = ($archives | first)
  let archive_entries = (^unzip -Z1 $archive | lines)
  if ($archive_entries | any {|entry| $entry | str contains "internal/restore_feasibility_probe" }) {
    error make { msg: "publish archive contains the Gate R0 executable probe" }
  }
  if ($archive_entries | any {|entry| $entry | str contains "moonbitlang/x/crypto" }) {
    error make { msg: "publish archive contains the probe-only crypto dependency" }
  }

  let verify_dir = ($work_dir | path join "extracted")
  mkdir $verify_dir
  run-checked "publish archive extraction" {
    ^unzip -q $archive -d $verify_dir
  }

  cd $verify_dir
  let extracted_manifests = (glob "**/moon.mod.json")
  for manifest_path in $extracted_manifests {
    let manifest_source = (open --raw $manifest_path)
    if ($manifest_source | str contains "moonbitlang/x/crypto") {
      error make { msg: $"published dependency manifest contains probe-only crypto: ($manifest_path)" }
    }
  }
  run-checked "extracted package dependency install" {
    ^moon install
  }
  run-checked "extracted package check" {
    ^moon check --frozen
  }
} catch {|error|
  cd $repo_root
  rm --recursive --force $work_dir
  error make $error
}

cd $repo_root
rm --recursive --force $work_dir
