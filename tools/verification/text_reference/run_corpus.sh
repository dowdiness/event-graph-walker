#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

commit=4d9bef55e4f2e3b3b8b0efe8f91cd35d34ed35a8
expected_sha=95bdb544deca513441a50ea26a1c3ecbad116061c1d0fd6dde3175ea1e0bffd7
oracle_sha=debf503de64aa1307fe93bb9a30c7d4f5d34257c5d11f65b5856f14443d9c4b1
mkdir -p .cache
corpus="${EGW_CONFORMANCE_CORPUS:-.cache/conformance.json}"

if [[ ! -f "$corpus" ]]; then
  url="https://raw.githubusercontent.com/josephg/egwalker-paper/$commit/eg-walker-reference/testdata/conformance.json"
  curl --fail --location --silent --show-error "$url" --output "$corpus"
fi
printf '%s  %s\n' "$expected_sha" "$corpus" | sha256sum --check --status

npm ci --ignore-scripts --silent
oracle=node_modules/reference-frh/dist/test/list-fugue-simple.js
printf '%s  %s\n' "$oracle_sha" "$oracle" | sha256sum --check --status

# The unmodified corpus's first run branches one replica's sequence history.
# Preserve that exact identity and prove the current public admission boundary
# rejects it for the characterized reason rather than silently changing it.
node corpus_translate.mjs "$corpus" --limit 1 > .cache/exact-first.json
set +e
moon run . --target native -- --corpus .cache/exact-first.json \
  > .cache/exact-first.stdout 2> .cache/exact-first.stderr
exact_status=$?
set -e
if [[ "$exact_status" -eq 0 ]]; then
  echo "UNEXPECTED: exact corpus identity is now accepted; update this characterization"
  exit 1
fi
if ! grep -q 'does not causally descend from its replica predecessor' \
    .cache/exact-first.stderr .cache/exact-first.stdout; then
  cat .cache/exact-first.stdout .cache/exact-first.stderr
  echo "FAIL: exact corpus identity failed for an unrecognized reason"
  exit 1
fi
echo "EXPECTED BLOCKER: exact corpus identities violate MoonBit's linear per-replica admission rule"

# Give each event a unique synthetic replica ID whose lexical order is an
# order-isomorphic embedding of the original (agent, sequence) RawVersion.
# This removes only the linear-agent admission mismatch; origins, parents,
# operations, delivery order, and expected visible text remain unchanged.
node corpus_translate.mjs "$corpus" --order-embedding \
  > .cache/order-embedded-corpus.json
moon run . --target native -- --corpus .cache/order-embedded-corpus.json
