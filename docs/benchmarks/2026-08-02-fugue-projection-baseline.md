# Fugue projection baseline evidence

Captured before production refactoring. D1-D9 values are per-process medians of five explicit operation-only samples. Other values are the Moon benchmark runner’s displayed per-process means. All table values are microseconds.

## Environment

```text
baseline_sha=15322c7621bf9cfc757a9ff76377211b894aabe3
origin_main=767abe928d1f2cb0470345dc2e9e80105e47b549
date=2026-08-02T12:39:46+09:00
uname=Linux A6 6.18.33.2-microsoft-standard-WSL2 #1 SMP PREEMPT_DYNAMIC Thu Jun 18 21:54:43 UTC 2026 x86_64 x86_64 x86_64 GNU/Linux
cpu=AMD Ryzen 7 6800H with Radeon Graphics
cores=8
memory=20481660 kB
governor=unavailable
moon 0.1.20260713 (75c7e1f 2026-07-13) ~/.moon/bin/moon
moonc v0.10.4+2cc641edf (2026-07-15) ~/.moon/bin/moonc
moonrun 0.1.20260713 (75c7e1f 2026-07-13) ~/.moon/bin/moonrun

Feature flags enabled: rr_moon_mod,rr_moon_pkg
lock_hash=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
completed=2026-08-02T12:53:36+09:00
```

Background policy: sequential benchmark commands, no intentionally concurrent workload. The first two exploratory D3 runs made before the recorded sets are excluded.

## Baseline sets

