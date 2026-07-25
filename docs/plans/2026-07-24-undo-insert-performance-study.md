# Undo-recording insert performance study

Status: completed as an exploratory comparison. The benchmark source was temporary and was not added to the production package.

## Compared paths

- **Baseline**: the pre-validation loop that emits one CRDT operation and one undo item per codepoint.
- **A**: the current `InsertPlan` validation followed by the existing commit-and-record loop.
- **B**: validated codepoint materialization followed by commit and undo recording.

The baseline was an equivalent shell reference using valid inputs, not a separate public-API checkout. All paths used the same document pool and undo workload.

## Representative results

| Workload | Target | Baseline | A | B |
| --- | --- | ---: | ---: | ---: |
| batch 100 | JS | 667.20 µs | 556.54 µs | 568.83 µs |
| batch 1,000 | JS | 7.14 ms | 4.65 ms | 5.33 ms |
| grouped typing, 100 chars | JS | 632.29 µs | 525.62 µs | 571.62 µs |
| separate typing, 100 chars | JS | 506.69 µs | 559.07 µs | 522.67 µs |
| batch 100 | wasm-gc | 1.67 ms | 1.75 ms | 1.66 ms |
| batch 1,000 | wasm-gc | 18.44 ms | 15.61 ms | 15.14 ms |
| grouped typing, 100 chars | wasm-gc | 1.74 ms | 1.61 ms | 1.74 ms |
| separate typing, 100 chars | wasm-gc | 1.81 ms | 1.75 ms | 1.61 ms |

The results are noisy because CRDT state grows in bounded pools and larger cases have few benchmark iterations. Neither A nor B shows a consistent regression or advantage. Temporary allocation/GC was not independently instrumented.

## Decision

Keep A for `insert_and_record` and `replace_range_and_record`. Do not introduce B without a future profile showing a real allocation or traversal bottleneck.
