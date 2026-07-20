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
