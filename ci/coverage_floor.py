#!/usr/bin/env python3
"""The project's line coverage, from xccov's reports, held to a floor.

    python3 ci/coverage_floor.py --root "$PWD" --floor 26.0 app.json watch.json

Each report is `xcrun xccov view --report --json <bundle>.xcresult` (the full report,
with files). What counts is THIS REPOSITORY'S SHIPPED CODE: every source file under
--root in a target that is not a test bundle (`*.xctest`), so the app, its extensions,
the watch app and its complication. Not counted: test bundles, and files outside the
repository or under SourcePackages/ and DerivedData/ (DistrictCore, Sentry, LiveKit and
the rest are other projects, with their own suites; DistrictCore's is in
district-core-swift). Nothing else is excluded, generated sources included.

A file can appear in more than one report (the watch app's sources are compiled into the
iOS run's embedded watch app too). Per file the report with the most covered lines is
taken. That is never more than the true union of the runs, so the figure can only be an
underestimate.

Exits 1 below the floor, and also when the reports hold no counted file at all: an empty
or misread report is a lost signal, not a pass.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

NOT_OURS = ("SourcePackages/", "DerivedData/")


def die(message: str) -> None:
    print(f"FATAL - {message}")
    sys.exit(1)


def targets_of(report: object) -> list[dict]:
    """xccov's top level is an object with `targets`; `--only-targets` gives a bare list."""
    if isinstance(report, dict) and isinstance(report.get("targets"), list):
        return report["targets"]
    if isinstance(report, list):
        return report
    die("a report is neither an xccov object with `targets` nor a list of targets")
    return []


def counted_files(reports: list[object], root: str) -> dict[str, tuple[str, int, int]]:
    """path relative to root -> (target, covered, executable), best report per file."""
    prefix = root.rstrip("/") + "/"
    best: dict[str, tuple[str, int, int]] = {}
    for report in reports:
        for target in targets_of(report):
            name = target.get("name", "")
            if name.endswith(".xctest"):
                continue
            for f in target.get("files") or []:
                path = f.get("path", "")
                if not path.startswith(prefix):
                    continue
                rel = path[len(prefix):]
                if rel.startswith(NOT_OURS):
                    continue
                covered, executable = int(f["coveredLines"]), int(f["executableLines"])
                if covered < 0 or executable < 0 or covered > executable:
                    die(f"{rel}: {covered} covered of {executable} executable lines")
                seen = best.get(rel)
                if seen is None or covered > seen[1]:
                    best[rel] = (name, covered, executable)
    return best


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--root", required=True, help="the repository checkout")
    parser.add_argument("--floor", required=True, type=float, help="minimum percent")
    parser.add_argument("reports", nargs="+", type=Path)
    args = parser.parse_args(argv)
    if not 0 <= args.floor <= 100:
        die(f"the floor {args.floor} is not a percentage")

    reports = []
    for path in args.reports:
        try:
            reports.append(json.loads(path.read_text()))
        except (OSError, ValueError) as e:
            die(f"{path} could not be read as JSON ({e})")

    files = counted_files(reports, args.root)
    if not files:
        die(f"no source file under {args.root} in {len(reports)} report(s)")

    per_target: dict[str, list[int]] = {}
    for name, covered, executable in files.values():
        sums = per_target.setdefault(name, [0, 0])
        sums[0] += covered
        sums[1] += executable
    for name in sorted(per_target):
        covered, executable = per_target[name]
        pct = 100 * covered / executable if executable else 0.0
        print(f"{name}: {pct:.2f}% ({covered}/{executable} lines)")

    covered = sum(c for _, c, _ in files.values())
    executable = sum(e for _, _, e in files.values())
    if executable == 0:
        die("the counted files have no executable line")
    pct = 100 * covered / executable
    print(f"project line coverage - {pct:.2f}% ({covered}/{executable} lines in {len(files)} files, floor {args.floor:.2f}%)")
    if pct < args.floor:
        print(f"FATAL - line coverage {pct:.2f}% is below the floor of {args.floor:.2f}%")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
