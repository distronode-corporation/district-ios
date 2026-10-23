#!/usr/bin/env python3
"""Writes the app's generated strings from its catalogs, or checks them.

    python3 scripts/gen-l10n.py           # rewrite every generated file below
    python3 scripts/gen-l10n.py --check   # fail on a stale file, a non-canonical catalog,
                                          # a broken catalog rule or an Info.plist drift
                                          # (what CI runs)

Four catalogs. The first three are the iPhone app's, the fourth the Apple Watch app's. The vendored tools in `tools/l10n/` (copied from the
monorepo's `i18n/tools/`, see `tools/l10n/SOURCE.toml`) do the writing.

- `l10n/ios.toml`: every sentence the app's screens say. It becomes
  `App/Sources/L10n/Generated/Copy.swift`, one `extension XCopy { static var ... }` per
  enum, so each call site reads `XCopy.member` exactly as it did when the string was a
  `static let`.
- `l10n/push.toml`: the push loc-keys. iOS draws a notification from the KEYS the
  server sends (`title-loc-key`, `loc-key`), looked up in `Localizable.strings` without
  waking the app, so these are a `.strings` table and never Swift.
- `l10n/infoplist.toml`: the permission prompts iOS reads from `InfoPlist.strings`.
  ⛔ EACH ENGLISH MUST EQUAL project.yml's Info.plist VALUE, which the OS shows when a
  language has no table; `--check` compares them.
- `l10n/watch.toml`: every sentence the watch app and its complication say. It becomes
  `Watch/Sources/L10n/Generated/Copy.swift` (`extension WatchCopy`), which reads
  `WatchL10n.copyLocale` and imports nothing: ⛔ NO DistrictCore ON THE WATCH. The same
  catalog is also written as `Localizable.strings` into `Watch/Localization/en.lproj` and
  `fr-CA.lproj`, which is what makes the watch bundles declare Canadian French at all
  (`Bundle.preferredLocalizations` answers only languages a bundle ships).
- `l10n/watch-infoplist.toml`: the watch bundles' `InfoPlist.strings` (their display name).

⛔ THE TWO LANGUAGES' TABLES LIVE APART. `en.lproj` sits in `App/Resources/` and
`fr-CA.lproj` in `App/Localization/`; project.yml takes both into every build since 3.0.

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

import re
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / "tools/l10n/l10n.py"
SWIFT_CATALOGS = ["l10n/ios.toml"]
SWIFT = "App/Sources/L10n/Generated/Copy.swift"
SWIFT_OPTS = [
    "--opt", "extension=true",
    "--opt", "runtime=external",
    "--opt", "access=internal",
    "--opt", "locale_expr=AppL10n.copyLocale",
]
# catalog -> the .strings table it becomes
TABLES = {"l10n/push.toml": "Localizable", "l10n/infoplist.toml": "InfoPlist"}
LPROJ = {"en.lproj": ROOT / "App/Resources/en.lproj", "fr-CA.lproj": ROOT / "App/Localization/fr-CA.lproj"}
# The Apple Watch app (Watch/, Complications/): its own catalog, accessors and tables.
WATCH_CATALOGS = ["l10n/watch.toml"]
WATCH_SWIFT = "Watch/Sources/L10n/Generated/Copy.swift"
WATCH_SWIFT_OPTS = [
    "--opt", "extension=true",
    "--opt", "runtime=external",
    "--opt", "access=internal",
    "--opt", "locale_expr=WatchL10n.copyLocale",
]
# ⛔ BOTH TABLES IN BOTH WATCH BUNDLES (the app and the complication share
# Watch/Localization): scripts/archive-imac.sh refuses a release whose nested bundle lacks
# fr-CA.lproj/Localizable.strings or fr-CA.lproj/InfoPlist.strings.
WATCH_TABLES = {"l10n/watch.toml": "Localizable", "l10n/watch-infoplist.toml": "InfoPlist"}
WATCH_LPROJ = {"en.lproj": ROOT / "Watch/Localization/en.lproj", "fr-CA.lproj": ROOT / "Watch/Localization/fr-CA.lproj"}


def tool(*args: str, quiet: bool = False) -> int:
    out = subprocess.DEVNULL if quiet else None
    return subprocess.run([sys.executable, str(TOOL), *args], cwd=ROOT, check=False, stdout=out).returncode


def strings_files(scratch: Path) -> dict[Path, bytes]:
    """Every .strings file the catalogs produce, keyed by where it belongs in the tree."""
    out: dict[Path, bytes] = {}
    for tables, lproj, prefix in ((TABLES, LPROJ, "app"), (WATCH_TABLES, WATCH_LPROJ, "watch")):
        for catalog, table in tables.items():
            target = scratch / prefix / table
            code = tool("gen", "--backend", "apple-strings", catalog, "--out", str(target),
                        "--opt", f"name={table}", "--opt", "_quiet=1", quiet=True)
            if code:
                raise SystemExit(code)
            for folder, home in lproj.items():
                out[home / f"{table}.strings"] = (target / folder / f"{table}.strings").read_bytes()
    return out


def info_plist_drift() -> list[str]:
    """Each InfoPlist entry's English against the value project.yml gives the same key."""
    spec = (ROOT / "project.yml").read_text(encoding="utf-8")
    catalog = tomllib.loads((ROOT / "l10n/infoplist.toml").read_text(encoding="utf-8"))
    problems = []
    for key, entry in catalog["infoplist"].items():
        name = entry["id"]["apple"]
        match = re.search(rf'^\s+{re.escape(name)}:\s*"((?:[^"\\]|\\.)*)"\s*$', spec, re.M)
        if not match:
            problems.append(f"l10n/infoplist.toml:infoplist.{key}: project.yml declares no {name}")
        elif match.group(1) != entry["en"]:
            problems.append(f"l10n/infoplist.toml:infoplist.{key}: English differs from project.yml's {name}")
    return problems


def main(argv: list[str]) -> int:
    if argv not in ([], ["--check"]):
        print(__doc__, file=sys.stderr)
        return 2
    with tempfile.TemporaryDirectory() as scratch:
        tables = strings_files(Path(scratch))
    if argv == ["--check"]:
        code = tool("check", *SWIFT_CATALOGS, "--gen", f"swift:{SWIFT}", *SWIFT_OPTS)
        code |= tool("check", *TABLES)
        code |= tool("check", "l10n/watch-infoplist.toml")
        code |= tool("check", *WATCH_CATALOGS, "--gen", f"swift:{WATCH_SWIFT}", *WATCH_SWIFT_OPTS)
        stale = [str(p.relative_to(ROOT)) for p, data in tables.items() if not p.exists() or p.read_bytes() != data]
        for path in stale:
            print(f"{path}: stale, run python3 scripts/gen-l10n.py", file=sys.stderr)
        drift = info_plist_drift()
        for line in drift:
            print(line, file=sys.stderr)
        return 1 if code or stale or drift else 0
    code = tool("gen", "--backend", "swift", *SWIFT_CATALOGS, "--out", SWIFT, *SWIFT_OPTS)
    code |= tool("gen", "--backend", "swift", *WATCH_CATALOGS, "--out", WATCH_SWIFT, *WATCH_SWIFT_OPTS)
    for path, data in tables.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        print(f"wrote {path.relative_to(ROOT)}")
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
