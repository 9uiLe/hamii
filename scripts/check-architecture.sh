#!/usr/bin/env bash
set -euo pipefail

check_imports() {
  local directory="$1"
  local forbidden="$2"
  if grep -R -n -E "^[[:space:]]*import (${forbidden})$" "$directory"; then
    echo "Forbidden dependency in $directory" >&2
    exit 1
  fi
}

check_imports Sources/HamiiCore 'AppKit|SwiftUI|UIKit|SQLite3|HamiiApplication|HamiiFormat|HamiiIndex|HamiiCLI|HamiiApp|HamiiMigrations|HamiiMigrationRuntime'
check_imports Sources/HamiiApplication 'AppKit|SwiftUI|UIKit|SQLite3|HamiiFormat|HamiiIndex|HamiiCLI|HamiiApp|HamiiMigrations'
check_imports Sources/HamiiPreviewProtocol 'AppKit|SQLite3|HamiiFormat|HamiiIndex|HamiiCLI|HamiiApp|HamiiMigrations'
check_imports Sources/HamiiGeneration 'AppKit|SQLite3|HamiiApplication|HamiiFormat|HamiiIndex|HamiiCLI|HamiiApp|HamiiMigrations'
check_imports Sources/HamiiIntegration 'AppKit|SQLite3|HamiiApplication|HamiiFormat|HamiiIndex|HamiiCLI|HamiiApp|HamiiMigrations'
check_imports Sources/HamiiMigrations 'AppKit|SwiftUI|UIKit|SQLite3|CryptoKit|HamiiCore|HamiiApplication|HamiiFormat|HamiiIndex|HamiiCLI|HamiiApp|HamiiMigrationRuntime'
check_imports Sources/HamiiMigrationRuntime 'AppKit|SwiftUI|UIKit|HamiiCLI|HamiiApp'
check_imports Sources/HamiiFormat 'HamiiMigrationRuntime'
check_imports Sources/HamiiIndex 'HamiiMigrationRuntime'
check_imports Sources/HamiiNativeRuntime 'AppKit|SQLite3|HamiiApplication|HamiiFormat|HamiiIndex|HamiiCLI|HamiiApp|HamiiMigrations'

if grep -n -E 'GitCanonicalRevisionCalculator|git[[:space:]]*\(|Process\(' Sources/HamiiIndex/LocalIndex.swift; then
  echo 'LocalIndex query/store code must use the CanonicalRevisionCalculating port' >&2
  exit 1
fi

if grep -R -n 'adr/' Sources; then
  echo 'Production sources must not depend on ADR files' >&2
  exit 1
fi

while IFS= read -r file; do
  if [[ "$file" == */WorktreeCoordinator.swift ]]; then
    continue
  fi
  if grep -n -E 'flock\(|write\.lock|client-observation-epoch' "$file"; then
    echo "Worktree lock and observation epoch must be owned by WorktreeCoordinator: $file" >&2
    exit 1
  fi
done < <(find Sources -type f -name '*.swift')

echo 'Architecture dependencies valid'
