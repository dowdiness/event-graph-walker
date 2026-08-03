#!/usr/bin/env python3
"""Summarize Fugue projection paired benchmark logs.

Parsing, statistics, and classification are pure functions over strings and
numbers.  Only manifest/log loading and report writing touch the filesystem.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import re
import sys
from pathlib import Path
from typing import Any, Iterable

from fugue_projection_bench_common import SCENARIOS, SCENARIO_BY_KEY, TARGETS

UNITS = {
    "ns": 1e-3,
    "nanosecond": 1e-3,
    "nanoseconds": 1e-3,
    "us": 1.0,
    "µs": 1.0,
    "μs": 1.0,
    "microsecond": 1.0,
    "microseconds": 1.0,
    "ms": 1e3,
    "millisecond": 1e3,
    "milliseconds": 1e3,
    "s": 1e6,
    "sec": 1e6,
    "second": 1e6,
    "seconds": 1e6,
}
NUMBER_UNIT = re.compile(r"(?<![A-Za-z0-9_])([+-]?(?:\d[\d,]*\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)\s*(ns|µs|μs|us|ms|seconds?|milliseconds?|microseconds?|nanoseconds?|sec|s)\b", re.IGNORECASE)
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")


class SummaryError(ValueError):
    pass


def parse_time_metadata(text: str) -> tuple[float, int]:
    lines = [line for line in text.splitlines() if line]
    elapsed_matches = re.findall(r"^elapsed_s=([0-9.eE+-]+)$", text, re.MULTILINE)
    rss_matches = re.findall(r"^max_rss_kb=(\d+)$", text, re.MULTILINE)
    if len(lines) != 2 or len(elapsed_matches) != 1 or len(rss_matches) != 1:
        raise SummaryError("time metadata must contain exactly one elapsed_s and max_rss_kb record")
    try:
        elapsed = float(elapsed_matches[0])
        rss = int(rss_matches[0])
    except ValueError as exc:
        raise SummaryError("time metadata contains an invalid elapsed/RSS value") from exc
    if not math.isfinite(elapsed) or elapsed < 0 or rss < 0:
        raise SummaryError("time metadata contains an invalid elapsed/RSS value")
    return elapsed, rss


def parse_unit(value: str) -> str:
    normalized = value.strip().lower().replace("μ", "µ")
    if normalized not in UNITS:
        raise SummaryError(f"unknown time unit {value!r}")
    return normalized


def number_with_unit(text: str, default_unit: str | None = None) -> float | None:
    match = NUMBER_UNIT.search(text)
    if match:
        number, unit = match.groups()
        return float(number.replace(",", "")) * UNITS[parse_unit(unit)]
    if default_unit is not None:
        match = re.search(r"(?<![A-Za-z0-9_])([+-]?(?:\d[\d,]*\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)", text)
        if match:
            return float(match.group(1).replace(",", "")) * UNITS[parse_unit(default_unit)]
    return None


def unit_from_key(key: str) -> str | None:
    normalized = key.lower().replace("_", "").replace("-", "")
    for suffix, unit in (("nanoseconds", "ns"), ("nanosecond", "ns"), ("milliseconds", "ms"), ("millisecond", "ms"), ("microseconds", "µs"), ("microsecond", "µs"), ("usec", "us"), ("msec", "ms"), ("nsec", "ns"), ("seconds", "s"), ("second", "s"), ("ns", "ns"), ("us", "us"), ("µs", "µs"), ("μs", "µs"), ("ms", "ms"), ("sec", "s"), ("s", "s")):
        if normalized.endswith(suffix):
            return unit
    return None


def json_candidates(value: Any, inherited_unit: str | None = None, key_hint: str = "") -> list[tuple[int, float]]:
    candidates: list[tuple[int, float]] = []
    if isinstance(value, dict):
        local_unit = inherited_unit
        for key in ("unit", "units", "time_unit"):
            if isinstance(value.get(key), str):
                local_unit = value[key]
        for key, child in value.items():
            key_lower = key.lower()
            key_unit = unit_from_key(key) or local_unit
            rank = 0 if key_lower in ("median", "median_time", "median_duration") else 1 if key_lower in ("p50", "q50") else 2 if key_lower in ("value", "time", "duration", "mean", "average") else 3
            if isinstance(child, (int, float)) and not isinstance(child, bool) and key_unit:
                candidates.append((rank, float(child) * UNITS[parse_unit(key_unit)]))
            elif isinstance(child, str):
                parsed = number_with_unit(child, key_unit)
                if parsed is not None:
                    candidates.append((rank, parsed))
            candidates.extend(json_candidates(child, key_unit, key))
    elif isinstance(value, list):
        for child in value:
            candidates.extend(json_candidates(child, inherited_unit, key_hint))
    elif isinstance(value, str):
        parsed = number_with_unit(value, inherited_unit)
        if parsed is not None:
            candidates.append((3, parsed))
    if key_hint and isinstance(value, (int, float)) and not isinstance(value, bool):
        key_unit = unit_from_key(key_hint) or inherited_unit
        if key_unit:
            rank = 0 if "median" in key_hint.lower() else 3
            candidates.append((rank, float(value) * UNITS[parse_unit(key_unit)]))
    return [(rank, value) for rank, value in candidates if math.isfinite(value) and value > 0]


def parse_json_metric(text: str) -> float | None:
    stripped = text.strip()
    values: list[tuple[int, float]] = []
    try:
        values = json_candidates(json.loads(stripped))
    except json.JSONDecodeError:
        # Some runners prefix one JSON record with a log line.  Only parse
        # complete JSON lines here; arbitrary brace extraction is ambiguous.
        for line in stripped.splitlines():
            try:
                values.extend(json_candidates(json.loads(line)))
            except json.JSONDecodeError:
                continue
    if not values:
        return None
    best_rank = min(rank for rank, _ in values)
    best = [value for rank, value in values if rank == best_rank]
    if max(best) - min(best) > max(1e-9, abs(best[0]) * 1e-9):
        raise SummaryError("JSON benchmark output contains multiple conflicting median/value metrics")
    return best[0]


def parse_displayed_metric(text: str, name: str) -> float:
    clean = ANSI.sub("", text)
    ranked: list[tuple[int, float, str]] = []
    for line in clean.splitlines():
        if not NUMBER_UNIT.search(line):
            continue
        value = number_with_unit(line)
        if value is None or not math.isfinite(value) or value <= 0:
            continue
        lower = line.lower()
        if name.lower() in lower:
            rank = 0
        elif "median" in lower or "p50" in lower:
            rank = 1
        elif re.search(r"\btime\s*:", lower):
            rank = 2
        elif "bench" in lower or "test" in lower:
            rank = 3
        else:
            rank = 4
        ranked.append((rank, value, line.strip()))
    if not ranked:
        raise SummaryError("benchmark output contains no displayed value with a recognized time unit")
    best_rank = min(item[0] for item in ranked)
    best = [item for item in ranked if item[0] == best_rank]
    values = [item[1] for item in best]
    if len(values) > 1 and max(values) - min(values) > max(1e-9, abs(values[0]) * 1e-9):
        raise SummaryError("benchmark output contains multiple equally-ranked displayed metrics")
    return values[0]


def parse_metric(stdout: bytes, name: str) -> float:
    text = stdout.decode("utf-8", errors="replace")
    parsed = parse_json_metric(text)
    value = parsed if parsed is not None else parse_displayed_metric(text, name)
    if not math.isfinite(value) or value <= 0:
        raise SummaryError(f"benchmark metric must be finite and positive, got {value}")
    return value


def median(values: Iterable[float]) -> float:
    ordered = sorted(values)
    if not ordered:
        raise SummaryError("median requires at least one value")
    middle = len(ordered) // 2
    return ordered[middle] if len(ordered) % 2 else (ordered[middle - 1] + ordered[middle]) / 2.0


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    if not ordered:
        raise SummaryError("percentile requires at least one value")
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] + weight * (ordered[upper] - ordered[lower])


def baseline_spread(first_ten: list[float]) -> float:
    centre = median(first_ten)
    p10 = percentile(first_ten, 0.10)
    p90 = percentile(first_ten, 0.90)
    return max(abs(p10 / centre - 1.0), abs(p90 / centre - 1.0))


def paired_delta(baseline: list[float], candidate: list[float]) -> float:
    if len(baseline) != len(candidate) or not baseline:
        raise SummaryError("paired samples must have equal nonzero lengths")
    return math.exp(median(math.log(c / b) for b, c in zip(baseline, candidate))) - 1.0


def unpaired_delta(baseline: list[float], candidate: list[float]) -> float:
    return median(candidate) / median(baseline) - 1.0


def classify_block(delta: float, tolerance: float) -> str:
    return "PASS" if delta <= tolerance else "FAIL"


def classify(values: dict[int, dict[str, float]], initial_pair_count: int) -> dict[str, Any]:
    if initial_pair_count != 10:
        raise SummaryError("the summarizer requires exactly ten initial pairs")
    pairs = sorted(values)
    first_pairs = list(range(1, 11))
    if any(pair not in values for pair in first_pairs):
        raise SummaryError("missing one of the required first ten pairs")
    first_baseline = [values[pair]["baseline"] for pair in first_pairs]
    first_candidate = [values[pair]["candidate"] for pair in first_pairs]
    spread = baseline_spread(first_baseline)
    tolerance = max(0.05, spread)
    block_a = paired_delta(first_baseline[:5], first_candidate[:5])
    block_b = paired_delta(first_baseline[5:], first_candidate[5:])
    block_a_status = classify_block(block_a, tolerance)
    block_b_status = classify_block(block_b, tolerance)
    first_delta = paired_delta(first_baseline, first_candidate)
    if len(pairs) == 10:
        result = "INCONCLUSIVE" if block_a_status != block_b_status else classify_block(first_delta, tolerance)
        pooled_delta = None
        block_c = None
    elif pairs == list(range(1, 16)):
        if block_a_status == block_b_status:
            raise SummaryError(
                "15-pair inventory is legal only when the first-ten block verdicts disagree"
            )
        all_baseline = [values[pair]["baseline"] for pair in pairs]
        all_candidate = [values[pair]["candidate"] for pair in pairs]
        pooled_delta = paired_delta(all_baseline, all_candidate)
        block_c = paired_delta(all_baseline[10:], all_candidate[10:])
        # The tolerance remains derived from the original ten baseline values.
        result = classify_block(pooled_delta, tolerance)
    else:
        raise SummaryError("extension logs must add exactly pairs 11-15; no other inventory is valid")
    return {
        "baseline_raw_us": first_baseline if len(pairs) == 10 else [values[pair]["baseline"] for pair in pairs],
        "candidate_raw_us": first_candidate if len(pairs) == 10 else [values[pair]["candidate"] for pair in pairs],
        "baseline_median_us": median(first_baseline),
        "candidate_median_us": median(first_candidate),
        "baseline_spread": spread,
        "tolerance": tolerance,
        "paired_delta": first_delta,
        "block_a_delta": block_a,
        "block_b_delta": block_b,
        "block_a_status": block_a_status,
        "block_b_status": block_b_status,
        "pooled_delta": pooled_delta,
        "block_c_delta": block_c,
        "unpaired_delta": unpaired_delta(first_baseline, first_candidate),
        "pair_count": len(pairs),
        "result": result,
    }


def expected_log_paths(manifest: dict[str, Any]) -> set[str]:
    paths: set[str] = set()
    for item in manifest["expected_samples"]:
        for key in ("relative_stdout", "relative_stderr", "relative_time", "relative_meta"):
            paths.add(item[key])
    return paths


def validate_manifest(manifest: dict[str, Any]) -> None:
    if manifest.get("schema") != "fugue-projection-paired-bench-v1":
        raise SummaryError("unsupported or missing runner manifest schema")
    if manifest.get("initial_pair_count") != 10:
        raise SummaryError("runner manifest must have exactly ten initial pairs")
    actual_map = manifest.get("selector_map")
    expected_map = [{"key": key, "package": package, "file": file_name, "index": index, "name": name} for key, package, file_name, index, name in SCENARIOS]
    if actual_map != expected_map:
        raise SummaryError("manifest selector map is not the frozen B1-B5/D1-D12 map")
    seen: set[tuple[str, str, int, str]] = set()
    for item in manifest.get("expected_samples", []):
        identity = (item.get("target", ""), item.get("key", ""), int(item.get("pair", 0)), item.get("role", ""))
        if identity in seen:
            raise SummaryError(f"duplicate expected sample {identity}")
        seen.add(identity)
        if identity[0] not in TARGETS or identity[1] not in SCENARIO_BY_KEY or identity[3] not in ("baseline", "candidate"):
            raise SummaryError(f"invalid expected sample {identity}")
        if identity[2] < 1:
            raise SummaryError(f"invalid pair number {identity[2]}")
        if identity[2] > 15:
            raise SummaryError(f"extension pair exceeds 15: {identity}")
        initial_count = int(manifest["initial_pair_count"])
        if bool(item.get("extension")) != (identity[2] > initial_count):
            raise SummaryError(f"extension flag disagrees with pair number: {identity}")
        for field in ("relative_stdout", "relative_stderr", "relative_time", "relative_meta"):
            raw_path = item.get(field)
            path = Path(raw_path) if isinstance(raw_path, str) else Path("/")
            if path.is_absolute() or ".." in path.parts or not path.parts or path.parts[0] != "raw":
                raise SummaryError(f"unsafe or malformed raw-log path in expected sample: {raw_path!r}")
    if len(seen) != len(manifest.get("expected_samples", [])):
        raise SummaryError("manifest expected sample inventory is malformed")
    completed = manifest.get("completed_samples")
    if not isinstance(completed, list):
        raise SummaryError("manifest completed sample inventory is missing")
    completed_ids: set[tuple[str, str, int, str]] = set()
    for item in completed:
        try:
            identity = (str(item["target"]), str(item["key"]), int(item["pair"]), str(item["role"]))
        except (KeyError, TypeError, ValueError) as exc:
            raise SummaryError(f"malformed completed sample inventory entry: {item!r}") from exc
        if identity in completed_ids:
            raise SummaryError(f"duplicate completed sample {identity}")
        completed_ids.add(identity)
    if completed_ids != seen:
        raise SummaryError("completed sample inventory does not exactly match expected samples")


def load_samples(input_dir: Path, manifest: dict[str, Any]) -> dict[tuple[str, str], dict[int, dict[str, float]]]:
    validate_manifest(manifest)
    expected = expected_log_paths(manifest)
    raw_dir = input_dir / "raw"
    if not raw_dir.is_dir():
        raise SummaryError(f"missing raw log directory: {raw_dir}")
    actual = {str(path.relative_to(input_dir)) for path in raw_dir.rglob("*") if path.is_file()}
    extra = sorted(actual - expected)
    missing = sorted(expected - actual)
    if extra:
        raise SummaryError("extra or unrecognized raw log(s): " + ", ".join(extra))
    if missing:
        raise SummaryError("missing raw log(s): " + ", ".join(missing))
    groups: dict[tuple[str, str], dict[int, dict[str, float]]] = {}
    for item in manifest["expected_samples"]:
        meta_path = input_dir / item["relative_meta"]
        try:
            metadata = json.loads(meta_path.read_text())
        except (OSError, json.JSONDecodeError) as exc:
            raise SummaryError(f"malformed metadata {meta_path}: {exc}") from exc
        for field in ("target", "key", "pair", "role", "returncode", "elapsed_s", "max_rss_kb", "relative_time"):
            if field not in metadata:
                raise SummaryError(f"metadata {meta_path} lacks {field}")
        if (metadata["target"], metadata["key"], metadata["pair"], metadata["role"]) != (item["target"], item["key"], item["pair"], item["role"]):
            raise SummaryError(f"metadata identity mismatch in {meta_path}")
        if metadata["relative_time"] != item["relative_time"]:
            raise SummaryError(f"metadata time-path mismatch in {meta_path}")
        try:
            elapsed = float(metadata["elapsed_s"])
            rss = int(metadata["max_rss_kb"])
        except (TypeError, ValueError) as exc:
            raise SummaryError(f"invalid process metadata in {meta_path}") from exc
        if metadata["returncode"] != 0 or not math.isfinite(elapsed) or elapsed < 0 or rss < 0:
            raise SummaryError(f"failed or invalid process metadata in {meta_path}")
        try:
            recorded_elapsed, recorded_rss = parse_time_metadata((input_dir / item["relative_time"]).read_text(errors="replace"))
        except (OSError, SummaryError) as exc:
            raise SummaryError(f"cannot parse {input_dir / item['relative_time']}: {exc}") from exc
        if recorded_elapsed != elapsed or recorded_rss != rss:
            raise SummaryError(f"time metadata disagrees with process metadata in {meta_path}")
        stdout_path = input_dir / item["relative_stdout"]
        try:
            metric = parse_metric(stdout_path.read_bytes(), item["name"])
        except (OSError, SummaryError) as exc:
            raise SummaryError(f"cannot parse {stdout_path}: {exc}") from exc
        group = groups.setdefault((item["target"], item["key"]), {})
        pair = int(item["pair"])
        role = item["role"]
        group.setdefault(pair, {})[role] = metric
    for identity, pairs in groups.items():
        for pair, roles in pairs.items():
            if set(roles) != {"baseline", "candidate"}:
                raise SummaryError(f"pair inventory is incomplete for {identity} pair {pair}")
        initial = {pair for pair in pairs if pair <= 10}
        if initial != set(range(1, 11)):
            raise SummaryError(f"{identity} does not contain exactly the required first ten pairs")
        extension = {pair for pair in pairs if pair > 10}
        if extension and extension != set(range(11, 16)):
            raise SummaryError(f"{identity} has malformed/missing/extra extension pairs: {sorted(extension)}")
    return groups


def percent(value: float | None) -> str:
    return "—" if value is None else f"{value * 100:+.2f}%"


def number(value: float) -> str:
    return f"{value:.3f}"


def markdown(manifest: dict[str, Any], results: dict[tuple[str, str], dict[str, Any]], input_dir: Path) -> str:
    lines = [
        "# Fugue projection paired benchmark summary",
        "",
        f"Generated at `{dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds')}` from `{input_dir}`.",
        "",
        "The paired estimate is `exp(median(ln(candidate / baseline))) - 1`; lower is faster. Baseline spread is the first-ten central-80% radius, and tolerance is `max(5%, spread)`. No raw sample is discarded.",
        "",
        "## Run controls",
        "",
        "```json",
        json.dumps(manifest.get("controls", {}), indent=2, sort_keys=True),
        "```",
        "",
        "## Results",
        "",
        "| Target | Key | Pairs | Baseline raw (µs) | Candidate raw (µs) | Baseline spread | Tolerance | Paired delta (10) | Block A | Block B | Pooled delta (15) | Unpaired delta (diagnostic) | Result |",
        "| --- | --- | ---: | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |",
    ]
    for target in TARGETS:
        for key, *_ in SCENARIOS:
            if (target, key) not in results:
                continue
            result = results[(target, key)]
            lines.append(
                f"| {target} | {key} | {result['pair_count']} | "
                f"{', '.join(number(v) for v in result['baseline_raw_us'])} | "
                f"{', '.join(number(v) for v in result['candidate_raw_us'])} | "
                f"{result['baseline_spread'] * 100:.2f}% | {result['tolerance'] * 100:.2f}% | "
                f"{percent(result['paired_delta'])} | {percent(result['block_a_delta'])} ({result['block_a_status']}) | "
                f"{percent(result['block_b_delta'])} ({result['block_b_status']}) | {percent(result['pooled_delta'])} | "
                f"{percent(result['unpaired_delta'])} | **{result['result']}** |"
            )
    lines.extend(["", "## Provenance", "", "The runner records revision, `git diff HEAD --binary` SHA-256, staged status, untracked MoonBit source inventory, executable versions, the exact Moon `version --all` output (including feature flags), lock hashes, host/CPU/memory/frequency policy, timestamps, environment, elapsed time, and peak RSS in `run.json` and per-process metadata.", "", "Extension pairs are valid only for pairs 11–15 after exact target:key authorization from an INCONCLUSIVE first-ten result, and are classified using the pooled fifteen-pair estimate against the unchanged first-ten tolerance.", ""])
    return "\n".join(lines)


def read_manifest(input_dir: Path) -> dict[str, Any]:
    manifest_path = input_dir / "run.json"
    if not manifest_path.is_file():
        raise SummaryError(f"missing manifest: {manifest_path}")
    try:
        return json.loads(manifest_path.read_text())
    except json.JSONDecodeError as exc:
        raise SummaryError(f"malformed manifest: {exc}") from exc


def exact_selector(value: str) -> tuple[str, str]:
    pieces = value.split(":")
    if len(pieces) != 2 or not pieces[0] or not pieces[1]:
        raise SummaryError(f"extension authorization requires an exact target:key selector: {value!r}")
    target, key = pieces
    if target not in TARGETS:
        raise SummaryError(f"unknown target in extension selector: {target!r}")
    if key not in SCENARIO_BY_KEY:
        raise SummaryError(f"unknown selector in extension selector: {key!r}")
    return target, key


def authorize_extension(input_dir: Path, selector: str) -> dict[str, Any]:
    target, key = exact_selector(selector)
    manifest = read_manifest(input_dir)
    groups = load_samples(input_dir, manifest)
    values = groups.get((target, key))
    if values is None:
        raise SummaryError(f"extension selector {target}:{key} is not present in the initial inventory")
    result = classify(values, manifest["initial_pair_count"])
    if result["pair_count"] != 10 or result["result"] != "INCONCLUSIVE":
        raise SummaryError(
            f"extension authorization denied for {target}:{key}: "
            f"first-ten result is {result['result']}; it must be INCONCLUSIVE"
        )
    return result


def make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Parse Fugue projection paired raw logs and emit a deterministic Markdown gate report.")
    parser.add_argument("--input-dir", type=Path, required=True, help="runner output directory containing run.json and raw/")
    parser.add_argument("--output", type=Path, help="explicit Markdown report path (required unless authorizing an extension)")
    parser.add_argument("--authorize-extension", "--check-extension", dest="authorization_selector", metavar="TARGET:KEY", help="authorize pairs 11-15 only when this exact selector's first ten blocks disagree")
    return parser


def main() -> int:
    args = make_parser().parse_args()
    try:
        input_dir = args.input_dir.resolve()
        if args.authorization_selector is not None:
            if args.output is not None:
                raise SummaryError("--output cannot be combined with extension authorization")
            authorize_extension(input_dir, args.authorization_selector)
            print(f"extension authorized: {args.authorization_selector}")
            return 0
        if args.output is None:
            raise SummaryError("--output is required unless extension authorization is requested")
        manifest = read_manifest(input_dir)
        groups = load_samples(input_dir, manifest)
        results = {(target, key): classify(pairs, manifest["initial_pair_count"]) for (target, key), pairs in groups.items()}
        report = markdown(manifest, results, input_dir)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(report + "\n")
        failing = [(target, key, value["result"]) for (target, key), value in results.items() if value["result"] in ("FAIL", "INCONCLUSIVE")]
        print(f"wrote {args.output} ({len(results)} scenarios)")
        if failing:
            print("gate failed or is inconclusive: " + ", ".join(f"{target}:{key}={status}" for target, key, status in failing), file=sys.stderr)
            return 1
        return 0
    except (OSError, SummaryError, KeyError, TypeError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
