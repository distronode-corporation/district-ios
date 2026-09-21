#!/usr/bin/env bash
#
# Line-coverage floors for Packages/DistrictCore, enforced per module.
#
# Run it AFTER `swift test --enable-code-coverage`, from anywhere:
#   ci/coverage-gate.sh   (path relative to the project root)
#
# ── Why a script and not a `swift test` flag ──────────────────────────────────
# SwiftPM has no coverage threshold of its own. It writes an llvm-cov export
# JSON as a side effect of `--enable-code-coverage` and stops there, so without
# something like this file the coverage data is produced, uploaded nowhere, and
# read by nobody, while any floors written down elsewhere describe a ratchet
# that nothing ever checks.
#
# ── The ratchet convention ───────────────────────────────────────────────────
# ⛔ EVERY FLOOR IS 100, AND FLOORS MAY ONLY EVER GO UP. A floor that trails
# measured coverage permits deleting tests without a red pipeline, which is
# what "a floor nobody ratchets" always decays into, and at 100 there is nothing
# left to trail.
#
# ⛔ AN UNCOVERED LINE IS ANSWERED BY A TEST OR BY DELETING IT, NEVER BY A LOWER
# FLOOR. A line no test can reach is dead code: delete it and say at the site
# why it could never run. A line that can run gets a test, with hostile input if
# that is what reaches it. The one legitimate reason to want a lower floor is a
# module growing a genuinely-untestable-on-Linux surface, and that belongs in
# App/ rather than here by construction (a debug-only `assertionFailure` is the
# worked example: see SchedulingAdminRepository's initialiser).
#
# ⚠️ llvm-cov COUNTS LINES PER FUNCTION, AND SWIFT COMPILES THE RIGHT-HAND SIDE
# OF `??` (AND OF `&&`/`||`) AS ITS OWN CLOSURE. So `x ?? fallback` whose
# fallback never runs is an uncovered line in this report even though `lcov`
# shows the line executed. That is the report being right: the fallback is
# code no test runs.
#
# ⚠️ PER MODULE, NOT JUST A TOTAL. A single aggregate lets a well-tested module
# subsidise an untested one, and a gate can report a comfortable percentage
# while silently measuring only part of the code. Every module below must
# APPEAR in the report; a module that produces no coverage data at all is a
# hard failure, not a 100%.
set -euo pipefail

# ── Floors ───────────────────────────────────────────────────────────────────
# No slack. It was a point below measured coverage until 2026-09-26, when the
# last 23 uncovered lines were tested or deleted.
FLOOR_TOTAL=100
FLOOR_DistrictModel=100
FLOOR_DistrictAuthCore=100
FLOOR_DistrictNetwork=100
FLOOR_DistrictData=100
FLOOR_DistrictCall=100

# Modules the gate requires to be present in the report. Adding a target to
# Package.swift without adding it here means it is built, possibly tested, and
# NOT gated — so the list is duplicated deliberately and the script fails if a
# name here has no files in the report.
MODULES="DistrictModel DistrictAuthCore DistrictNetwork DistrictData DistrictCall"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="${DISTRICT_CORE_DIR:-$SCRIPT_DIR/../Packages/DistrictCore}"

fatal() {
    echo "FATAL: $*" >&2
    exit 1
}

[ -d "$PACKAGE_DIR" ] || fatal "package directory not found: $PACKAGE_DIR"
cd "$PACKAGE_DIR"

command -v swift >/dev/null 2>&1 || fatal "swift not on PATH — wrong image?"
# ⚠️ python3 is asserted rather than assumed. ci/Dockerfile and the workflow's
# `verify` job install it explicitly for this script; the stock swift image is
# not guaranteed to carry it.
command -v python3 >/dev/null 2>&1 || fatal "python3 not on PATH — see ci/Dockerfile"

# ── Locate the coverage export ───────────────────────────────────────────────
# ⛔ A MISSING FILE ABORTS. It never falls through to "nothing to check, pass":
# a skipped measurement must stop the job, because "no data" and "all green" are
# indistinguishable from the outside and the second one is what a fall-through
# would report.
CODECOV_JSON="$(swift test --show-codecov-path 2>/dev/null | tail -n 1 || true)"

