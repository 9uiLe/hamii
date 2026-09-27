#!/usr/bin/env bash
set -euo pipefail

if [[ -x "$HOME/.swiftly/bin/swift" ]]; then
  hamii_swift="$HOME/.swiftly/bin/swift"
else
  hamii_swift="$(command -v swift)"
fi

hamii_swift_version="$("$hamii_swift" --version)"
if [[ ! "$hamii_swift_version" =~ Swift[[:space:]]version[[:space:]]6\.4([[:space:]]|$) ]]; then
  echo "Swift 6.4 is required; found: $hamii_swift_version" >&2
  exit 1
fi
"$hamii_swift" build
bash scripts/package-app.sh
codesign --verify --deep --strict .build/hamii.app
"$hamii_swift" test
bash scripts/check-architecture.sh
python3 scripts/check-adr.py
python3 scripts/check-links.py
python3 scripts/smoke-cli.py
python3 scripts/smoke-state-precondition.py
python3 scripts/smoke-merge-candidate.py
python3 scripts/validate-samples.py
