#!/usr/bin/env python3
"""Fails when a guide links a file that is not in the repository."""
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
missing = []
for md in sorted(root.glob("README*.md")):
    text = md.read_text(encoding="utf-8")
    for target in re.findall(r"\]\(([^)#]+)\)", text):
        if not target.startswith("http") and not (md.parent / target).exists():
            missing.append("%s -> %s" % (md.name, target))
if missing:
    print("\n".join(missing))
    sys.exit(1)
