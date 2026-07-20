#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/event-graph-walker-publish.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

target_dir="$work_dir/build"
moon package --list --frozen --target-dir "$target_dir"

shopt -s nullglob
archives=("$target_dir"/publish/*.zip)
if (( ${#archives[@]} != 1 )); then
  echo "moon package produced ${#archives[@]} publish archives; expected 1" >&2
  exit 1
fi
archive=${archives[0]}

verify_dir="$work_dir/extracted"
mkdir -p "$verify_dir"
unzip -q "$archive" -d "$verify_dir"
(
  cd "$verify_dir"
  moon check
)
