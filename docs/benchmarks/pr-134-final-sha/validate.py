#!/usr/bin/env python3
"""Validate committed raw statistics and immutable measured inputs (no build)."""
import hashlib
import json
import math
from pathlib import Path
import statistics

ROOT = Path(__file__).resolve().parent


def read(path):
    return json.loads((ROOT / path).read_text())


def sha(path):
    return hashlib.sha256((ROOT / path).read_bytes()).hexdigest()


def main():
    result = read("raw/benchmark.json")
    config = read("harness/config.json")
    lock = read("harness/lock.json")
    assert result["status"] == "complete"
    assert result["config"] == config and result["source"] == lock["sources"]
    for key, path in [("harnessSha256", "harness/bench.mjs"), ("configSha256", "harness/config.json"), ("lockSha256", "harness/lock.json")]:
        assert result["hashes"][key] == sha(path), path
    for name in ["main.mbt", "moon.pkg"]:
        assert lock["bridge"]["bridge/" + name] == sha("bridge/" + name + ".template")
    assert lock["vendorManifestSha256"] == sha("provenance/vendor-manifest.json")
    assert len(result["rows"]) == len(config["remoteCases"]) + 1
    for row in result["rows"]:
        assert len(row["warmup"]) == config["warmupPairs"]
        assert len(row["pairs"]) == config["measuredPairs"]
        for i, pair in enumerate(row["warmup"] + row["pairs"]):
            assert pair["index"] == i
            assert pair["order"] == (["head", "base"] if i % 2 else ["base", "head"])
            assert pair["phase"] == ("warmup" if i < config["warmupPairs"] else "measured")
            assert pair["checks"]["historySha256"] == row["expectedHistorySha256"]
            assert pair["checks"]["versionSha256"] == row["expectedVersionSha256"]
            operations = config["baseScalars"] + row["changedOperations"] * (2 if row["scenario"].startswith("undo") else 1)
            assert pair["checks"]["historyOperations"] == operations
        for lane in ["base", "head"]:
            samples = [p["durationMs"][lane] for p in row["pairs"]]
            ordered = sorted(samples)
            reported = row[lane]
            assert samples == reported["samplesMs"] and reported["n"] == len(samples)
            assert reported["medianMs"] == statistics.median(samples)
            assert reported["p95Ms"] == ordered[math.ceil(len(samples) * .95) - 1]
            assert reported["maxMs"] == max(samples)
            assert reported["minMs"] == min(samples)
        assert row["baseToHeadMedianRatio"] == row["base"]["medianMs"] / row["head"]["medianMs"]
        assert all(v for v in row["checks"].values() if v is not None)
    print("Verified immutable harness/bridge/config/lock/dependencies and all 150 measured pairs / 175 total pairs")


if __name__ == "__main__":
    main()
