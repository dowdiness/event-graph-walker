#!/usr/bin/env python3
"""Run the frozen Fugue projection benchmark matrix as paired processes.

The runner deliberately does not interpret benchmark output.  It preserves raw
stdout/stderr and process metadata; summarize-fugue-projection-bench.py owns the
pure parsing and statistical decisions.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
import platform
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Iterable

from fugue_projection_bench_common import SCENARIOS, SCENARIO_BY_KEY, TARGETS

MANIFEST_NAME = "run.json"
# Only values that affect locale, time interpretation, hashing, or Moon's
# explicitly documented cache/workspace selection are persisted.  In
# particular, PATH/HOME and all credentials are intentionally excluded.
REPRODUCIBILITY_ENV_ALLOWLIST = (
    "CI",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "MOON_HOME",
    "MOON_MOD_CACHE",
    "MOON_WORKSPACE",
    "PYTHONHASHSEED",
    "SOURCE_DATE_EPOCH",
    "TZ",
)


class RunnerError(RuntimeError):
    pass


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def run_capture(args: list[str], cwd: Path, *, check: bool = False) -> subprocess.CompletedProcess[bytes]:
    result = subprocess.run(args, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if check and result.returncode != 0:
        raise RunnerError(f"command failed in {cwd}: {' '.join(args)}\n{result.stderr.decode(errors='replace')}")
    return result


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def git_output(worktree: Path, *args: str) -> str:
    result = run_capture(["git", *args], worktree, check=True)
    return result.stdout.decode("utf-8", errors="replace")


def inventory(worktree: Path) -> dict[str, str]:
    # Keep this command intentionally aligned with the provenance policy: it
    # inventories untracked MoonBit source and manifests, not benchmark logs.
    result = run_capture(
        [
            "git",
            "ls-files",
            "--others",
            "--exclude-standard",
            "-z",
            "--",
            "*.mbt",
            "*.mbti",
            "moon.pkg",
            "moon.mod",
            "moon.mod.json",
            "moon.work",
        ],
        worktree,
        check=True,
    )
    names = [name for name in result.stdout.decode(errors="surrogateescape").split("\0") if name]
    return {name: sha256_file(worktree / name) for name in sorted(names)}


def lock_hashes(worktree: Path) -> dict[str, str]:
    found: dict[str, str] = {}
    for name in (".moon-lock", "moon.lock", "moon.mod.json"):
        for path in worktree.rglob(name):
            if ".git" not in path.parts and path.is_file():
                found[str(path.relative_to(worktree))] = sha256_file(path)
    return dict(sorted(found.items()))


def resolve_executable(command: str) -> str | None:
    candidate = Path(command).expanduser()
    resolved = candidate if candidate.is_absolute() or candidate.parent != Path(".") else Path(shutil.which(command) or "")
    if not resolved or not resolved.is_file():
        return None
    return str(resolved.resolve())


def executable_version(executable: str | None) -> str:
    if executable is None:
        return "unavailable"
    result = subprocess.run([executable, "--version"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
    return result.stdout.decode("utf-8", errors="replace").strip() or f"exit {result.returncode}"


def moon_version_all(executable: str) -> dict[str, Any]:
    command = [executable, "version", "--all"]
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
    return {
        "command": command,
        "output": result.stdout.decode("utf-8", errors="replace"),
        "returncode": result.returncode,
    }


def resolve_moon_executable(command: str) -> str:
    executable = resolve_executable(command)
    if executable is None:
        raise RunnerError(f"cannot resolve --moon executable: {command!r}")
    return executable


def toolchain_snapshot(moon_executable: str) -> dict[str, Any]:
    tools = {"moon": moon_executable}
    moon_directory = Path(moon_executable).parent
    for name in ("moonc", "moonrun"):
        sibling = moon_directory / name
        resolved = str(sibling.resolve()) if sibling.is_file() else resolve_executable(name)
        if resolved is not None:
            tools[name] = resolved
    snapshot: dict[str, Any] = {
        name: {"executable": executable, "version": executable_version(executable)}
        for name, executable in sorted(tools.items())
    }
    snapshot["moon_version_all"] = moon_version_all(moon_executable)
    return snapshot


def frequency_policy() -> dict[str, Any]:
    governors = sorted(str(path) for path in Path("/sys/devices/system/cpu").glob("cpu*/cpufreq/scaling_governor") if path.exists())
    values: dict[str, str] = {}
    for raw_path in governors:
        path = Path(raw_path)
        try:
            values[str(path)] = path.read_text().strip()
        except OSError as exc:
            values[str(path)] = f"unreadable: {exc}"
    return {"governor_files": values, "policy": sorted(set(values.values())) if values else "unavailable"}


def memory_info() -> dict[str, str]:
    result: dict[str, str] = {}
    meminfo = Path("/proc/meminfo")
    if meminfo.exists():
        for line in meminfo.read_text(errors="replace").splitlines():
            if line.startswith(("MemTotal:", "MemAvailable:")):
                key, value = line.split(":", 1)
                result[key] = value.strip()
    return result or {"policy": "unavailable"}


def cpu_info() -> dict[str, Any]:
    model = "unavailable"
    cpuinfo = Path("/proc/cpuinfo")
    if cpuinfo.exists():
        for line in cpuinfo.read_text(errors="replace").splitlines():
            if line.lower().startswith(("model name", "hardware", "processor")) and ":" in line:
                model = line.split(":", 1)[1].strip()
                if "model name" in line.lower() or "hardware" in line.lower():
                    break
    allowed = sorted(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else None
    return {"model": model, "logical_cpus": os.cpu_count(), "allowed_cpus": allowed}


def environment_snapshot(environment: dict[str, str] | None = None) -> dict[str, Any]:
    source = os.environ if environment is None else environment
    variables = {key: source[key] for key in REPRODUCIBILITY_ENV_ALLOWLIST if key in source}
    return {
        "allowlist": list(REPRODUCIBILITY_ENV_ALLOWLIST),
        "variables": variables,
    }


def provenance(worktree: Path, moon_executable: str) -> dict[str, Any]:
    diff = subprocess.run(["git", "diff", "HEAD", "--binary"], cwd=worktree, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if diff.returncode != 0:
        raise RunnerError(f"cannot capture git diff in {worktree}: {diff.stderr.decode(errors='replace')}")
    return {
        "captured_at_utc": utc_now(),
        "worktree": str(worktree),
        "revision": git_output(worktree, "rev-parse", "HEAD").strip(),
        "git_diff_HEAD_binary_sha256": sha256_bytes(diff.stdout),
        "staged_status": git_output(worktree, "diff", "--cached", "--name-status"),
        "untracked_moonbit_source_inventory": inventory(worktree),
        "toolchain": toolchain_snapshot(moon_executable),
        "lock_sha256": lock_hashes(worktree),
        "host": platform.uname()._asdict(),
        "cpu": cpu_info(),
        "memory": memory_info(),
        "frequency_policy": frequency_policy(),
        "local_time": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        "utc_time": utc_now(),
    }


def provenance_fingerprint(value: dict[str, Any]) -> tuple[Any, ...]:
    return (
        value["revision"],
        value["git_diff_HEAD_binary_sha256"],
        value["staged_status"],
        tuple(sorted(value["untracked_moonbit_source_inventory"].items())),
        tuple(sorted(value["lock_sha256"].items())),
        json.dumps(value["toolchain"], sort_keys=True),
    )


def assert_provenance_unchanged(worktrees: dict[str, Path], original: dict[str, Any], moon_executable: str) -> dict[str, Any]:
    current = {role: provenance(worktree, moon_executable) for role, worktree in worktrees.items()}
    for role in ("baseline", "candidate"):
        if provenance_fingerprint(current[role]) != provenance_fingerprint(original[role]):
            raise RunnerError(f"{role} worktree provenance changed during the run")
    return current


def parse_cpu_affinity(value: str | None) -> list[int] | None:
    if value is None:
        return None
    cpus: set[int] = set()
    for item in value.split(","):
        item = item.strip()
        if not item:
            raise RunnerError("--cpu-affinity contains an empty item")
        if "-" in item:
            pieces = item.split("-")
            if len(pieces) != 2 or not all(piece.isdigit() for piece in pieces):
                raise RunnerError(f"invalid CPU affinity range: {item}")
            start, end = map(int, pieces)
            if end < start:
                raise RunnerError(f"invalid descending CPU affinity range: {item}")
            cpus.update(range(start, end + 1))
        elif item.isdigit():
            cpus.add(int(item))
        else:
            raise RunnerError(f"invalid CPU affinity value: {item}")
    if not cpus:
        raise RunnerError("--cpu-affinity selected no CPUs")
    if hasattr(os, "sched_getaffinity"):
        allowed = os.sched_getaffinity(0)
        unavailable = sorted(cpus - allowed)
        if unavailable:
            raise RunnerError(f"requested CPUs are not available to this process: {unavailable}")
    else:
        raise RunnerError("this Python platform cannot honor --cpu-affinity")
    return sorted(cpus)


def load_average() -> float:
    if not hasattr(os, "getloadavg"):
        raise RunnerError("this platform cannot honor load-average controls")
    return float(os.getloadavg()[0])


def wait_for_load(maximum: float | None, timeout: float, poll: float) -> float:
    if maximum is None:
        return 0.0
    started = time.monotonic()
    while True:
        current = load_average()
        if current <= maximum:
            return time.monotonic() - started
        if time.monotonic() - started >= timeout:
            raise RunnerError(f"load average {current:.3f} stayed above {maximum:.3f} for {timeout:.1f}s")
        time.sleep(poll)


def parse_pair_range(value: str) -> tuple[int, int]:
    match = re.fullmatch(r"(\d+)[-:](\d+)", value.strip())
    if not match:
        raise argparse.ArgumentTypeError("pair range must be START-END, for example 11-15")
    start, end = map(int, match.groups())
    if start < 1 or end < start:
        raise argparse.ArgumentTypeError("pair range must satisfy 1 <= START <= END")
    return start, end


def selector_token(value: str) -> tuple[str | None, str]:
    if ":" in value:
        target, key = value.split(":", 1)
        if target not in TARGETS:
            raise RunnerError(f"unknown target in selector {value!r}; use js or wasm-gc")
    else:
        target, key = None, value
    if key not in SCENARIO_BY_KEY:
        raise RunnerError(f"unknown selector {key!r}; expected one of {', '.join(SCENARIO_BY_KEY)}")
    return target, key


def selected_scenarios(targets: Iterable[str], selectors: list[str] | None) -> list[tuple[str, tuple[str, str, str, str, str]]]:
    target_list = list(targets)
    allowed: dict[str, set[str] | None] = {target: None for target in target_list}
    if selectors:
        allowed = {target: set() for target in target_list}
        unrestricted: set[str] = set()
        for raw in selectors:
            target, key = selector_token(raw)
            if target is not None:
                if target not in target_list:
                    raise RunnerError(f"selector {raw!r} names target {target}, which is not in --target")
                allowed[target].add(key)  # type: ignore[union-attr]
            else:
                unrestricted.add(key)
        for target in target_list:
            allowed[target].update(unrestricted)  # type: ignore[union-attr]
    return [(target, SCENARIO_BY_KEY[key]) for target in target_list for key, *_ in SCENARIOS if allowed[target] is None or key in allowed[target]]


def sample_paths(output_dir: Path, target: str, key: str, pair: int, role: str) -> dict[str, Path]:
    directory = output_dir / "raw" / target / key
    stem = f"pair-{pair:03d}-{role}"
    return {"stdout": directory / f"{stem}.stdout", "stderr": directory / f"{stem}.stderr", "time": directory / f"{stem}.time", "meta": directory / f"{stem}.meta.json"}


def parse_time_file(path: Path) -> tuple[float, int]:
    content = path.read_text(errors="replace")
    lines = [line for line in content.splitlines() if line]
    elapsed_matches = re.findall(r"^elapsed_s=([0-9.eE+-]+)$", content, re.MULTILINE)
    rss_matches = re.findall(r"^max_rss_kb=(\d+)$", content, re.MULTILINE)
    if len(lines) != 2 or len(elapsed_matches) != 1 or len(rss_matches) != 1:
        raise RunnerError(f"time command did not emit exactly one elapsed/RSS record: {path}")
    try:
        elapsed = float(elapsed_matches[0])
        rss = int(rss_matches[0])
    except ValueError as exc:
        raise RunnerError(f"invalid elapsed/RSS metadata in {path}") from exc
    if not math.isfinite(elapsed) or elapsed < 0:
        raise RunnerError(f"invalid elapsed time in {path}")
    return elapsed, rss


def atomic_json(path: Path, value: Any) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def controls(args: argparse.Namespace, affinity: list[int] | None, moon_executable: str | None = None) -> dict[str, Any]:
    return {
        "cpu_affinity_requested": args.cpu_affinity,
        "cpu_affinity_applied": affinity,
        "load_average_max_1m": args.load_average_max,
        "load_average_timeout_seconds": args.load_average_timeout,
        "load_average_poll_seconds": args.load_average_poll,
        "cooldown_seconds_between_processes": args.cooldown_seconds,
        "outlier_deletion": "none; every raw sample is retained",
        "process_order": "baseline first for odd pair numbers; candidate first for even pair numbers",
        "processes": "sequential",
        "moon_executable": moon_executable or args.moon,
    }


def add_initial_run_arguments(parser: argparse.ArgumentParser) -> argparse.ArgumentParser:
    """Add the worktree, matrix-selection, and noise-control arguments."""
    parser.add_argument("--baseline-worktree", type=Path, required=True, help="baseline Event Graph Walker worktree")
    parser.add_argument("--candidate-worktree", type=Path, required=True, help="candidate Event Graph Walker worktree")
    parser.add_argument("--output-dir", type=Path, required=True, help="directory for run.json, provenance, and raw logs (always explicitly supplied)")
    parser.add_argument("--target", choices=TARGETS, action="append", dest="targets", help="target to run; repeatable (default: js and wasm-gc)")
    parser.add_argument("--selector", action="append", help="initial selector key, or target:key; repeatable (default: all frozen selectors)")
    parser.add_argument("--cpu-affinity", help="optional CPUs for every child, e.g. 2 or 2-3; fail if unavailable")
    parser.add_argument("--load-average-max", type=float, help="optional maximum 1-minute load average before each process")
    parser.add_argument("--load-average-timeout", type=float, default=300.0, help="load wait timeout in seconds (default: 300)")
    parser.add_argument("--load-average-poll", type=float, default=1.0, help="load wait polling interval in seconds (default: 1)")
    parser.add_argument("--cooldown-seconds", type=float, default=0.0, help="sleep between sequential processes (default: 0)")
    parser.add_argument("--moon", default="moon", help="Moon executable (default: moon)")
    return parser


def make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run the frozen B1-B5/D1-D12 Fugue projection matrix as alternating baseline/candidate processes. Raw logs are never deleted."
    )
    add_initial_run_arguments(parser)
    parser.add_argument("--extension-selector", "--extend-selector", "--extend", action="append", help="append pairs for target:key (or key for all selected targets); repeatable")
    parser.add_argument("--pair-count", type=int, default=10, help="initial number of pairs (default: 10)")
    parser.add_argument("--pair-range", type=parse_pair_range, help="extension pair range; extensions require exactly 11-15")
    parser.add_argument("--dry-run", action="store_true", help="validate and print the planned commands without running them or writing logs")
    return parser


def expected_entries(scenarios: list[tuple[str, tuple[str, str, str, str, str]]], pair_range: tuple[int, int], extension: bool) -> list[dict[str, Any]]:
    start, end = pair_range
    entries: list[dict[str, Any]] = []
    for target, row in scenarios:
        key, package, file_name, index, name = row
        for pair in range(start, end + 1):
            for role in ("baseline", "candidate"):
                paths = sample_paths(Path("."), target, key, pair, role)
                entries.append({"target": target, "key": key, "name": name, "pair": pair, "role": role, "extension": extension, "relative_stdout": str(paths["stdout"].relative_to(".")), "relative_stderr": str(paths["stderr"].relative_to(".")), "relative_time": str(paths["time"].relative_to(".")), "relative_meta": str(paths["meta"].relative_to("."))})
    return entries


def command_for(moon: str, row: tuple[str, str, str, str, str], target: str) -> list[str]:
    _, package, file_name, index, _ = row
    return [moon, "bench", "--release", "--target", target, "--package", package, "--file", file_name, "--index", index]


def parse_existing_manifest(output_dir: Path) -> dict[str, Any]:
    path = output_dir / MANIFEST_NAME
    if not path.is_file():
        raise RunnerError(f"extension run requires existing {path}")
    try:
        value = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        raise RunnerError(f"invalid existing manifest {path}: {exc}") from exc
    if value.get("schema") != "fugue-projection-paired-bench-v1":
        raise RunnerError(f"unsupported manifest schema in {path}")
    return value


def sample_identity(item: dict[str, Any]) -> tuple[str, str, int, str]:
    try:
        return (str(item["target"]), str(item["key"]), int(item["pair"]), str(item["role"]))
    except (KeyError, TypeError, ValueError) as exc:
        raise RunnerError(f"malformed sample inventory entry: {item!r}") from exc


def require_complete_initial_inventory(manifest: dict[str, Any], target: str, key: str) -> None:
    required = {(target, key, pair, role) for pair in range(1, 11) for role in ("baseline", "candidate")}
    expected_items = manifest.get("expected_samples", [])
    completed_items = manifest.get("completed_samples", [])
    expected = {sample_identity(item) for item in expected_items}
    completed = {sample_identity(item) for item in completed_items}
    if len(expected) != len(expected_items) or len(completed) != len(completed_items):
        raise RunnerError(f"extension selector {target}:{key} has duplicate expected or completed samples")
    if not required <= expected or not required <= completed:
        raise RunnerError(f"extension selector {target}:{key} lacks complete expected and completed initial pairs 1-10")


def authorize_extension(output_dir: Path, target: str, key: str) -> None:
    summarizer = Path(__file__).with_name("summarize-fugue-projection-bench.py")
    result = run_capture(
        [
            sys.executable,
            str(summarizer),
            "--input-dir",
            str(output_dir),
            "--authorize-extension",
            f"{target}:{key}",
        ],
        output_dir,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise RunnerError(
            f"extension authorization denied for {target}:{key}"
            + (f": {detail}" if detail else "")
        )


def original_pre_provenance(manifest: dict[str, Any]) -> dict[str, Any]:
    try:
        initial = manifest["invocations"][0]
        provenance_value = initial["provenance_pre"]
        if set(provenance_value) != {"baseline", "candidate"}:
            raise KeyError("baseline/candidate")
        return provenance_value
    except (KeyError, IndexError, TypeError) as exc:
        raise RunnerError("manifest lacks the original initial pre-run provenance") from exc


def run(args: argparse.Namespace) -> int:
    if args.pair_count != 10:
        raise RunnerError("--pair-count must be exactly 10")
    if args.load_average_max is not None and (args.load_average_max < 0 or args.load_average_timeout < 0 or args.load_average_poll <= 0):
        raise RunnerError("load-average maximum must be nonnegative, timeout nonnegative, and poll positive")
    if args.cooldown_seconds < 0:
        raise RunnerError("--cooldown-seconds must be nonnegative")
    baseline = args.baseline_worktree.resolve()
    candidate = args.candidate_worktree.resolve()
    output_dir = args.output_dir.resolve()
    if not baseline.is_dir() or not candidate.is_dir():
        raise RunnerError("both worktree arguments must be existing directories")
    if baseline == candidate:
        raise RunnerError("baseline and candidate worktrees must be distinct")
    targets = args.targets or list(TARGETS)
    extension = bool(args.extension_selector)
    if extension:
        manifest = parse_existing_manifest(output_dir)
        if manifest.get("initial_pair_count") != 10:
            raise RunnerError("extension runs require manifest initial_pair_count == 10")
        if args.selector or args.pair_count != manifest["initial_pair_count"]:
            raise RunnerError("extension runs cannot change --selector or --pair-count")
        if str(baseline) != manifest.get("baseline_worktree") or str(candidate) != manifest.get("candidate_worktree"):
            raise RunnerError("extension worktrees differ from the original run")
        if targets != manifest.get("targets"):
            raise RunnerError("extension targets must match the original run")
        extension_start, extension_end = args.pair_range or (11, 15)
        if (extension_start, extension_end) != (11, 15):
            raise RunnerError("extension pair range must be exactly 11-15")
        extension_scenarios: list[tuple[str, tuple[str, str, str, str, str]]] = []
        for raw in args.extension_selector:
            requested_target, key = selector_token(raw)
            if requested_target is None:
                raise RunnerError(f"extension selector must name an exact target:key: {raw!r}")
            if requested_target not in targets:
                raise RunnerError(f"selector {raw!r} names target {requested_target}, which is not in --target")
            require_complete_initial_inventory(manifest, requested_target, key)
            authorize_extension(output_dir, requested_target, key)
            item = (requested_target, SCENARIO_BY_KEY[key])
            if item not in extension_scenarios:
                extension_scenarios.append(item)

    moon_executable = resolve_moon_executable(args.moon)
    affinity = parse_cpu_affinity(args.cpu_affinity)
    if affinity is not None:
        try:
            original_affinity = os.sched_getaffinity(0)
            os.sched_setaffinity(0, set(affinity))
            os.sched_setaffinity(0, original_affinity)
        except OSError as exc:
            raise RunnerError(f"cannot honor --cpu-affinity {args.cpu_affinity!r}: {exc}") from exc
    if extension:
        if controls(args, affinity, moon_executable) != manifest.get("controls"):
            raise RunnerError("extension noise controls must exactly match the original run")
        original_pre = original_pre_provenance(manifest)
        pre = {"baseline": provenance(baseline, moon_executable), "candidate": provenance(candidate, moon_executable)}
        for role in ("baseline", "candidate"):
            if provenance_fingerprint(pre[role]) != provenance_fingerprint(original_pre[role]):
                raise RunnerError(f"{role} worktree provenance differs from the original initial provenance")
        initial_pairs = {sample_identity(item) for item in manifest.get("expected_samples", [])}
        additions = expected_entries(extension_scenarios, (extension_start, extension_end), True)
        for item in additions:
            identity = sample_identity(item)
            if identity in initial_pairs:
                raise RunnerError(f"sample already expected: {identity}")
        manifest["expected_samples"].extend(additions)
        manifest["invocations"].append({"kind": "extension", "captured_at_utc": utc_now(), "selectors": args.extension_selector, "pair_range": [extension_start, extension_end], "provenance_pre": pre})
        scenarios = extension_scenarios
        pair_range = (extension_start, extension_end)
        is_extension = True
    else:
        if output_dir.exists() and any(output_dir.iterdir()):
            raise RunnerError(f"initial run requires an empty or nonexistent output directory: {output_dir}")
        scenarios = selected_scenarios(targets, args.selector)
        pair_range = (1, args.pair_count)
        pre = {"baseline": provenance(baseline, moon_executable), "candidate": provenance(candidate, moon_executable)}
        manifest = {
            "schema": "fugue-projection-paired-bench-v1",
            "created_at_utc": utc_now(),
            "baseline_worktree": str(baseline),
            "candidate_worktree": str(candidate),
            "targets": targets,
            "selector_keys": [row[0] for row in SCENARIOS if any(item[1][0] == row[0] for item in scenarios)],
            "initial_pair_count": args.pair_count,
            "selector_map": [{"key": key, "package": package, "file": file_name, "index": index, "name": name} for key, package, file_name, index, name in SCENARIOS],
            "controls": controls(args, affinity, moon_executable),
            "environment": environment_snapshot(),
            "expected_samples": expected_entries(scenarios, pair_range, False),
            "completed_samples": [],
            "invocations": [{"kind": "initial", "captured_at_utc": utc_now(), "pair_range": [1, args.pair_count], "provenance_pre": pre}],
        }
        is_extension = False
        original_pre = pre
    if not scenarios:
        raise RunnerError("no scenarios selected")
    # The time utility is required for per-process elapsed time and peak RSS.
    time_command = "/usr/bin/time" if Path("/usr/bin/time").is_file() else shutil.which("time")
    if not time_command:
        raise RunnerError("GNU time is required to record per-process elapsed time and RSS")
    if args.dry_run:
        preview: list[dict[str, Any]] = []
        for target, row in scenarios:
            for pair in range(pair_range[0], pair_range[1] + 1):
                order = ["baseline", "candidate"] if pair % 2 else ["candidate", "baseline"]
                preview.append({"target": target, "key": row[0], "pair": pair, "order": order, "baseline": command_for(moon_executable, row, target), "candidate": command_for(moon_executable, row, target)})
        print(json.dumps({"output_dir": str(output_dir), "pair_range": list(pair_range), "extension": is_extension, "controls": manifest["controls"], "commands": preview}, indent=2))
        for target, row in scenarios:
            for pair in range(pair_range[0], pair_range[1] + 1):
                order = ("baseline", "candidate") if pair % 2 else ("candidate", "baseline")
                print(f"pair={pair} target={target} key={row[0]} order={' then '.join(order)}")
                for role in order:
                    print(f"  {role}: cwd={(baseline if role == 'baseline' else candidate)} command={' '.join(command_for(moon_executable, row, target))}")
        return 0
    output_dir.mkdir(parents=True, exist_ok=True)
    atomic_json(output_dir / MANIFEST_NAME, manifest)
    try:
        for target, row in scenarios:
            key = row[0]
            for pair in range(pair_range[0], pair_range[1] + 1):
                order = ("baseline", "candidate") if pair % 2 else ("candidate", "baseline")
                for role in order:
                    if args.cooldown_seconds:
                        time.sleep(args.cooldown_seconds)
                    waited = wait_for_load(args.load_average_max, args.load_average_timeout, args.load_average_poll)
                    worktree = baseline if role == "baseline" else candidate
                    paths = sample_paths(output_dir, target, key, pair, role)
                    for path in paths.values():
                        path.parent.mkdir(parents=True, exist_ok=True)
                    command = command_for(moon_executable, row, target)
                    started = utc_now()
                    start_clock = time.monotonic()
                    time_command_path = paths["time"]
                    wrapped = [time_command, "-f", "elapsed_s=%e\\nmax_rss_kb=%M", "-o", str(time_command_path), *command]
                    kwargs: dict[str, Any] = {"cwd": worktree, "stdout": subprocess.PIPE, "stderr": subprocess.PIPE, "check": False}
                    if affinity is not None:
                        kwargs["preexec_fn"] = lambda: os.sched_setaffinity(0, set(affinity))  # type: ignore[attr-defined]
                    result = subprocess.run(wrapped, **kwargs)
                    elapsed_wall = time.monotonic() - start_clock
                    paths["stdout"].write_bytes(result.stdout)
                    paths["stderr"].write_bytes(result.stderr)
                    elapsed_s, max_rss_kb = parse_time_file(time_command_path)
                    assert_provenance_unchanged({"baseline": baseline, "candidate": candidate}, original_pre, moon_executable)
                    metadata = {
                        "target": target, "key": key, "name": row[4], "pair": pair, "role": role,
                        "order": list(order), "worktree": str(worktree), "command": command,
                        "started_at_utc": started, "finished_at_utc": utc_now(), "returncode": result.returncode,
                        "elapsed_s": elapsed_s, "wall_elapsed_s": elapsed_wall, "max_rss_kb": max_rss_kb,
                        "load_average_wait_seconds": waited, "cpu_affinity": affinity,
                        "relative_stdout": str(paths["stdout"].relative_to(output_dir)),
                        "relative_stderr": str(paths["stderr"].relative_to(output_dir)),
                        "relative_time": str(paths["time"].relative_to(output_dir)),
                    }
                    paths["meta"].write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
                    manifest["completed_samples"].append(metadata)
                    atomic_json(output_dir / MANIFEST_NAME, manifest)
                    if result.returncode != 0:
                        raise RunnerError(f"benchmark failed ({result.returncode}): target={target} selector={key} pair={pair} role={role}; raw logs retained in {paths['stdout'].parent}")
        post = assert_provenance_unchanged({"baseline": baseline, "candidate": candidate}, original_pre, moon_executable)
        manifest["post_run_provenance"] = post
        atomic_json(output_dir / MANIFEST_NAME, manifest)
    except Exception:
        atomic_json(output_dir / MANIFEST_NAME, manifest)
        raise
    print(f"completed {len(scenarios) * (pair_range[1] - pair_range[0] + 1)} scenarios/pairs in {output_dir}")
    return 0


def main() -> int:
    parser = make_parser()
    args = parser.parse_args()
    try:
        return run(args)
    except (RunnerError, OSError, subprocess.SubprocessError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("interrupted; existing raw logs and run.json were retained", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
