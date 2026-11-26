#!/usr/bin/env python3
"""Tests of ci/coverage_floor.py: what counts as the project's code, the per-file merge
across reports, and every way a report can fail to be a pass.

    python3 ci/coverage_floor_test.py
"""

from __future__ import annotations

import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import coverage_floor  # noqa: E402

ROOT = "/runner/work/district-ios"


def file(rel: str, covered: int, executable: int, root: str = ROOT) -> dict:
    return {"path": f"{root}/{rel}", "coveredLines": covered, "executableLines": executable}


def target(name: str, *files: dict) -> dict:
    return {"name": name, "files": list(files)}


class FloorTests(unittest.TestCase):
    def run_floor(self, floor: float, *reports: object, raw: list[str] | None = None) -> tuple[int, str]:
        with tempfile.TemporaryDirectory() as tmp:
            paths = []
            for i, report in enumerate(reports):
                p = Path(tmp) / f"r{i}.json"
                p.write_text(json.dumps(report))
                paths.append(str(p))
            for i, text in enumerate(raw or []):
                p = Path(tmp) / f"raw{i}.json"
                p.write_text(text)
                paths.append(str(p))
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                try:
                    code = coverage_floor.main(["--root", ROOT, "--floor", str(floor), *paths])
                except SystemExit as e:
                    code = int(e.code)
            return code, out.getvalue()

    def test_counts_only_shipped_repository_code(self) -> None:
        report = {"targets": [
            target("DistrictAI.app", file("App/Sources/A.swift", 8, 10)),
            # A test bundle's own lines would inflate the figure: never counted.
            target("DistrictAITests.xctest", file("App/Tests/ATests.swift", 100, 100)),
            # Dependencies are other projects, resolved under the checkout.
            target("DistrictData", file("SourcePackages/checkouts/core/Data.swift", 0, 1000)),
            target("Sentry", file("DerivedData/SourcePackages/x.swift", 0, 50)),
            # A file outside the checkout, even one whose path merely shares the prefix.
            target("DistrictAI.app", file("Elsewhere.swift", 0, 500, root="/runner/work/district-ios-other")),
        ]}
        code, out = self.run_floor(80, report)
        self.assertEqual(code, 0, out)
        self.assertIn("project line coverage - 80.00% (8/10 lines in 1 files", out)
        self.assertNotIn("DistrictAITests", out)
        self.assertNotIn("DistrictData", out)

    def test_below_the_floor_fails(self) -> None:
        code, out = self.run_floor(80.01, [target("DistrictAI.app", file("App/A.swift", 8, 10))])
        self.assertEqual(code, 1)
        self.assertIn("FATAL - line coverage 80.00% is below the floor of 80.01%", out)

    def test_a_file_in_two_reports_takes_the_better_one_not_the_sum(self) -> None:
        ios = {"targets": [target("DistrictAIWatch.app", file("Watch/Sources/W.swift", 1, 10))]}
        watch = {"targets": [target("DistrictAIWatch.app", file("Watch/Sources/W.swift", 7, 10))]}
        code, out = self.run_floor(70, ios, watch)
        self.assertEqual(code, 0, out)
        self.assertIn("70.00% (7/10 lines in 1 files", out)
        code, out = self.run_floor(70, watch, ios)
        self.assertIn("70.00% (7/10 lines in 1 files", out)

    def test_the_only_targets_list_shape_is_read_too(self) -> None:
        code, out = self.run_floor(50, [target("DistrictAI.app", file("App/A.swift", 1, 2))])
        self.assertEqual(code, 0, out)
        self.assertIn("DistrictAI.app: 50.00% (1/2 lines)", out)

    def test_nothing_counted_is_a_failure_not_a_pass(self) -> None:
        for report in ({"targets": []}, [target("DistrictData", file("SourcePackages/a.swift", 1, 1))], [target("x", )]):
            code, out = self.run_floor(0, report)
            self.assertEqual(code, 1, report)
            self.assertIn("FATAL - no source file under", out)

    def test_only_non_executable_files_is_a_failure(self) -> None:
        code, out = self.run_floor(0, [target("DistrictAI.app", file("App/Empty.swift", 0, 0))])
        self.assertEqual(code, 1)
        self.assertIn("no executable line", out)

    def test_hostile_reports(self) -> None:
        code, out = self.run_floor(0, raw=["not json"])
        self.assertEqual(code, 1)
        self.assertIn("could not be read as JSON", out)
        code, out = self.run_floor(0, {"coverage": 1})
        self.assertEqual(code, 1)
        self.assertIn("neither an xccov object", out)
        # More covered than executable, or negative, is a corrupt report, not 100 percent.
        for covered, executable in ((11, 10), (-1, 10), (0, -5)):
            code, out = self.run_floor(0, [target("DistrictAI.app", file("App/A.swift", covered, executable))])
            self.assertEqual(code, 1, (covered, executable))
            self.assertIn("App/A.swift:", out)

    def test_a_floor_that_is_not_a_percentage_is_refused(self) -> None:
        for floor in (-1, 100.5):
            code, out = self.run_floor(floor, [target("DistrictAI.app", file("App/A.swift", 1, 1))])
            self.assertEqual(code, 1)
            self.assertIn("is not a percentage", out)

    def test_a_root_with_a_trailing_slash_is_the_same_root(self) -> None:
        out = io.StringIO()
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "r.json"
            p.write_text(json.dumps([target("DistrictAI.app", file("App/A.swift", 1, 1))]))
            with contextlib.redirect_stdout(out):
                code = coverage_floor.main(["--root", ROOT + "/", "--floor", "100", str(p)])
        self.assertEqual(code, 0, out.getvalue())


if __name__ == "__main__":
    unittest.main()
