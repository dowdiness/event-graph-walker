#!/usr/bin/env python3
"""Stdlib tests for the Fugue projection benchmark runner and summarizer."""
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))


def load_module(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / filename)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {filename}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


runner = load_module("fugue_runner", "run-fugue-projection-bench.py")
summary = load_module("fugue_summary", "summarize-fugue-projection-bench.py")


class FugueProjectionBenchTests(unittest.TestCase):
    def values(self, candidate: float = 102.0) -> dict[int, dict[str, float]]:
        return {pair: {"baseline": 100.0, "candidate": candidate} for pair in range(1, 11)}

    def test_parsing_statistics_and_classification(self) -> None:
        self.assertEqual(summary.parse_unit("μs"), "µs")
        self.assertAlmostEqual(summary.number_with_unit("1.5 ms"), 1500.0)
        self.assertEqual(summary.parse_metric(b"median: 2 ms\n", "B1"), 2000.0)
        self.assertEqual(summary.median([3.0, 1.0, 2.0]), 2.0)
        self.assertAlmostEqual(summary.percentile([1.0, 2.0, 4.0, 8.0], 0.5), 3.0)
        self.assertAlmostEqual(summary.paired_delta([100.0] * 10, [102.0] * 10), 0.02)

    def test_ten_pair_pass_fail_and_inconclusive(self) -> None:
        passed = summary.classify(self.values(102.0), 10)
        failed = summary.classify(self.values(110.0), 10)
        split = self.values(102.0)
        for pair in range(6, 11):
            split[pair]["candidate"] = 120.0
        inconclusive = summary.classify(split, 10)
        self.assertEqual(passed["result"], "PASS")
        self.assertEqual(failed["result"], "FAIL")
        self.assertEqual(inconclusive["result"], "INCONCLUSIVE")
        with self.assertRaises(summary.SummaryError):
            summary.classify(self.values(), 9)

    def test_fifteen_pair_extension_requires_inconclusive_first_ten(self) -> None:
        values = self.values(102.0)
        for pair in range(6, 11):
            values[pair]["candidate"] = 120.0
        for pair in range(11, 16):
            values[pair] = {"baseline": 100.0, "candidate": 103.0}
        result = summary.classify(values, 10)
        self.assertEqual(result["pair_count"], 15)
        self.assertEqual(result["result"], "PASS")
        self.assertEqual(result["tolerance"], summary.classify(self.values(), 10)["tolerance"])
        with self.assertRaises(summary.SummaryError):
            summary.classify({**values, 16: {"baseline": 100.0, "candidate": 100.0}}, 10)

    def test_fifteen_pair_extension_rejects_initial_pass_and_fail(self) -> None:
        for candidate in (102.0, 110.0):
            values = self.values(candidate)
            for pair in range(11, 16):
                values[pair] = {"baseline": 100.0, "candidate": candidate}
            with self.assertRaises(summary.SummaryError):
                summary.classify(values, 10)

    def test_time_metadata_format_and_consistency(self) -> None:
        self.assertEqual(summary.parse_time_metadata("elapsed_s=1.25\nmax_rss_kb=42\n"), (1.25, 42))
        with self.assertRaises(summary.SummaryError):
            summary.parse_time_metadata("elapsed_s=nan\nmax_rss_kb=42\n")
        with self.assertRaises(summary.SummaryError):
            summary.parse_time_metadata("elapsed_s=1\nmax_rss_kb=42\nextra=1\n")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = self.make_manifest(root, 10)
            self.write_samples(root, manifest)
            self.assertEqual(len(summary.load_samples(root, manifest)), 1)
            time_path = root / manifest["expected_samples"][0]["relative_time"]
            time_path.write_text("elapsed_s=9\nmax_rss_kb=42\n")
            with self.assertRaises(summary.SummaryError):
                summary.load_samples(root, manifest)

    def test_malformed_extension_inventory_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = self.make_manifest(root, 15)
            manifest["expected_samples"] = [
                item for item in manifest["expected_samples"] if int(item["pair"]) != 14
            ]
            manifest["completed_samples"] = [
                item for item in manifest["completed_samples"] if int(item["pair"]) != 14
            ]
            self.write_samples(root, manifest)
            with self.assertRaises(summary.SummaryError):
                summary.load_samples(root, manifest)

    def test_selector_and_extension_safeguards(self) -> None:
        self.assertEqual(runner.selector_token("js:B1"), ("js", "B1"))
        self.assertEqual(runner.parse_pair_range("11-15"), (11, 15))
        with self.assertRaises(runner.RunnerError):
            runner.selector_token("native:B1")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = self.make_manifest(root, 10)
            runner.require_complete_initial_inventory(manifest, "js", "B1")
            manifest["completed_samples"] = manifest["completed_samples"][:-1]
            with self.assertRaises(runner.RunnerError):
                runner.require_complete_initial_inventory(manifest, "js", "B1")

    def test_extension_authorization_requires_exact_inconclusive_selector(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = self.make_manifest(root, 10)
            root.joinpath("run.json").write_text(json.dumps(manifest))
            metrics = {(pair, role): (102.0 if pair <= 5 else 120.0) for pair in range(1, 11) for role in ("baseline", "candidate")}
            metrics.update({(pair, "baseline"): 100.0 for pair in range(1, 11)})
            self.write_samples(root, manifest, metrics)
            result = summary.authorize_extension(root, "js:B1")
            self.assertEqual(result["result"], "INCONCLUSIVE")
            for candidate in (102.0, 110.0):
                metrics = {(pair, role): (100.0 if role == "baseline" else candidate) for pair in range(1, 11) for role in ("baseline", "candidate")}
                self.write_samples(root, manifest, metrics)
                with self.assertRaises(summary.SummaryError):
                    summary.authorize_extension(root, "js:B1")
            with self.assertRaises(summary.SummaryError):
                summary.authorize_extension(root, "B1")
            with self.assertRaises(summary.SummaryError):
                summary.authorize_extension(root, "wasm-gc:B1")

    def test_pair_count_is_exactly_ten(self) -> None:
        args = runner.make_parser().parse_args([
            "--baseline-worktree", ".", "--candidate-worktree", ".", "--output-dir", "/tmp/unused",
            "--pair-count", "9",
        ])
        with self.assertRaises(runner.RunnerError):
            runner.run(args)

    def test_moon_version_all_provenance_helper(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "moon"
            executable.write_text("#!/bin/sh\nprintf 'moon feature flags: wasm-gc\\n'\n")
            executable.chmod(0o755)
            captured = runner.moon_version_all(str(executable))
            self.assertEqual(captured["command"], [str(executable), "version", "--all"])
            self.assertIn("feature flags: wasm-gc", captured["output"])
            self.assertEqual(captured["returncode"], 0)

    def test_environment_allowlist_and_provenance_fingerprint(self) -> None:
        secret = "do-not-persist-this-secret"
        snapshot = runner.environment_snapshot(
            {"PATH": "/secret/path", "API_TOKEN": secret, "LANG": "C", "TZ": "UTC"}
        )
        self.assertEqual(snapshot["variables"], {"LANG": "C", "TZ": "UTC"})
        self.assertNotIn(secret, json.dumps(snapshot))
        self.assertNotIn("full_environment_sha256", snapshot)
        base = {
            "revision": "a",
            "git_diff_HEAD_binary_sha256": "b",
            "staged_status": "",
            "untracked_moonbit_source_inventory": {"new.mbt": "hash-1"},
            "lock_sha256": {"moon.lock": "lock-1"},
            "toolchain": {"moon": {"executable": "/bin/moon", "version": "1"}},
        }
        changed = {**base, "untracked_moonbit_source_inventory": {"new.mbt": "hash-2"}}
        self.assertNotEqual(runner.provenance_fingerprint(base), runner.provenance_fingerprint(changed))
        changed_toolchain = {**base, "toolchain": {**base["toolchain"], "moon_version_all": {"output": "feature-flags-a"}}}
        self.assertNotEqual(runner.provenance_fingerprint(base), runner.provenance_fingerprint(changed_toolchain))
        with tempfile.TemporaryDirectory() as directory:
            worktree = Path(directory)
            subprocess.run(
                ["git", "init", "--quiet"],
                cwd=worktree,
                check=True,
            )
            source = worktree / "new file.mbt"
            source.write_text("test")
            self.assertEqual(
                runner.inventory(worktree),
                {"new file.mbt": runner.sha256_file(source)},
            )

    def make_manifest(self, root: Path, pair_count: int) -> dict:
        scenarios = [("js", runner.SCENARIO_BY_KEY["B1"])]
        expected = runner.expected_entries(scenarios, (1, pair_count), False)
        for item in expected:
            item["extension"] = int(item["pair"]) > 10
        completed = [
            {"target": item["target"], "key": item["key"], "pair": item["pair"], "role": item["role"]}
            for item in expected
        ]
        return {
            "schema": "fugue-projection-paired-bench-v1",
            "initial_pair_count": 10,
            "selector_map": [
                {"key": key, "package": package, "file": file_name, "index": index, "name": name}
                for key, package, file_name, index, name in runner.SCENARIOS
            ],
            "expected_samples": expected,
            "completed_samples": completed,
        }

    def write_samples(self, root: Path, manifest: dict, metrics: dict[tuple[int, str], float] | None = None) -> None:
        for item in manifest["expected_samples"]:
            for field in ("relative_stdout", "relative_stderr", "relative_time", "relative_meta"):
                path = root / item[field]
                path.parent.mkdir(parents=True, exist_ok=True)
                if field == "relative_stdout":
                    metric = 100.0 if metrics is None else metrics[(int(item["pair"]), item["role"])]
                    path.write_text(f"median: {metric} us\n")
                elif field == "relative_time":
                    path.write_text("elapsed_s=1.25\nmax_rss_kb=42\n")
                elif field == "relative_meta":
                    path.write_text(json.dumps({
                        "target": item["target"], "key": item["key"], "pair": item["pair"],
                        "role": item["role"], "relative_time": item["relative_time"], "returncode": 0,
                        "elapsed_s": 1.25, "max_rss_kb": 42,
                    }) + "\n")
                else:
                    path.write_text("")


if __name__ == "__main__":
    unittest.main()
