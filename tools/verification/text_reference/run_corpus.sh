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

# Keep the original (agent, sequence) identities: this is the canonical
# delivery-validation corpus. The order-embedding option remains available in
# corpus_translate.mjs for diagnostics, but is intentionally not used here.
node corpus_translate.mjs "$corpus" > .cache/exact-all.json
moon run . --target native -- --corpus .cache/exact-all.json
moon run . --target native -- --corpus-reversed-duplicates .cache/exact-all.json
