# Local insert performance study

Status: completed as an exploratory comparison. The benchmark prototype was temporary and was not added to the production package.

## Goal

Measure whether the extra validation pass in A is material, and compare it with a materialized-codepoint plan before changing the design.

## Matrix

Compare these equivalent paths:

1. Baseline: current single-pass insert.
2. A: validate the complete string, then commit by iterating the original string.
3. B prototype: materialize validated codepoints, then commit from the materialized plan.

Measure input lengths `1`, `8`, `64`, `1_000`, and `10_000`, with sequential append and middle-position insert workloads. Run release-mode measurements for both JS (deployment target) and wasm-gc.

## Measurements

Record latency, allocation/GC signals where available, peak temporary memory, visible operation count, and resulting text. Keep correctness checks identical across all three paths, especially non-BMP characters and malformed UTF-16 rejection.

## Results

The three strategies were compared in-process with release-mode benchmarks on JS and wasm-gc. Representative means (lower is better) were:

| Workload | Target | Baseline | A | B |
| --- | --- | ---: | ---: | ---: |
| batch 64 | JS | 361.88 µs | 357.05 µs | 390.05 µs |
| batch 1,000 | JS | 5.28 ms | 4.52 ms | 5.21 ms |
| batch 10,000 | JS | 50.09 ms | 53.35 ms | 55.05 ms |
| middle 64 | JS | 415.07 µs | 442.24 µs | 380.07 µs |
| batch 64 | wasm-gc | 1.05 ms | 938.76 µs | 1.04 ms |
| batch 1,000 | wasm-gc | 18.64 ms | 17.75 ms | 14.75 ms |
| middle 64 | wasm-gc | 519.86 µs | 605.17 µs | 431.92 µs |

The 10,000-operation samples had only two to four iterations and high variance, so they are directional rather than decision-quality evidence. Across the smaller and more realistic workloads, A showed no consistent material regression, while B showed no consistent latency advantage and adds temporary array allocations. Allocation/GC was not independently instrumented.

## Decision

Keep A. Do not replace it with B based on this exploratory comparison. If profiling later identifies validation traversal as a real bottleneck, repeat the study with allocation/GC measurement and a stable workload distribution before changing the design.
