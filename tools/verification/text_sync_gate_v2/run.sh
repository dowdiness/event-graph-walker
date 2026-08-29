#!/usr/bin/env bash
set -euo pipefail
started_at=$SECONDS

suite_dir="$(cd "$(dirname "$0")" && pwd -P)"
repo_root="$(cd "$suite_dir/../../.." && pwd -P)"
expected_quint=0.32.0
expected_apalache=0.62.2
mode="${1:---dev}"
if [[ "$mode" != "--dev" && "$mode" != "--candidate" ]]; then
  echo "usage: ./run.sh [--dev|--candidate]" >&2
  exit 2
fi
if [[ "$mode" == "--candidate" ]] && \
   [[ -n "$(git -C "$repo_root" status --short --untracked-files=all)" ]]; then
  echo "STOPPED: --candidate requires a clean worktree" >&2
  exit 2
fi

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
  local model="$1"
  local metrics="$tmp/${model%.qnt}.time"
  local -a command
  if command -v java >/dev/null 2>&1 && [[ "$(java_major)" -eq 21 ]]; then
    command=("$quint_bin" verify "$@")
  elif command -v nix >/dev/null 2>&1; then
    command=(nix shell nixpkgs#jdk21_headless -c "$quint_bin" verify "$@")
  else
    echo "STOPPED: Quint verification requires Java 21 or Nix" >&2
    exit 2
  fi
  if [[ -x /usr/bin/time ]]; then
    /usr/bin/time \
      -f "VERIFY_METRIC: model=$model elapsed_seconds=%e max_rss_kib=%M" \
      -o "$metrics" "${command[@]}"
    cat "$metrics"
  else
    "${command[@]}"
    printf 'VERIFY_METRIC: model=%s elapsed_seconds=unavailable max_rss_kib=unavailable\n' \
      "$model"
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
complete_trace="$tmp/complete.itf.json"
schedule_dir="$tmp/schedules"
mkdir -p "$schedule_dir"

cd "$suite_dir"
"$quint_bin" typecheck TextSyncCore.qnt
"$quint_bin" typecheck TextSyncDistributed.qnt
"$quint_bin" typecheck TextSyncAdmission.qnt
"$quint_bin" typecheck TextSyncSchedules.qnt
"$quint_bin" typecheck TextSyncComplete.qnt
"$quint_bin" run TextSyncComplete.qnt \
  --main TextSyncComplete \
  --step step \
  --invariant safety \
  --out-itf "$complete_trace" \
  --max-steps 21 \
  --seed 0x032 \
  --verbosity 0
expect_failure "Invariant violated" \
  "$quint_bin" run TextSyncComplete.qnt \
    --main TextSyncComplete \
    --step step \
    --invariant identityConflictMutation \
    --max-steps 1 \
    --seed 0x032 \
    --verbosity 1

expect_failure "Invariant violated" \
  "$quint_bin" run TextSyncComplete.qnt \
    --main TextSyncComplete \
    --step step \
    --invariant nullContentMutation \
    --max-steps 1 \
    --seed 0x032 \
    --verbosity 1

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

"$quint_bin" run TextSyncSchedules.qnt \
  --main TextSyncSchedules \
  --step step \
  --invariant safety \
  --n-traces 256 \
  --max-samples 256 \
  --max-steps 9 \
  --seed 0x032 \
  --out-itf "$schedule_dir/schedule-{seq}.itf.json" \
  --verbosity 0

expect_failure "Invariant violated" \
  "$quint_bin" run TextSyncSchedules.qnt \
    --main TextSyncSchedules \
    --step mutationStep \
    --invariant safety \
    --max-steps 9 \
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

verify_quint TextSyncSchedules.qnt \
  --main TextSyncSchedules \
  --step step \
  --invariant safety \
  --max-steps 9 \
  --apalache-version "$expected_apalache" \
  --verbosity 1

verify_quint TextSyncComplete.qnt \
  --main TextSyncComplete \
  --step step \
  --invariant safety \
  --max-steps 21 \
  --apalache-version "$expected_apalache" \
  --verbosity 1

moon -C "$suite_dir/replay" check --target native
moon -C "$suite_dir/replay" run --target native . -- "$sparse_trace"
moon -C "$suite_dir/replay" run --target native . -- "$admission_trace"
moon -C "$suite_dir/replay" run --target native . -- "$complete_trace"
schedule_traces=("$schedule_dir"/*.itf.json)
moon -C "$suite_dir/replay" run --target native . -- "${schedule_traces[@]}"
trace_files=(
  "$sparse_trace"
  "$admission_trace"
  "$complete_trace"
  "${schedule_traces[@]}"
)
replayed_states="$(node -e '
  const fs = require("node:fs");
  const total = process.argv.slice(1).reduce((sum, path) =>
    sum + JSON.parse(fs.readFileSync(path, "utf8")).states.length, 0);
  process.stdout.write(String(total));
' "${trace_files[@]}")"
expect_failure "schedule coverage expected" \
  moon -C "$suite_dir/replay" run --target native . -- \
    "${schedule_traces[0]}"
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
printf 'PASS: bounded Apalache %s safety verification (sparse=6, admission=8, schedules=9, complete=21 steps)\n' \
  "$expected_apalache"
printf 'PASS: flat-maximum, premature-admission, implicit-sequence-parent, exact-origin-conflict, and null-content model mutations detected\n'
printf 'PASS: sparse, pending, duplicate, and conflict traces replayed through public MoonBit APIs\n'
printf 'PASS: all 36 canonical two-replica delivery-order pairs replayed\n'
printf 'PASS: exact multi-agent insert/delete/undelete, directional origins, checkout, delta, and overclaim replayed\n'
printf 'PASS: incomplete schedule coverage detected\n'
printf 'PASS: replay observation mutation detected\n'
printf 'PASS: existing Version codec/resource/sparse contracts\n'
printf 'PASS: Gate V0 reference traces and official corpus\n'
if [[ "$mode" == "--candidate" ]] && \
   [[ -n "$(git -C "$repo_root" status --short --untracked-files=all)" ]]; then
  echo "STOPPED: worktree changed during candidate verification" >&2
  exit 2
fi
candidate="$(git -C "$repo_root" rev-parse HEAD)"
if [[ "$mode" == "--dev" ]] && \
   [[ -n "$(git -C "$repo_root" status --short --untracked-files=all)" ]]; then
  candidate="$candidate+dirty"
fi
printf 'TOOLS: quint=%s apalache=%s java_requirement=21\n' \
  "$($quint_bin --version)" "$expected_apalache"
printf 'MOON_TOOL: %s\n' "$(moon version --json)"
printf 'BOUNDS: sparse=6 admission=8 schedules=9 complete=21 seed=0x032 bounded_model_states=398\n'
printf 'EVIDENCE: schedule_traces=%s required_schedules=36 replayed_itf_states=%s\n' \
  "${#schedule_traces[@]}" "$replayed_states"
printf 'EVIDENCE: total_runtime_seconds=%s\n' "$((SECONDS - started_at))"
printf 'MODE: %s\n' "${mode#--}"
printf 'CANDIDATE: %s\n' "$candidate"
