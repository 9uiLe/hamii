#!/usr/bin/env bash
set -euo pipefail

echo "HAMII_CHECK_START adr"
python3 scripts/check-adr.py
echo "HAMII_CHECK_PASSED adr"
echo "HAMII_CHECK_START links"
python3 scripts/check-links.py
echo "HAMII_CHECK_PASSED links"
echo "Documentation checks passed; Swift build and tests were not run (Markdown-only diff)."
