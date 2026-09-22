# Contributing to Event Graph Walker

Thank you for your interest in contributing to Event Graph Walker! This document explains how to set up your local development environment, run checks, and submit contributions.

---

## Prerequisites

To build, test, and verify the project locally, ensure you have the following tools installed:

- **[MoonBit CLI](https://www.moonbitlang.com/)** (`moon`): The core language toolchain.
- **[just](https://github.com/casey/just)**: The command runner used for project recipes.
- **[Nushell](https://www.nushell.sh/)** (`nu`): Required by the verification and pipeline scripts.
- **Python 3**: Required for benchmark verification tooling tests.

---

## Development Workflow

We use `just` recipes to automate common development workflows.

### 1. Preparing Dependencies

Install dependencies and check formatting:

```bash
just resolve
```

This runs `moon update` and verifies code formatting across all targets.

### 2. Running Tests & Verifications

Before committing or opening a pull request, run the verification suite:

```bash
just verify
```

`just verify` runs the automated validation script (`scripts/verify.nu`), which includes:
- Python tooling tests
- MoonBit type checking and linting (`moon check --target all --fmt --deny-warn --frozen`)
- MoonBit test suite (`moon test --target all --frozen`)
- Text epoch cutover verification
- Interface generation check (`moon info --frozen`)
- Boundary check preventing accidental dependencies on `internal/`

You can also run tests directly with MoonBit:

```bash
moon test
```

> [!NOTE]
> `just verify` enforces `--deny-warn` to match CI standards. If you are using a newer MoonBit toolchain that introduces new deprecation warnings, use `moon test` directly during iterative local development.

### 3. Packaging & Publish Validation

To ensure that the package can be bundled and published cleanly:

```bash
just verify-publish
```

### 4. Full CI Pipeline

To run the exact pipeline that runs in GitHub Actions CI:

```bash
just ci
```

### 5. Running Benchmarks

For performance profiling and benchmarking:

```bash
moon bench --release
```

See [docs/BENCHMARKS.md](docs/BENCHMARKS.md) for more details on benchmarking setups and history.

---

## Contribution Guidelines

### Public Facades vs. Internal Packages

- External consumers should rely only on public facade packages (`text`, `tree`, `undo`, `container`, `history`, `peer_sync`).
- Do not expose `internal/*` types or APIs through public facades without deliberate design consensus.
- Never import `internal/*` packages into public facades or consumer packages.

### Public API Surface (`.mbti`)

- The `.mbti` files (such as `text/pkg.generated.mbti`) represent the authoritative public API contract.
- Any change to public signatures will cause `just verify` to fail if interface files are out of sync.
- Update generated interface files when intentionally modifying public APIs using `moon info`.

### Pull Request Process

1. Fork the repository and create your branch from `main`.
2. Make your changes and write unit tests covering new features or bug fixes.
3. Ensure all checks pass by running `just ci`.
4. Submit a pull request with a clear description of the problem solved or feature added.
