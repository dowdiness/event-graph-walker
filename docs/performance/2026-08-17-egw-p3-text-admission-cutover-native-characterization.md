# P3 Text admission cutover: paired native characterization

This is paired native-release characterization evidence for the Text ingress
cutover. It is not a cross-runtime performance claim.

## Provenance

| lane | source commit |
| --- | --- |
| before | `f4cfec3095906104d111f23f90fb458c736f9da4` |
| after | `e593319` (`feat/p3-text-admission-cutover`) |

The same temporary white-box matrix probe and measurement boundary were used
for both lanes:

```text
NEW_MOON_MOD=0 moon test --package text --target native --release \
  --filter '*P3.1 temporary Text ingress after-cutover matrix*' \
  --no-parallelize
```

The probe seeded resident history outside the timed region through the
Document admission boundary, then timed only `TextState::sync().apply`. It
covered H=`0/1k/10k/100k`, M=`1/10/100`, the complete, duplicate-only,
pending-only, and conflicting-identity lanes, plus dependency-drain at M=1.
Each lane has three independent process samples (52 rows per phase). The
pending columns use the public `pending_sync_count` contract, so the before
and after observations have the same boundary.

The temporary probe was deleted after collection. The raw CSVs are retained:

- [before CSV](./2026-08-17-egw-p3-text-admission-cutover-native-before.csv)
  — SHA-256 `39486cb693aa00a6c5082e3dcff992ebf729472e356aa9ac9eceaaf046e9a4b6`
- [after CSV](./2026-08-17-egw-p3-text-admission-cutover-native-after.csv)
  — SHA-256 `1ef3ae5154ebf4c66c759baf6078bc9301847e1517b31465510b8e84fe4412b5`

## Interpretation boundary

These observations verify the paired fixture, report values, pending
lifecycle, and native timing boundary. They do **not** promote an improvement
percentage: no wasm-gc/JS timing matrix is included here, and the source
probe is intentionally not part of the normal test suite. Cross-runtime
measurements and any performance claim require a separate reviewed evidence
update.
