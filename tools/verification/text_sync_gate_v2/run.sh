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
  local label="$1"
  shift
  local metrics="$tmp/$label.time"
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
      -f "VERIFY_METRIC: model=$label elapsed_seconds=%e max_rss_kib=%M" \
      -o "$metrics" "${command[@]}"
    cat "$metrics"
  else
    "${command[@]}"
    printf 'VERIFY_METRIC: model=%s elapsed_seconds=unavailable max_rss_kib=unavailable\n' \
      "$label"
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
named_trace="$tmp/named.itf.json"
schedule_dir="$tmp/schedules"
mkdir -p "$schedule_dir"

cd "$suite_dir"
"$quint_bin" typecheck TextSyncCore.qnt
"$quint_bin" typecheck TextSyncScenarios.qnt

"$quint_bin" run TextSyncScenarios.qnt \
  --main TextSyncScenarios \
  --init initNamed \
  --step namedStep \
  --invariant namedSafety \
  --out-itf "$named_trace" \
  --max-steps 39 \
  --seed 0x032 \
  --verbosity 0

"$quint_bin" run TextSyncScenarios.qnt \
  --main TextSyncScenarios \
  --init initSchedule \
  --step scheduleStep \
  --invariant scheduleSafety \
  --n-traces 256 \
  --max-samples 256 \
  --max-steps 9 \
  --seed 0x032 \
  --out-itf "$schedule_dir/schedule-{seq}.itf.json" \
  --verbosity 0

expect_failure "Invariant violated" \
  "$quint_bin" run TextSyncScenarios.qnt \
    --main TextSyncScenarios \
    --init initSchedule \
    --step implicitSequenceMutationStep \
    --invariant scheduleSafety \
    --n-traces 100 \
    --max-samples 100 \
    --max-steps 9 \
    --seed 0x032 \
    --verbosity 1

expect_failure "Invariant violated" \
  "$quint_bin" run TextSyncScenarios.qnt \
    --main TextSyncScenarios \
    --init initSchedule \
    --step prematureMutationStep \
    --invariant scheduleSafety \
    --n-traces 100 \
    --max-samples 100 \
    --max-steps 9 \
    --seed 0x032 \
    --verbosity 1

expect_failure "Invariant violated" \
  "$quint_bin" run TextSyncScenarios.qnt \
    --main TextSyncScenarios \
    --init initNamed \
    --step namedStep \
    --invariant flatMaximumMutation \
    --max-steps 1 \
    --seed 0x032 \
    --verbosity 1

expect_failure "Invariant violated" \
  "$quint_bin" run TextSyncScenarios.qnt \
    --main TextSyncScenarios \
    --init initSchedule \
    --step scheduleStep \
    --invariant catalogDeletionMutation \
    --max-steps 1 \
    --seed 0x032 \
    --verbosity 1

verify_quint schedule \
  TextSyncScenarios.qnt \
  --main TextSyncScenarios \
  --init initSchedule \
  --step scheduleStep \
  --invariant scheduleSafety \
  --max-steps 9 \
  --apalache-version "$expected_apalache" \
  --verbosity 1

verify_quint named \
  TextSyncScenarios.qnt \
  --main TextSyncScenarios \
  --init initNamed \
  --step namedStep \
  --invariant namedSafety \
  --max-steps 39 \
  --apalache-version "$expected_apalache" \
  --verbosity 1

moon -C "$suite_dir/replay" check --target native
moon -C "$suite_dir/replay" run --target native . -- "$named_trace"
schedule_traces=("$schedule_dir"/*.itf.json)
schedule_output="$(
  moon -C "$suite_dir/replay" run --target native . -- "${schedule_traces[@]}"
)"
printf '%s\n' "$schedule_output"
coverage_line="$(printf '%s\n' "$schedule_output" | awk '/^COVERAGE:/ { print; exit }')"
observed_schedules="$(printf '%s\n' "$coverage_line" | sed -E 's/.*observed=([0-9]+).*/\1/')"
required_schedules="$(printf '%s\n' "$coverage_line" | sed -E 's/.*required=([0-9]+).*/\1/')"
if [[ -z "$coverage_line" ]] || [[ "$observed_schedules" != "$required_schedules" ]]; then
  echo "schedule coverage evidence is incomplete" >&2
  exit 1
fi

trace_files=("$named_trace" "${schedule_traces[@]}")
replayed_states="$(node -e '
  const fs = require("node:fs");
  const total = process.argv.slice(1).reduce((sum, path) =>
    sum + JSON.parse(fs.readFileSync(path, "utf8")).states.length, 0);
  process.stdout.write(String(total));
' "${trace_files[@]}")"
expect_failure "schedule coverage expected" \
  moon -C "$suite_dir/replay" run --target native . -- \
    "${schedule_traces[0]}"
expect_failure "exact knowledge diverged" \
  moon -C "$suite_dir/replay" run --target native . -- \
    "$named_trace" --broken
expect_failure "exact message heads diverged" \
  moon -C "$suite_dir/replay" run --target native . -- \
    "$named_trace" --broken-head

moon -C "$repo_root" test --target native text/text_wire_contract_test.mbt
moon -C "$repo_root" test --target native text/version_resource_limit_wbtest.mbt
moon -C "$repo_root" test --target native text/sync_json_properties_test.mbt
moon -C "$repo_root" test --target native text/sparse_version_properties_wbtest.mbt
(
  cd "$repo_root/tools/verification/text_reference"
  ./run.sh
  ./run_corpus.sh
)

printf 'PASS: one pure causal reducer derived admission, pending, Version, checkpoint, and delta observations\n'
printf 'PASS: bounded Apalache %s safety verification (schedule=9, named=39 steps)\n' \
  "$expected_apalache"
printf 'PASS: flat-maximum, premature-admission, and implicit-sequence-parent reducer mutations detected\n'
printf 'PASS: content, parents, left-origin, and right-origin identity conflicts replayed through public APIs\n'
printf 'PASS: exact exported operation and head sets checked for fixtures, export_all, and export_since\n'
printf 'PASS: origin-only readiness preserves declared-parent Version frontier semantics\n'
printf 'PASS: generated delivery catalog and incomplete-coverage mutation checked\n'
printf 'PASS: replay Version and message-head observation mutations detected\n'
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
printf 'BOUNDS: schedule=9 named=39 release_operations=8 seed=0x032\n'
printf 'EVIDENCE: schedule_traces=%s observed_schedules=%s required_schedules=%s replayed_itf_states=%s\n' \
  "${#schedule_traces[@]}" "$observed_schedules" "$required_schedules" \
  "$replayed_states"
printf 'EVIDENCE: total_runtime_seconds=%s\n' "$((SECONDS - started_at))"
printf 'MODE: %s\n' "${mode#--}"
printf 'CANDIDATE: %s\n' "$candidate"