if [ -z "$CODECOV_JSON" ] || [ ! -f "$CODECOV_JSON" ]; then
    # Fall back to a direct search before giving up: --show-codecov-path can
    # print a path for a configuration that was not the one just tested.
    CODECOV_JSON="$(find .build -path '*/codecov/*.json' -type f 2>/dev/null | head -n 1 || true)"
fi

if [ -z "$CODECOV_JSON" ] || [ ! -f "$CODECOV_JSON" ]; then
    fatal "no coverage export found under $PACKAGE_DIR/.build.
       Run 'swift test --enable-code-coverage' first. This is a HARD failure and
       not a skip: an absent measurement must never read as a passing one."
fi

echo "coverage export: $CODECOV_JSON"

# ── Enforce ──────────────────────────────────────────────────────────────────
# The export is llvm-cov's own JSON (data[].files[].summary.lines.{count,covered}).
# Percentages are recomputed from the raw counts rather than read from
# `.percent`, so a module of two files is weighted by lines and not by file.
MODULES="$MODULES" \
FLOOR_TOTAL="$FLOOR_TOTAL" \
FLOOR_DistrictModel="$FLOOR_DistrictModel" \
FLOOR_DistrictAuthCore="$FLOOR_DistrictAuthCore" \
FLOOR_DistrictNetwork="$FLOOR_DistrictNetwork" \
FLOOR_DistrictData="$FLOOR_DistrictData" \
FLOOR_DistrictCall="$FLOOR_DistrictCall" \
python3 - "$CODECOV_JSON" <<'PYTHON'
import json
import os
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    report = json.load(handle)

data = report.get("data")
if not data:
    sys.exit("FATAL: coverage export has no `data` array — llvm-cov schema changed.")

modules = os.environ["MODULES"].split()
counts = {name: [0, 0] for name in modules}   # module -> [covered, total]
total = [0, 0]

for block in data:
    for entry in block.get("files", []):
        filename = entry.get("filename", "")
        # Only first-party sources. Test files and anything checked out under
        # .build are excluded: a test file counting towards its own coverage
        # inflates every number and hides the code it was meant to exercise.
        if "/Sources/" not in filename or "/.build/" in filename:
            continue
        lines = entry.get("summary", {}).get("lines")
        if lines is None:
            sys.exit(f"FATAL: no line summary for {filename} — llvm-cov schema changed.")
        covered, count = lines["covered"], lines["count"]
        total[0] += covered
        total[1] += count
        for name in modules:
            if f"/Sources/{name}/" in filename:
                counts[name][0] += covered
                counts[name][1] += count
                break
        else:
            sys.exit(
                f"FATAL: {filename} belongs to no gated module.\n"
                "       Add its target to MODULES (and a FLOOR_ entry) in "
                "ci/coverage-gate.sh, or it ships ungated."
            )

failures = []


def check(label, covered, count, floor):
    if count == 0:
        # ⛔ NOT A PASS. Zero measurable lines means the module was not built
        # with coverage, was renamed, or its sources vanished.
        failures.append(f"{label}: NO COVERAGE DATA (0 measurable lines) — floor {floor}%")
        print(f"  {label:<20} no data                 floor {floor}%   FAIL")
        return
    pct = 100.0 * covered / count
    verdict = "ok" if pct + 1e-9 >= floor else "FAIL"
    print(f"  {label:<20} {pct:6.2f}%  ({covered}/{count})   floor {floor}%   {verdict}")
    if verdict == "FAIL":
        failures.append(f"{label}: {pct:.2f}% < floor {floor}%")


print("DISTRICTCORE line coverage:")
for name in modules:
    covered, count = counts[name]
    check(name, covered, count, int(os.environ[f"FLOOR_{name}"]))
check("TOTAL", total[0], total[1], int(os.environ["FLOOR_TOTAL"]))

# The one line a reader greps a job log for; keep its wording stable.
print()
total_pct = (100.0 * total[0] / total[1]) if total[1] else 0.0
print(f"DISTRICTCORE TOTAL line coverage: {total_pct:.2f}%")

if failures:
    print()
    print("FATAL: coverage floors not met:")
    for line in failures:
        print(f"  - {line}")
    print()
    print("Floors are a ratchet: raise them when coverage rises, and fix coverage")
    print("rather than lowering them. See the header of ci/coverage-gate.sh.")
    sys.exit(1)

print()
print("All coverage floors met.")
PYTHON
