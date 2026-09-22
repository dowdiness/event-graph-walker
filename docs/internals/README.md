# Internals

This directory contains resources for contributors working on the implementation, tracking performance, and managing architectural decisions. These are **not** required reading for library consumers.

---

## Contents

| Directory / File | Description |
| :--- | :--- |
| **[benchmarks/](benchmarks/)** | Benchmark commands, notes on running suites, performance baselines, and raw snapshots over time. The directory index is [`benchmarks/README.md`](benchmarks/README.md). |
| **[roadmaps/](roadmaps/)** | Stabilization and optimization roadmaps plus open architectural decisions. |
| **[adr/](adr/)** | Architectural Decision Records (numbered, immutable). |
| **[performance/](performance/)** | Profiling data, CSV evidence, and characterization reports. |
| **[plans/](plans/)** | Active implementation plans and `archive/` of completed ones. |
| **[research/](research/)** | Experimental designs, alternative assessments, and one-off explorations. |
| **[decisions/](decisions/)** | Resolved implementation decisions (complementary to ADRs). |

---

## Roadmaps

- **[Stabilization Roadmap](roadmaps/stabilization.md)**: Phase-by-phase invariant hardening, network readiness, and performance work.
- **[Optimization Roadmap](roadmaps/optimization.md)**: Specific performance targets, completed fixes, and future optimization candidates.
- **[Decisions Needed](roadmaps/decisions-needed.md)**: Open architectural questions requiring a human decision before proceeding.

---

## ADR Index

| ADR | Title |
| :--- | :--- |
| [0001](adr/0001-local-insert-validation-core.md) | Local insert validation core |
| [0002](adr/0002-distinguish-invalid-local-text.md) | Distinguish invalid local text |
| [0003](adr/0003-consistency-boundaries.md) | Consistency boundaries |
| [0004](adr/0004-canonical-pending-remote-owner.md) | Canonical pending remote owner |
| [0005](adr/0005-rawversion-identity-conflicts.md) | RawVersion identity conflicts |
| [0006](adr/0006-local-mutation-footprint-evidence.md) | Local mutation footprint evidence |
| [0007](adr/0007-prepared-local-mutation-is-feasible-but-full-history-evidence-is-not-promotable.md) | Prepared local mutation feasibility |
| [0008](adr/0008-core-owned-batch-remote-admission-over-legacy-op.md) | Core-owned batch remote admission |
| [0009](adr/0009-text-causality-and-sparse-version.md) | Text causality and sparse version |
