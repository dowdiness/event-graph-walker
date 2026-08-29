#!/usr/bin/env bash
set -euo pipefail

suite_dir="$(cd "$(dirname "$0")" && pwd -P)"
repo_root="$(cd "$suite_dir/../../.." && pwd -P)"
expected_quint=0.32.0
expected_apalache=0.56.1

if [[ -n "${QUINT_BIN:-}" ]]; then
  quint_bin="$QUINT_BIN"
else
  quint_bin="$suite_dir/node_modules/.bin/quint"
  if [[ ! -x "$quint_bin" ]] || \
     [[ "$($quint_bin --version 2>/dev/null)" != "$expected_quint" ]]; then
    npm ci --prefix "$suite_dir" --ignore-scripts --no-audit --no-fund
  fi
fi

if [[ ! -x "$quint_bin" ]] || \
   [[ "$($quint_bin --version)" != "$expected_quint" ]]; then
  echo "STOPPED: expected Quint $expected_quint" >&2
  exit 2
fi

java_major() {
  java -version 2>&1 | awk -F'[".]' '/version/ { if ($2 == "1") print $3; else print $2; exit }'
}

verify_quint() {
  if command -v java >/dev/null 2>&1 && [[ "$(java_major)" -eq 17 ]]; then
    "$quint_bin" verify "$@"
  elif command -v nix >/dev/null 2>&1; then
    nix shell nixpkgs#jdk17_headless -c "$quint_bin" verify "$@"
  else
    echo "STOPPED: Quint verification requires Java 17 or Nix" >&2
    exit 2
  fi
}

expect_failure() {
  local expected="$1"
  shift
  local output
  local status
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  if [[ "$status" -eq 0 ]] || [[ "$output" != *"$expected"* ]]; then
    printf '%s\n' "$output" >&2
    echo "expected failure containing: $expected" >&2
    exit 1
  fi
}

tmp="$(mktemp -d)"
on_exit() {
  local status=$?
  trap - EXIT
  if [[ "$status" -eq 0 ]]; then
    rm -rf "$tmp"
  else
    echo "PRESERVED: failing Gate V2 artifacts at $tmp" >&2
  fi
  exit "$status"
}
trap on_exit EXIT
sparse_trace="$tmp/sparse-gap.itf.json"
admission_trace="$tmp/admission.itf.json"

cd "$suite_dir"
"$quint_bin" typecheck TextSyncCore.qnt
"$quint_bin" typecheck TextSyncDistributed.qnt
"$quint_bin" typecheck TextSyncAdmission.qnt
"$quint_bin" run TextSyncDistributed.qnt \
  --main TextSyncDistributed \
  --step replayStep \
  --invariant safety \
  --out-itf "$sparse_trace" \
  --max-steps 6 \
  --seed 0x032 \
  --verbosity 0

expect_failure "Invariant violated" \
  "$quint_bin" run TextSyncDistributed.qnt \
    --main TextSyncDistributed \
    --step mutationStep \
    --invariant safety \
    --max-steps 6 \
    --seed 0x032 \
    --verbosity 1

"$quint_bin" run TextSyncAdmission.qnt \
  --main TextSyncAdmission \
  --step replayStep \
  --invariant safety \
  --out-itf "$admission_trace" \
  --max-steps 8 \
  --seed 0x032 \
  --verbosity 0

expect_failure "Invariant violated" \
  "$quint_bin" run TextSyncAdmission.qnt \
    --main TextSyncAdmission \
    --step mutationStep \
    --invariant safety \
    --max-steps 2 \
    --seed 0x032 \
    --verbosity 1

verify_quint TextSyncDistributed.qnt \
  --main TextSyncDistributed \
  --step step \
  --invariant safety \
  --max-steps 6 \
  --apalache-version "$expected_apalache" \
  --verbosity 1

verify_quint TextSyncAdmission.qnt \
  --main TextSyncAdmission \
  --step step \
  --invariant safety \
  --max-steps 8 \
  --apalache-version "$expected_apalache" \
  --verbosity 1

moon -C "$suite_dir/replay" check --target native
moon -C "$suite_dir/replay" run --target native . -- "$sparse_trace"
moon -C "$suite_dir/replay" run --target native . -- "$admission_trace"
expect_failure "knowledge expected" \
  moon -C "$suite_dir/replay" run --target native . -- \
    "$sparse_trace" --broken

moon -C "$repo_root" test --target native text/version_resource_limit_wbtest.mbt
moon -C "$repo_root" test --target native text/sync_json_properties_test.mbt
moon -C "$repo_root" test --target native text/sparse_version_properties_wbtest.mbt
(
  cd "$repo_root/tools/verification/text_reference"
  ./run.sh
  ./run_corpus.sh
)

printf 'PASS: Quint %s sparse and admission traces\n' "$expected_quint"
printf 'PASS: bounded Apalache %s safety verification (sparse=6, admission=8 steps)\n' \
  "$expected_apalache"
printf 'PASS: flat-maximum and premature-admission model mutations detected\n'
printf 'PASS: sparse, pending, duplicate, and conflict traces replayed through public MoonBit APIs\n'
printf 'PASS: replay observation mutation detected\n'
printf 'PASS: existing Version codec/resource/sparse contracts\n'
printf 'PASS: Gate V0 reference traces and official corpus\n'
printf 'CANDIDATE: %s\n' "$(git -C "$repo_root" rev-parse HEAD)"
