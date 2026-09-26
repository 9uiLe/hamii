#!/usr/bin/env python3
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
missing = []
for document in [root / "README.md", *(root / "docs").rglob("*.md"), *(root / "adr").rglob("*.md"), *(root / "Samples").rglob("*.md")]:
    text = document.read_text()
    for link in re.findall(r"\]\(([^)]+)\)", text):
        if "://" in link or link.startswith(("#", "mailto:")):
            continue
        path = link.split("#", 1)[0]
        if path and not (document.parent / path).exists():
            missing.append(f"{document.relative_to(root)}: {link}")
if missing:
    print("Broken local documentation links:\n" + "\n".join(missing), file=sys.stderr)
    sys.exit(1)
print("Documentation links valid")
