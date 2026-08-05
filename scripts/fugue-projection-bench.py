#!/usr/bin/env python3
"""Run the Fugue projection benchmark gate in one command.

The runner owns process execution and provenance.  The summarizer owns parsing,
statistics, inventory validation, and classification.  This module only
coordinates those capabilities and makes the pure extension decision.
"""
from __future__ import annotations

import argparse
import importlib.util
import sys
from pathlib import Path
from typing import Any, Callable, Mapping

from fugue_projection_bench_common import SCENARIO_BY_KEY, TARGETS


def _load_script(name: str, filename: str) -> Any:
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {filename}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


runner = _load_script("fugue_gate_runner", "run-fugue-projection-bench.py")
summarizer = _load_script("fugue_gate_summarizer", "summarize-fugue-projection-bench.py")


class GateDecision:
    def __init__(
        self,
        action: str,
        exit_code: int | None,
        extension_selectors: tuple[str, ...] = (),
        error: str | None = None,
    ) -> None:
        self.action = action
        self.exit_code = exit_code
        self.extension_selectors = extension_selectors
        self.error = error


class GateCapabilities:
    """Injected shell capabilities used by ``run_gate``."""

    def __init__(
        self,
        run_runner: Callable[[argparse.Namespace], int],
        summarize: Callable[[Path], tuple[dict[str, str], str]],
    ) -> None:
        self.run_runner = run_runner
        self.summarize = summarize


def decide_gate(results: Mapping[str, str], *, after_extension: bool = False) -> GateDecision:
    """Return the complete gate decision matrix for exact selector statuses."""
    if not results:
        return GateDecision("error", 2, error="summary contains no results")
    statuses: list[str] = []
    inconclusive: list[str] = []
    for selector, status in results.items():
        if not isinstance(selector, str) or selector.count(":") != 1:
            return GateDecision("error", 2, error=f"malformed selector: {selector!r}")
        target, key = selector.split(":")
        if target not in TARGETS or key not in SCENARIO_BY_KEY:
            return GateDecision("error", 2, error=f"unknown selector: {selector!r}")
        if not isinstance(status, str) or status not in {"PASS", "FAIL", "INCONCLUSIVE"}:
            return GateDecision("error", 2, error=f"unknown status for {selector}: {status!r}")
        statuses.append(status)
        if status == "INCONCLUSIVE":
            inconclusive.append(selector)
    if after_extension:
        return GateDecision("finish", 0 if all(status == "PASS" for status in statuses) else 1)
    if "FAIL" in statuses:
        return GateDecision("finish", 1)
    if inconclusive:
        return GateDecision("extend", None, tuple(sorted(inconclusive)))
    return GateDecision("finish", 0)


def summarize_gate(input_dir: Path) -> tuple[dict[str, str], str]:
    """Load and classify a valid run, returning statuses and its Markdown."""
    manifest = summarizer.read_manifest(input_dir)
    groups = summarizer.load_samples(input_dir, manifest)
    detailed = {
        (target, key): summarizer.classify(pairs, manifest["initial_pair_count"])
        for (target, key), pairs in groups.items()
    }
    statuses = {f"{target}:{key}": value["result"] for (target, key), value in detailed.items()}
    return statuses, summarizer.markdown(manifest, detailed, input_dir)


def make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run the Fugue projection benchmark gate.")
    commands = parser.add_subparsers(dest="command", required=True)
    gate_parser = commands.add_parser("gate", help="run ten pairs, then extend only exact inconclusive selectors")
    runner.add_initial_run_arguments(gate_parser)
    return parser


def _runner_args(args: argparse.Namespace, extension_selectors: list[str] | None = None) -> argparse.Namespace:
    return argparse.Namespace(
        baseline_worktree=args.baseline_worktree,
        candidate_worktree=args.candidate_worktree,
        output_dir=args.output_dir,
        targets=args.targets,
        selector=args.selector if extension_selectors is None else None,
        extension_selector=extension_selectors,
        pair_count=10,
        pair_range=None if extension_selectors is None else (11, 15),
        cpu_affinity=args.cpu_affinity,
        load_average_max=args.load_average_max,
        load_average_timeout=args.load_average_timeout,
        load_average_poll=args.load_average_poll,
        cooldown_seconds=args.cooldown_seconds,
        moon=args.moon,
        dry_run=False,
    )


def _write_report(output: Path, report: str) -> None:
    temporary = output.with_suffix(output.suffix + ".tmp")
    try:
        temporary.write_text(report.rstrip("\n") + "\n")
        temporary.replace(output)
    except BaseException:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass
        raise


def _summarize_and_retain(
    args: argparse.Namespace,
    capabilities: GateCapabilities,
    *,
    after_extension: bool = False,
) -> dict[str, str]:
    statuses, report = capabilities.summarize(args.output_dir.resolve())
    decision = decide_gate(statuses, after_extension=after_extension)
    if decision.action == "error":
        raise RuntimeError(decision.error or "invalid gate summary")
    output = args.output_dir.resolve() / "summary.md"
    output.parent.mkdir(parents=True, exist_ok=True)
    _write_report(output, report)
    return statuses


def run_gate(args: argparse.Namespace, capabilities: GateCapabilities | Any | None = None) -> int:
    """Run the gate through injected runner/summarizer capabilities."""
    capabilities = capabilities or GateCapabilities(runner.run, summarize_gate)
    try:
        initial_code = capabilities.run_runner(_runner_args(args))
        if initial_code != 0:
            raise RuntimeError(f"initial benchmark runner exited with code {initial_code}")
        initial = _summarize_and_retain(args, capabilities)
        decision = decide_gate(initial)
        if decision.action == "error":
            return 2
        if decision.action == "finish":
            return decision.exit_code if decision.exit_code is not None else 2
        extension_code = capabilities.run_runner(_runner_args(args, list(decision.extension_selectors)))
        if extension_code != 0:
            raise RuntimeError(f"extension benchmark runner exited with code {extension_code}")
        final = _summarize_and_retain(args, capabilities, after_extension=True)
        final_decision = decide_gate(final, after_extension=True)
        return final_decision.exit_code if final_decision.action == "finish" else 2
    except KeyboardInterrupt:
        print("interrupted; existing raw logs, run.json, and the last valid summary were retained", file=sys.stderr)
        return 130
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


def main() -> int:
    args = make_parser().parse_args()
    return run_gate(args)


if __name__ == "__main__":
    raise SystemExit(main())
