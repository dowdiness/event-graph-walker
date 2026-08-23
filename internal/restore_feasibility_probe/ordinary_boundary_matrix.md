# Gate R0 ordinary Candidate A boundary matrix

This package is the test-only EGW authority and fresh-consumer seam. Production
`Document`, archive, wire, storage, and public Markdown interfaces remain
unchanged. The full-history oracle remains authoritative.

| Row | Functional-core input | Required decision/observation | Provider allowance | Initial vertical slice |
|---|---|---|---|---|
| R-01 | Candidate bytes for empty/non-empty settled fixtures | Validate text, exact ranked heads, writer commitments, graph/head/text hashes, and snapshot commit before editability | zero metadata, payload, and full-history reads | Empty then `S-linear-4` native encode/decode with frozen empty vector |
| R-02 | Candidate bytes with one corrupted committed component | Typed rejection naming the first invalid component before text/edit observation | zero payload and full-history reads | After R-01 |
| R-03 | Immutable candidate plus publication ref/current expected-old ref | Accept current CAS lineage or reject stale/mixed provenance without changing content identity | zero provider reads | After immutable validation |
| R-04 | Same immutable bytes in two fresh consumers | Equal content commit and distinct restore-time writer identities | zero provider reads | Native/JS process handoff after R-01 |
| R-05 | Canonical event with duplicate declared parent | `duplicate_declared_parent_unsupported`, never sort/dedup alias | explicit oracle path only | Capture preflight after event metadata exists |
| L-01 | Validated branch plus scalar insert position/value | New positional event, exact parent heads/rank/frontier/text, fresh writer | zero provider reads | First local edit after R rows |
| L-02 | Validated branch plus scalar delete position | New positional event and exact text/frontier parity | zero provider reads | After L-01 |
| L-03 | Validated branch plus two local decisions | Writer sequence/predecessor/rank continuity | zero existing-provider reads | After L-02 |
| L-04 | Validated branch with maximum head rank | Pure `rank_exhausted`; no event or mutation | zero provider reads | Rank allocator unit slice |
| L-05 | Undo request without target receipt | `pre_capture_undo_receipt_absent`; never infer identity from text | zero provider reads | Decision-only negative |
| F-01 | Validated branch plus closed hot region of 1/10/100 events | Prove coverage and apply exact effects/frontier | zero existing metadata, payload, and full-history reads | After local event core |
| F-02 | Closed hot source-equal event | Frontier advances while text remains byte-identical | zero existing-provider reads | F-01 variant |
| F-04 | Incoming event requiring an older predecessor proof but no body | Indexed-forward with authenticated verified metadata | metadata batch only; zero payload/full-history | After provider shell |
| D-01 | Queried identity outside resident writer ranges | Tier-0 authenticated non-membership | no provider call | Writer commitment lookup |
| D-02 | Exact in-range duplicate | Duplicate decision after verified metadata equality | metadata only | Provider/metadata verifier |
| D-03 | In-range identity differing in body/parent/predecessor/reference/rank | Exact conflict rejection | metadata only | D-02 variants |
| D-04 | Child before parent, then parent arrives | Pending identity then deterministic drain | metadata only as requested; no payload/full-history | Admission reducer |
| D-05 | Valid prefix plus unresolved suffix | Commit prefix sidecar only; disable capture while pending | metadata only as requested; no payload/full-history | Admission reducer |
| D-06 | Present predecessor unreachable through declared-parent closure | Reject/pending/fallback decision; never synthesize graph edge | authenticated metadata only | Closure verifier |

The pure core owns codec validation, commitment construction, state transitions,
provider requests, and structured decisions. The imperative shell owns native/JS
process I/O, provider calls, clocks/RSS, publication writes/CAS, and JSONL routing.
