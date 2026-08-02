set shell := ["nu", "-c"]

# List the available project commands.
default:
    @just --list

# Resolve dependencies for local preparation.
resolve:
    moon update
    moon check --target all --fmt --deny-warn

# Run the release verification suite.
verify:
    nu ./scripts/verify.nu

# Build, extract, and validate the publish archive.
verify-publish:
    nu ./scripts/verify-publish-package.nu

# Run the same complete verification pipeline as CI.
ci: verify verify-publish

# Run the Issue #107 Phase A correctness model on every backend.
prototype-prepared-local-mutation-test:
    moon test --target all --frozen container/prepared_local_mutation_wbtest.mbt

# Measure isolated Issue #107 latency stages on one release backend.
prototype-prepared-local-mutation-bench target:
    moon bench --release --target {{target}} --frozen -p dowdiness/event-graph-walker/container -f prepared_local_mutation_benchmark_wbtest.mbt --no-parallelize

# Measure isolated-process peak RSS for one Issue #107 fixture.
prototype-prepared-local-mutation-memory target scenario:
    nu ./scripts/measure-prepared-local-mutation-memory.nu {{target}} {{scenario}}
