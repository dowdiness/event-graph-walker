#!/usr/bin/env bash
set -eu

moon check --target all --fmt --deny-warn --frozen
moon test --target all --frozen
moon info --frozen

if rg -n 'event-graph-walker/internal' \
  text/pkg.generated.mbti \
  tree/pkg.generated.mbti \
  container/pkg.generated.mbti \
  history/pkg.generated.mbti; then
  echo "public generated interfaces import internal packages" >&2
  exit 1
fi

git diff --exit-code -- \
  text/pkg.generated.mbti \
  tree/pkg.generated.mbti \
  container/pkg.generated.mbti \
  history/pkg.generated.mbti
