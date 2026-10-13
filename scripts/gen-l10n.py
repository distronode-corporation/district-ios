#!/usr/bin/env python3
"""Writes the app's generated strings from its catalogs, or checks them.

    python3 scripts/gen-l10n.py           # rewrite every generated file below
    python3 scripts/gen-l10n.py --check   # fail on a stale file, a non-canonical catalog,
                                          # a broken catalog rule or an Info.plist drift
                                          # (what CI runs)

Three catalogs, three outputs. The vendored tools in `tools/l10n/` (copied from the
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

⛔ THE TWO LANGUAGES' TABLES LIVE APART. `en.lproj` sits in `App/Resources/` and ships in
every build. `fr-CA.lproj` sits in `App/Localization/`, which only `project.fr.yml`
(included when `DISTRICT_FRENCH` is set) adds to the app: an XcodeGen include can add a
source but never remove an `excludes`, so French cannot sit beside English and be left
out. Until the catalogs carry French, the fr-CA tables hold the English.

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


def tool(*args: str, quiet: bool = False) -> int:
    out = subprocess.DEVNULL if quiet else None
    return subprocess.run([sys.executable, str(TOOL), *args], cwd=ROOT, check=False, stdout=out).returncode


def strings_files(scratch: Path) -> dict[Path, bytes]:
    """Every .strings file the catalogs produce, keyed by where it belongs in the tree."""
    out: dict[Path, bytes] = {}
    for catalog, table in TABLES.items():
        target = scratch / table
        code = tool("gen", "--backend", "apple-strings", catalog, "--out", str(target),
                    "--opt", f"name={table}", "--opt", "_quiet=1", quiet=True)
        if code:
            raise SystemExit(code)
        for folder, home in LPROJ.items():
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
        stale = [str(p.relative_to(ROOT)) for p, data in tables.items() if not p.exists() or p.read_bytes() != data]
        for path in stale:
            print(f"{path}: stale, run python3 scripts/gen-l10n.py", file=sys.stderr)
        drift = info_plist_drift()
        for line in drift:
            print(line, file=sys.stderr)
        return 1 if code or stale or drift else 0
    code = tool("gen", "--backend", "swift", *SWIFT_CATALOGS, "--out", SWIFT, *SWIFT_OPTS)
    for path, data in tables.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        print(f"wrote {path.relative_to(ROOT)}")
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
