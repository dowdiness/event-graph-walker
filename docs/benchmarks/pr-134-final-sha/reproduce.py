#!/usr/bin/env python3
"""Rebuild/run the unchanged measured harness outside the repository.

Only Python's standard library plus Git, the pinned MoonBit toolchain and Node
are required. Source/dependency downloads use their normal public tooling.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile

HERE = Path(__file__).resolve().parent
REPOSITORY = "https://github.com/dowdiness/event-graph-walker.git"
MODULES = ["dowdiness-alga", "dowdiness-btree", "dowdiness-order-tree", "dowdiness-rle", "moonbitlang-quickcheck", "moonbitlang-x"]


def run(*args, cwd=None, capture=False):
    return subprocess.run(args, cwd=cwd, check=True, text=True, capture_output=capture)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", type=Path, required=True, help="New/empty directory outside the EGW checkout")
    parser.add_argument("--source-repo", type=Path, help="Optional local Git clone containing both pinned commits (offline source reuse)")
    parser.add_argument("--dependency-cache", type=Path, help="Optional existing .mooncakes directory; every used file is hash-checked")
    parser.add_argument("--build-only", action="store_true", help="Verify/rebuild both binaries without repeating all timings")
    args = parser.parse_args()
    work = args.work_dir.resolve()
    repo_root = HERE.parents[2]
    if work == repo_root or repo_root in work.parents:
        parser.error("--work-dir must be outside the repository; generated MoonBit packages must not enter its package scan")
    if work.exists() and any(work.iterdir()):
        parser.error("--work-dir must be new or empty; old build outputs are not reused")
    work.mkdir(parents=True, exist_ok=True)
    (work / "logs").mkdir()
    os.environ["NEW_MOON_MOD"] = "0"
    os.environ.setdefault("MOON_HOME", str(Path.home() / ".moon"))
    lock = json.loads((HERE / "harness/lock.json").read_text())
    recorded = json.loads((HERE / "raw/benchmark.json").read_text())
    assert run("node", "-v", capture=True).stdout.strip() == lock["node"], "Use Node 24.19.0"
    assert lock["compiler"] in run("moonc", "-v", capture=True).stdout, "Use the pinned compiler"
    assert lock["moon"] in run("moon", "version", capture=True).stdout, "Use the pinned Moon CLI"
    core = Path(os.environ["MOON_HOME"]) / "lib/core/moon.mod"
    assert f'version = "{lock["compiler"]}"' in core.read_text(), "Use the matching pinned core"
    assert digest(HERE / "harness/bench.mjs") == recorded["hashes"]["harnessSha256"]
    assert digest(HERE / "harness/config.json") == recorded["hashes"]["configSha256"]
    assert digest(HERE / "harness/lock.json") == recorded["hashes"]["lockSha256"]
    repo = args.source_repo.resolve() if args.source_repo else work / "repository"
    if not args.source_repo:
        run("git", "clone", "--no-checkout", REPOSITORY, str(repo))
    (work / "source").mkdir()
    for lane, source in lock["sources"].items():
        # A moved branch/PR merge ref cannot change either measured source tree.
        actual = run("git", "-C", str(repo), "rev-parse", source["commit"] + "^{tree}", capture=True).stdout.strip()
        assert actual == source["tree"], (lane, "source commit/tree mismatch")
        destination = work / "source" / lane
        destination.mkdir()
        archive = work / "source" / f"{lane}.tar"
        with archive.open("wb") as out:
            subprocess.run(["git", "-C", str(repo), "archive", source["commit"]], stdout=out, check=True)
        with tarfile.open(archive) as data:
            data.extractall(destination, filter="data")
        archive.unlink()
    cache = args.dependency_cache.resolve() if args.dependency_cache else work / "source/base/.mooncakes"
    if not args.dependency_cache:
        run("moon", "update", cwd=work / "source/base")
        # moon update refreshes the registry; build resolves/installs module files.
        with (work / "logs/dependency-prepare.log").open("w") as log:
            subprocess.run(["moon", "build", "--target", "js", "--release"], cwd=work / "source/base", stdout=log, stderr=subprocess.STDOUT, check=True)
    vendor = work / "vendor"
    vendor.mkdir()
    for module in MODULES:
        namespace, name = module.split("-", 1)
        shutil.copytree(cache / namespace / name, vendor / module)
    assert digest(HERE / "provenance/vendor-manifest.json") == lock["vendorManifestSha256"], "Dependency manifest differs from measured lock"
    expected = json.loads((HERE / "provenance/vendor-manifest.json").read_text())["files"]
    actual = {str(p.relative_to(vendor)): digest(p) for p in vendor.rglob("*") if p.is_file()}
    assert actual == expected, "Dependency files differ from measured sources; do not silently use another version"
    (work / "scripts").mkdir()
    (work / "artifacts").mkdir()
    (work / "results").mkdir()
    shutil.copyfile(HERE / "harness/bench.mjs", work / "scripts/bench.mjs")
    for name in ["config.json", "lock.json"]:
        shutil.copyfile(HERE / "harness" / name, work / name)
    (work / "package.json").write_text('{"type":"module","private":true}\n')
    for lane in lock["sources"]:
        build = work / "build" / lane
        (build / "bridge").mkdir(parents=True)
        for name in ["main.mbt", "moon.pkg"]:
            target = build / "bridge" / name
            shutil.copyfile(HERE / "bridge" / (name + ".template"), target)
            assert digest(target) == lock["bridge"]["bridge/" + name], "Bridge differs from measured bridge"
        (build / "moon.mod").write_text('name = "experiment/pr134_evidence"\nversion = "0.0.1"\nimport { "dowdiness/event-graph-walker@0.8.0" }\npreferred_target = "js"\n')
        members = [".", "../../source/" + lane] + ["../../vendor/" + name for name in MODULES]
        (build / "moon.work").write_text("members = " + json.dumps(members) + "\n")
        with (work / "logs" / f"build-{lane}.log").open("w") as log:
            subprocess.run(["moon", "build", "--target", "js", "--release", "bridge"], cwd=build, stdout=log, stderr=subprocess.STDOUT, check=True)
        artifact = work / "artifacts" / f"{lane}.js"
        shutil.copyfile(build / "_build/js/release/build/experiment/pr134_evidence/bridge/bridge.js", artifact)
        assert digest(artifact) == recorded["hashes"][lane + "BinarySha256"], "Rebuilt binary differs; inspect compiler/core/dependencies before comparing numbers"
        print(lane, lock["sources"][lane]["commit"], digest(artifact), flush=True)
    if not args.build_only:
        run("node", "scripts/bench.mjs", cwd=work)
    print("Verified exact source trees, immutable harness/bridge/dependencies, and byte-identical release JS", flush=True)


if __name__ == "__main__":
    main()
