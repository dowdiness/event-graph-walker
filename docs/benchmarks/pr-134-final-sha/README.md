# PR #134: exact implementation-source performance evidence

These measurements compare the exact implementation commits below. The later commit adding this directory is **evidence-only**: it does not change the measured engine implementation. Do not attribute these timings to an unmeasured future PR head or a PR merge ref.

| Source | Commit | Git tree |
|---|---|---|
| base | `ed2e89e1bdc6f64e979e63d0b23d83e6b99872bc` | `8334ae00018b9a7919eaed46ac2a8c329cecb07c` |
| measured implementation head | `eea050d5737ea3a699948150ea92c72e757fa2ca` | `ba5056f85b7228bcb5cc5a32de8c9cf44a8ffe7f` |

Both were newly built with MoonBit compiler **and core** `0.10.14+7d59c7ec9`, Moon CLI `0.1.20260920 (914d7da 2026-09-20)`, `moon build --target js --release bridge`, and Node `24.19.0`. The historical stage-11 binary was not reused. Builds from a separately extracted reproduction bundle reproduced both JS binaries byte-for-byte.

## Results

Milliseconds, **median / nearest-rank p95 / max**, with the first post-change public text getter and full UTF-16 checksum inside every timed interval.

| Operation | Base | Head | Median base/head ratio |
|---|---:|---:|---:|
| receive4 | 65.984 / 70.944 / 72.373 | 0.698 / 0.960 / 0.964 | 94.54x |
| receive20 | 64.637 / 81.008 / 89.222 | 1.164 / 1.810 / 2.243 | 55.52x |
| receive32 | 62.952 / 67.710 / 74.478 | 1.457 / 1.824 / 1.851 | 43.22x |
| receive1000 | 93.702 / 114.919 / 121.722 | 25.632 / 34.324 / 43.709 | 3.66x |
| undo1000 | 1603.214 / 1731.314 / 1785.304 | 4.435 / 8.961 / 10.130 | 361.48x |

Each row has 5 warmup pairs and 30 measured pairs. All 175 pairs passed exact text, history-byte, Version-byte, operation-count and pending checks. [The unchanged raw JSON](raw/benchmark.json) includes every warmup/sample, execution order, checksums and per-pair history hashes. No outliers were excluded. With 30 samples, p95 is the 29th sorted observation; this is limited tail evidence, not a long-run guarantee or confidence interval.

The 1000-op receive improves but still takes **25.632 ms median / 34.324 ms p95 / 43.709 ms max**. These results do not establish browser frame-budget compliance, mobile performance, general scalability, or blanket parity with another library.

## Method and exclusions

- The deterministic fixture is 10,000 ASCII scalars and 10,000 operations, made by repeating `abcdefghijklmnopqrstuvwxyz0123456789\n`. Base/head generation must produce identical text, canonical history bytes and Version bytes
- Every lane/sample creates a **fresh receiver**, imports that same fixture, verifies full history and Version, and reads its text before the timed change. No reset operations or retained-history growth accumulate across samples. This measures a warmed projection, not cold restore
- Remote cases insert distinct new characters at the middle (position 5000). The 4/20/32/1000 operations have distinct IDs and are causally chained. They are delivered together as **one whole packet**, never split or resent
- Undo setup imports the shared seed with no local Undo history, then uses normal `replace_range_and_record` through the bridge's `edit` to record one 1000-scalar paste group. One timed Undo restores the initial text, clears `can_undo`, and leaves exactly 12,000 accepted operations
- Remote timing includes JSON decode, packet validation/admission, transition finalization, effect serialization/report parsing, then the **first** changed-text getter and checksum. Undo timing includes `UndoManager.undo`, then that first getter and checksum. Exact effects must reconstruct the expected result; all remote deliveries have zero pending/duplicates. Base returned snapshot and head exact for every remote sample
- AB/BA order alternates, with 15 measured pairs in each order. Both modules run in one Node process using default GC, no forced collection or optimization flags
- Source builds, fixture/sender generation, receiver import and pre-read, Undo's paste, exact post-timer assertions, and cleanup are excluded. Recorded pair setup is roughly 0.9–1.2 seconds and includes validation; it is not a standalone restore benchmark. Initial builds were approximately one second per lane
- Measured 2026-10-02T08:43:04.245Z to 2026-10-02T08:47:54.097Z on Linux/Debian 13.6, AMD EPYC 9V74 shared virtual hardware, allowed CPUs 0–8 without affinity pinning. Other local engineering jobs were idle, but host co-tenancy, migration and GC were uncontrolled
- Browser/editor paint, mobile, network, IndexedDB, wasm/native, cold projection, Unicode/production documents and long-running retained histories were not measured. The earlier stage-11 numbers have different artifacts/conditions and should not be combined with these results

## Reproduction

Required: Python 3.12+ (tar extraction safety filter), Git, Node 24.19.0, and the pinned MoonBit compiler **and matching core**. Put `moon`/`moonc` on PATH and set `MOON_HOME` if it is not `$HOME/.moon`. The runner downloads only public pinned repository sources via Git and fixed dependencies via `moon update`. It fails on dependency-content or compiled-binary hash differences.

```sh
python3 docs/benchmarks/pr-134-final-sha/validate.py
python3 docs/benchmarks/pr-134-final-sha/reproduce.py \
  --work-dir /tmp/egw-pr134-reproduction
```

The work directory must be new/empty and outside the repository. Generated packages, binaries, fixtures, logs and fresh measurements stay there. To verify the builds without re-running the approximately five-minute measurement sequence, add `--build-only`. For offline reuse, pass `--source-repo /path/to/egw-clone` containing both pinned commits and `--dependency-cache /path/to/.mooncakes`; every dependency file remains hash-checked.

The measured [harness](harness/bench.mjs), [configuration](harness/config.json), and [lock metadata](harness/lock.json) are byte-identical to the recorded run. The lock's archive hashes identify the original external bundle; this repository-native runner verifies source commit/tree identity instead of requiring those archives. The bridge templates preserve the measured bridge byte-for-byte and import only public facades. They deliberately end in `.template` so they do not create a MoonBit package inside this repository; the unused experimental fast-control exports are not invoked by these cases.

`validate.py` checks committed statistics and immutable inputs without downloads. `reproduce.py` generates the fixture and packets deterministically, reconstructs isolated workspaces and verifies the recorded binary hashes before running the unchanged harness. It writes new `results/benchmark.json` in the external work directory and never overwrites committed raw data. Reproduction under other runtimes or changed dependencies should be reported as a different experiment.

## Provenance

[Environment and tool/core hashes](provenance/environment.json), [dependency content manifest](provenance/vendor-manifest.json), and the raw JSON preserve the measured source/fixture/packet/input hashes. Exact source commits are public and retained above; large archives, vendor copies, generated fixture files and compiled binaries are intentionally not committed.

- Base JS SHA-256: `55afbfccafbcefb5d52cd919d9e1f1f19e6120e0e590cb8cd2bdc01464fdf255`
- Head JS SHA-256: `868435facd9a661de51a94f13f336dc7fedd05ba187464870cc777b195ec9cfc`
- Harness SHA-256: `77ddfb1fd340027ab008bdd857256c1170a9de92cab7b9a4f45bd18a09a75f8b`

The companion evidence-only commit does not repeat engine performance measurements. Its checks cover this evidence/reproduction path and repository CI; the timings remain attributed specifically to `eea050d` versus `ed2e89e`.
