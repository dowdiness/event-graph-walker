#!/usr/bin/env bash
set -euo pipefail

suite_dir="$(cd "$(dirname "$0")" && pwd -P)"
cd "$suite_dir"

if [[ ! -d node_modules ]]; then
  npm ci
fi

mkdir -p .out
matched=0
diverged=0
for trace in traces/*.trace; do
  name="$(basename "$trace" .trace)"
  node reference_driver.mjs "$trace" > ".out/$name.reference.tsv"
  moon run . --target native -- "$trace" > ".out/$name.moonbit.tsv"
  if diff -u ".out/$name.reference.tsv" ".out/$name.moonbit.tsv" \
      > ".out/$name.diff"; then
    matched=$((matched + 1))
    printf 'MATCH %s\n' "$name"
  else
    diverged=$((diverged + 1))
    printf 'DIVERGED %s\n' "$name"
  fi
done

printf 'RESULT: %d matched, %d diverged\n' "$matched" "$diverged"
if [[ "$diverged" -ne 0 ]]; then
  echo "NO-GO: the reference and MoonBit implementations do not share exact text ordering"
  echo "Inspect .out/*.diff for counterexamples"
  exit 2
fi

echo "GO: reference-frh and MoonBit text states matched"
