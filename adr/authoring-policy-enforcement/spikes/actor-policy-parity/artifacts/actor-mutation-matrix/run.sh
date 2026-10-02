#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/hamii-actor-policy.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
mkdir -p "$scratch/Sources/Probe"
cp "$script_dir/probe.swift" "$scratch/Sources/Probe/main.swift"
cat > "$scratch/Package.swift" <<'SWIFT'
// swift-tools-version: 6.4
import Foundation
import PackageDescription

let root = ProcessInfo.processInfo.environment["HAMII_REPO_ROOT"]!
let package = Package(name: "ActorPolicyProbe", platforms: [.macOS(.v14)],
    dependencies: [.package(path: root)], targets: [
    .executableTarget(name: "Probe", dependencies: [
        .product(name: "HamiiCore", package: "hamii"),
        .product(name: "HamiiApplication", package: "hamii")
    ])
])
SWIFT
HAMII_REPO_ROOT="$repo_root" swift run --package-path "$scratch" --scratch-path "$scratch/build" Probe
