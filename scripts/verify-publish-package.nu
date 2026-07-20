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

  let verify_dir = ($work_dir | path join "extracted")
  mkdir $verify_dir
  run-checked "publish archive extraction" {
    ^unzip -q ($archives | first) -d $verify_dir
  }

  cd $verify_dir
  run-checked "extracted package check" {
    ^moon check
  }
} catch {|error|
  cd $repo_root
  rm --recursive --force $work_dir
  error make $error
}

cd $repo_root
rm --recursive --force $work_dir
