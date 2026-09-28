#!/usr/bin/env bash
set -euo pipefail

run_check() {
  local name="$1"
  shift
  echo "HAMII_CHECK_START $name"
  "$@"
  echo "HAMII_CHECK_PASSED $name"
}

run_check change-impact-tests python3 scripts/test_change_impact.py
run_check swift-test-shard-tests python3 scripts/test_swift_test_shards.py
run_check architecture bash scripts/check-architecture.sh
run_check adr python3 scripts/check-adr.py
run_check links python3 scripts/check-links.py

if [[ -x "$HOME/.swiftly/bin/swift" ]]; then
  hamii_swift="$HOME/.swiftly/bin/swift"
else
  hamii_swift="$(command -v swift)"
fi

hamii_swift_version="$("$hamii_swift" --version)"
echo "HAMII_CHECK_START swift-version"
if [[ ! "$hamii_swift_version" =~ Swift[[:space:]]version[[:space:]]6\.4([[:space:]]|$) ]]; then
  echo "Swift 6.4 is required; found: $hamii_swift_version" >&2
  exit 1
fi
echo "HAMII_CHECK_PASSED swift-version"
run_check swift-build "$hamii_swift" build --build-tests
run_check package-app bash scripts/package-app.sh
run_check codesign codesign --verify --deep --strict .build/hamii.app
run_check swift-test env HAMII_SWIFT="$hamii_swift" python3 scripts/run-swift-tests.py
run_check cli-smoke python3 scripts/smoke-cli.py
run_check state-precondition-smoke python3 scripts/smoke-state-precondition.py
run_check merge-candidate-smoke python3 scripts/smoke-merge-candidate.py
run_check samples python3 scripts/validate-samples.py
