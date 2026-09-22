# P2.3 Document admission boundary benchmark evidence

This records the benchmark run for the P2.3 document admission boundary at source commit `f394d7048a5f8fd195519fe435841b54748a8967`, based on `origin/main` `0e4ec9347c4655449cf3dd5a2a543f1d9cfe335b`.

## Commands

```text
NEW_MOON_MOD=0 moon bench --package internal/document --file document_admission_boundary_benchmark_wbtest.mbt --release
NEW_MOON_MOD=0 moon bench --target js --package internal/document --file document_admission_boundary_benchmark_wbtest.mbt --release
```

Both targets ran the four benchmark cases (`complete`, `duplicate-only`, `pending-only`, `partial`) at `M = 1, 10, 100, 1000` through both lanes (`M × apply_remote` and `1 × admit_remote`), with 4/4 benchmark tests passing per target. The raw 64-row JSON evidence is in [2026-08-17-egw-p2-document-admission-boundary-evidence.json](./2026-08-17-egw-p2-document-admission-boundary-evidence.json).

The raw JSON SHA-256 is:

```text
417a321a0d57ffa46c82bc9a4a34c96e6c782ff6444d359dbeb7309f7b5d4be0
```

## Timing scope

The framework's reported benchmark time is end-to-end for the harness iteration. Each JSON record's `inner_us` measures only the remote admission boundary; fixture construction and postcondition/fresh-checkout validation are outside that clock.

A representative wasm-gc `M=1000` boundary measurement from this run was:

| Case | `M × apply_remote` | `1 × admit_remote` | Difference |
| --- | ---: | ---: | ---: |
| complete | 6492.618 µs | 3878.004 µs | 40.3% lower |
| duplicate-only | 1723.264 µs | 1158.404 µs | 32.8% lower |
| pending-only | 3569.129 µs | 2117.984 µs | 40.7% lower |
| partial | 2323.779 µs | 2598.273 µs | not directly comparable |

Partial is intentionally not a same-workload speed comparison: the per-operation lane stops at the first error and leaves one pending operation, while the batch lane owns the full pending suffix. Its lifecycle and state assertions remain evidence of the two intended ownership paths.

## Allocation observation

The MoonBit core benchmark API does not expose an allocator counter. The raw records therefore retain the explicit observation:

```text
core-bench-counter-unavailable
```

No allocation value is inferred.
