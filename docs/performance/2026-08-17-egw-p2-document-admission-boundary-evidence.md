# P2.3 Document admission boundary benchmark evidence

This records the benchmark run for the P2.3 document admission boundary at source commit `22d01f8f75fdbd11230a3418934813d4d3e0cc00`, based on `origin/main` `0e4ec9347c4655449cf3dd5a2a543f1d9cfe335b`.

## Commands

```text
NEW_MOON_MOD=0 moon bench --package internal/document --file document_admission_boundary_benchmark_wbtest.mbt --release
NEW_MOON_MOD=0 moon bench --target js --package internal/document --file document_admission_boundary_benchmark_wbtest.mbt --release
```

Both targets ran the four benchmark cases (`complete`, `duplicate-only`, `pending-only`, `partial`) at `M = 1, 10, 100, 1000` through both lanes (`M × apply_remote` and `1 × admit_remote`), with 4/4 benchmark tests passing per target. The raw 64-row JSON evidence is in [2026-08-17-egw-p2-document-admission-boundary-evidence.json](./2026-08-17-egw-p2-document-admission-boundary-evidence.json).

The raw JSON SHA-256 is:

```text
ce526dc7cd8b60fbd746cce41905ed94c89689e7350fe6bd41d2567e881471a3
```

## Timing scope

The framework's reported benchmark time is end-to-end for the harness iteration. Each JSON record's `inner_us` measures only the remote admission boundary; fixture construction and postcondition/fresh-checkout validation are outside that clock.

A representative wasm-gc `M=1000` boundary measurement from this run was:

| Case | `M × apply_remote` | `1 × admit_remote` | Difference |
| --- | ---: | ---: | ---: |
| complete | 5597.146 µs | 4798.124 µs | 14.3% lower |
| duplicate-only | 2137.610 µs | 872.802 µs | 59.2% lower |
| pending-only | 3137.263 µs | 3225.972 µs | 2.8% higher in this run |
| partial | 2554.683 µs | 3188.205 µs | not directly comparable |

Partial is intentionally not a same-workload speed comparison: the per-operation lane stops at the first error and leaves one pending operation, while the batch lane owns the full pending suffix. Its lifecycle and state assertions remain evidence of the two intended ownership paths.

## Allocation observation

The MoonBit core benchmark API does not expose an allocator counter. The raw records therefore retain the explicit observation:

```text
core-bench-counter-unavailable
```

No allocation value is inferred.
