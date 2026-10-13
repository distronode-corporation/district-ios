#!/usr/bin/env python3
"""Writes the app's generated strings from its catalog, or checks them.

    python3 scripts/gen-l10n.py           # rewrite App/Sources/L10n/Generated/Copy.swift
    python3 scripts/gen-l10n.py --check   # fail on a stale file, a non-canonical catalog
                                          # or a broken catalog rule (what CI runs)

`l10n/ios.toml` holds every sentence the `*Copy` enums say. The vendored tools in
`tools/l10n/` (copied from the monorepo's `i18n/tools/`, see `tools/l10n/SOURCE.toml`)
turn it into one `extension XCopy { static var ... }` per enum, so each call site reads
`XCopy.member` exactly as it did when the string was a `static let`.

⚠️ THE OPTIONS LIVE HERE AND NOWHERE ELSE. A second spelling of them (in the workflow,
in a README) would let the file CI checks and the file a developer writes differ.
- `extension=true`: the hand-written `enum XCopy` keeps its logic functions, and the
  generated file only adds to it.
- `runtime=external`, `locale_expr=AppL10n.copyLocale`: the language is the core's
  `L10nRuntime.locale`, read through the app's own `AppL10n`, because a generated file
  imports nothing.
- `access=internal`: the Copy enums are internal to the app target.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / "tools/l10n/l10n.py"
CATALOGS = ["l10n/ios.toml"]
SWIFT = "App/Sources/L10n/Generated/Copy.swift"
OPTS = [
    "--opt", "extension=true",
    "--opt", "runtime=external",
    "--opt", "access=internal",
    "--opt", "locale_expr=AppL10n.copyLocale",
]


def main(argv: list[str]) -> int:
    if argv not in ([], ["--check"]):
        print(__doc__, file=sys.stderr)
        return 2
    if argv == ["--check"]:
        cmd = [sys.executable, str(TOOL), "check", *CATALOGS, "--gen", f"swift:{SWIFT}", *OPTS]
    else:
        cmd = [sys.executable, str(TOOL), "gen", "--backend", "swift", *CATALOGS, "--out", SWIFT, *OPTS]
    return subprocess.run(cmd, cwd=ROOT, check=False).returncode


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