| Target | Key | Scenario | Set A raw (5 processes) | A median | Set B raw (5 processes) | B median | Repeat spread | Tolerance |
| --- | --- | --- | --- | ---: | --- | ---: | ---: | ---: |
| js | B1 | Branch checkout 1k | 764.440, 1000.000, 482.040, 472.030, 479.130 | 482.040 | 497.860, 550.340, 483.490, 530.730, 519.580 | 519.580 | 7.23% | 7.23% |
| js | B2 | Branch advance 50 | 113.780, 121.330, 50.640, 53.440, 54.300 | 54.300 | 52.330, 57.560, 49.630, 62.490, 51.720 | 52.330 | 3.63% | 5.00% |
| js | B3 | Branch repeated advance steady-state | 93.470, 128.400, 44.030, 40.910, 44.680 | 44.680 | 44.550, 45.430, 47.400, 55.990, 45.730 | 45.730 | 2.30% | 5.00% |
| js | B4 | Branch repeated advance with OpLog mutation | 6670.000, 7750.000, 6070.000, 6330.000, 5960.000 | 6330.000 | 6080.000, 6110.000, 6040.000, 6090.000, 6600.000 | 6090.000 | 3.79% | 5.00% |
| js | B5 | MergeContext apply-50 | 100.720, 88.160, 35.270, 33.860, 30.990 | 35.270 | 33.350, 31.070, 34.920, 32.410, 29.900 | 32.410 | 8.11% | 8.11% |
| js | D1 | Observed Insert 1k | 36.044, 50.456, 36.240, 44.114, 34.561 | 36.240 | 53.632, 49.102, 48.607, 51.745, 48.824 | 49.102 | 26.19% | 26.19% |
| js | D2 | Observed Insert 10k | 75.855, 88.799, 65.526, 76.055, 76.569 | 76.055 | 71.815, 65.500, 67.726, 83.704, 86.468 | 71.815 | 5.57% | 5.57% |
| js | D3 | Observed Insert 100k | 117.010, 97.006, 100.001, 91.421, 91.951 | 97.006 | 87.003, 90.395, 103.411, 95.655, 100.322 | 95.655 | 1.39% | 5.00% |
| js | D4 | Observed Delete 1k | 31.187, 52.372, 55.099, 44.790, 27.882 | 44.790 | 54.791, 49.904, 44.426, 54.018, 27.820 | 49.904 | 10.25% | 10.25% |
| js | D5 | Observed Delete 10k | 56.592, 59.670, 49.313, 49.411, 54.518 | 54.518 | 59.404, 44.906, 48.976, 48.787, 66.793 | 48.976 | 10.17% | 10.17% |
| js | D6 | Observed Delete 100k | 69.839, 80.749, 58.077, 66.646, 62.875 | 66.646 | 66.960, 68.380, 65.007, 72.713, 65.599 | 66.960 | 0.47% | 5.00% |
| js | D7 | Observed Undelete 1k | 71.816, 73.364, 23.799, 39.567, 52.524 | 52.524 | 40.868, 45.004, 32.147, 34.542, 34.922 | 34.922 | 33.51% | 33.51% |
| js | D8 | Observed Undelete 10k | 66.521, 86.748, 48.941, 49.031, 60.203 | 60.203 | 48.605, 57.483, 54.490, 63.797, 49.241 | 54.490 | 9.49% | 9.49% |
| js | D9 | Observed Undelete 100k | 80.596, 77.549, 66.958, 65.246, 74.706 | 74.706 | 77.267, 69.873, 82.643, 74.046, 68.633 | 74.046 | 0.88% | 5.00% |
| js | D10 | Remote insert/query 1k | 41910.000, 42010.000, 6380.000, 6980.000, 7850.000 | 7850.000 | 7240.000, 7220.000, 7100.000, 7040.000, 10230.000 | 7220.000 | 8.03% | 8.03% |
| js | D11 | Remote insert/query 5k | 148250.000, 165020.000, 49240.000, 51810.000, 49030.000 | 51810.000 | 56030.000, 59220.000, 55870.000, 55520.000, 55310.000 | 55870.000 | 7.27% | 7.27% |
| js | D12 | Reverse merge 10k | 317960.000, 493530.000, 121040.000, 127940.000, 122660.000 | 127940.000 | 144450.000, 133250.000, 142920.000, 143120.000, 150680.000 | 143120.000 | 10.61% | 10.61% |
| wasm-gc | B1 | Branch checkout 1k | 1020.000, 1270.000, 347.110, 378.830, 352.960 | 378.830 | 375.330, 371.680, 369.630, 407.300, 387.370 | 375.330 | 0.92% | 5.00% |
| wasm-gc | B2 | Branch advance 50 | 126.540, 126.870, 36.710, 41.990, 52.160 | 52.160 | 43.530, 39.120, 39.570, 46.920, 45.930 | 43.530 | 16.55% | 16.55% |
| wasm-gc | B3 | Branch repeated advance steady-state | 61.020, 79.550, 25.950, 26.040, 27.520 | 27.520 | 27.050, 27.110, 27.250, 32.540, 27.940 | 27.250 | 0.98% | 5.00% |
| wasm-gc | B4 | Branch repeated advance with OpLog mutation | 10070.000, 8180.000, 8050.000, 8740.000, 7650.000 | 8180.000 | 7560.000, 7760.000, 7160.000, 7710.000, 7190.000 | 7560.000 | 7.58% | 7.58% |
| wasm-gc | B5 | MergeContext apply-50 | 96.100, 90.330, 33.010, 31.790, 37.940 | 37.940 | 34.450, 31.510, 32.180, 34.760, 35.440 | 34.450 | 9.20% | 9.20% |
| wasm-gc | D1 | Observed Insert 1k | 33.704, 32.138, 24.611, 22.336, 27.175 | 27.175 | 23.559, 22.445, 32.868, 25.896, 23.019 | 23.559 | 13.31% | 13.31% |
| wasm-gc | D2 | Observed Insert 10k | 75.181, 68.946, 50.354, 44.391, 44.773 | 50.354 | 52.092, 46.727, 50.584, 53.718, 53.167 | 52.092 | 3.34% | 5.00% |
| wasm-gc | D3 | Observed Insert 100k | 75.425, 77.715, 79.482, 83.202, 81.340 | 79.482 | 76.840, 76.509, 76.199, 85.826, 87.500 | 76.840 | 3.32% | 5.00% |
| wasm-gc | D4 | Observed Delete 1k | 29.958, 20.420, 18.145, 17.082, 19.457 | 19.457 | 19.937, 17.479, 21.380, 17.700, 17.612 | 17.700 | 9.03% | 9.03% |
| wasm-gc | D5 | Observed Delete 10k | 52.443, 43.054, 28.769, 34.904, 31.332 | 34.904 | 51.179, 39.801, 34.364, 32.340, 28.097 | 34.364 | 1.55% | 5.00% |
| wasm-gc | D6 | Observed Delete 100k | 78.683, 54.607, 51.045, 50.956, 63.274 | 54.607 | 54.883, 55.154, 50.299, 55.292, 52.345 | 54.883 | 0.50% | 5.00% |
| wasm-gc | D7 | Observed Undelete 1k | 33.421, 33.825, 15.789, 21.171, 30.337 | 30.337 | 19.195, 19.358, 21.303, 26.385, 21.430 | 21.303 | 29.78% | 29.78% |
| wasm-gc | D8 | Observed Undelete 10k | 52.312, 43.238, 27.197, 35.207, 51.894 | 43.238 | 34.945, 49.985, 41.254, 32.411, 45.397 | 41.254 | 4.59% | 5.00% |
| wasm-gc | D9 | Observed Undelete 100k | 66.331, 49.558, 52.679, 52.507, 53.575 | 52.679 | 59.964, 55.433, 61.316, 62.656, 53.988 | 59.964 | 12.15% | 12.15% |
| wasm-gc | D10 | Remote insert/query 1k | 17670.000, 5280.000, 5480.000, 5560.000, 5790.000 | 5560.000 | 6920.000, 6250.000, 6700.000, 6100.000, 6070.000 | 6250.000 | 11.04% | 11.04% |
| wasm-gc | D11 | Remote insert/query 5k | 133400.000, 51810.000, 46560.000, 49690.000, 51830.000 | 51810.000 | 60740.000, 52800.000, 58100.000, 51900.000, 57540.000 | 57540.000 | 9.96% | 9.96% |
| wasm-gc | D12 | Reverse merge 10k | 339800.000, 90500.000, 79150.000, 82900.000, 90700.000 | 90500.000 | 130500.000, 90890.000, 145630.000, 91260.000, 100010.000 | 100010.000 | 9.51% | 9.51% |

## Raw logs

Uncommitted process logs: `/tmp/fugue-projection-baseline-15322c7`. Each file records the exact command, benchmark output, elapsed process time, and peak RSS.

Candidate runs must use the same selector map in `docs/plans/2026-08-02-fugue-projection-deepening.md`, compare against the median of all ten baseline process statistics, and use the scenario tolerance above.
