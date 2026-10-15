#!/usr/bin/env python3
"""QA only: drop the fr and state lines pseudo.py writes into `fixed = true` entries."""
import re, sys
path = sys.argv[1]
blocks, cur = [], []
for line in open(path, encoding="utf-8").read().split("\n"):
    if line.startswith("[") and cur:
        blocks.append(cur); cur = []
    cur.append(line)
blocks.append(cur)
out = []
for b in blocks:
    if any(l.strip() == "fixed = true" for l in b):
        b = [l for l in b if not re.match(r"(fr|state)(\.\w+)? = ", l) and not re.match(r"fr\s*=", l)]
    out.extend(b)
open(path, "w", encoding="utf-8").write("\n".join(out))
