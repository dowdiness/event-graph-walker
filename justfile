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

# Run the throwaway Issue #101 local-footprint prototype.
prototype-issue-101:
    moon run --release --target native prototypes/issue_101_local_footprint

# Run its non-interactive reconstruction timing on one backend.
prototype-issue-101-batch target="native":
    moon run --release --target {{target}} prototypes/issue_101_local_footprint/batch
