# Reproduce the source/build bridge evidence

This Spike used a pinned Apple Food Truck base commit `3954a769e99f3cc53297d94f2b960ceb2665b3d6`. The two incremental bundles preserve the exact disposable child commits without adding the Product tree to hamii. They **require** that base commit to be available locally. The test environment had the base in `/tmp/hamii-integration-spike/targets/food-truck`; availability of the same object from its upstream remote at a later date was not tested.

From the hamii repository root, set task-specific paths for an existing clean clone containing the exact base commit and for disposable output locations:

```sh
HAMII_BRIDGE_ARTIFACTS="$PWD/adr/product-build-membership/spikes/source-to-selected-build-bridge/artifacts"
HAMII_BRIDGE_BASE_REPO=/path/to/food-truck-with-pinned-base
HAMII_BRIDGE_REPLAY=/tmp/hamii-bridge-replay
git -C "$HAMII_BRIDGE_BASE_REPO" cat-file -e 3954a769e99f3cc53297d94f2b960ceb2665b3d6^{commit}
git clone --no-local "$HAMII_BRIDGE_BASE_REPO" "$HAMII_BRIDGE_REPLAY"
git -C "$HAMII_BRIDGE_REPLAY" bundle verify "$HAMII_BRIDGE_ARTIFACTS/food-truck-profile-c1.bundle"
git -C "$HAMII_BRIDGE_REPLAY" fetch "$HAMII_BRIDGE_ARTIFACTS/food-truck-profile-c1.bundle" HEAD:refs/heads/hamii-bridge-c1
git -C "$HAMII_BRIDGE_REPLAY" bundle verify "$HAMII_BRIDGE_ARTIFACTS/food-truck-source-c2.bundle"
git -C "$HAMII_BRIDGE_REPLAY" fetch "$HAMII_BRIDGE_ARTIFACTS/food-truck-source-c2.bundle" HEAD:refs/heads/hamii-bridge-c2
git -C "$HAMII_BRIDGE_REPLAY" rev-parse refs/heads/hamii-bridge-c1 refs/heads/hamii-bridge-c2
git -C "$HAMII_BRIDGE_REPLAY" checkout --detach refs/heads/hamii-bridge-c1
```

The final command must print C1 `3cf70a8775a8d528d27b560185ed6d1116557b99` and C2 `4050d4f2c5e7bf357e4b82af4ef39a1ad9c7ed1b` in that order. Bundle SHA-256 values are `ed5cbb3a8ccc4306d6cb3f5363b0ebb94530e48fd53874e1a265d4c463ff2889` and `19a0abe6a660dad81b386586510b7280a885b7c05e72d7a0ecb1cb986f075082`. [bundle-preservation.json](bundle-preservation.json) records the measured size and replay checks. The [readable Profile v2](profile-v2.json) duplicates the tracked Profile blob in C1 for inspection.

The production source/receipt trial used a disposable hamii project created by [create-hamii.swift](create-hamii.swift). The committed creator accepts its output root as an argument; the measured source role used identical fixture construction with its fixed scratch path. After building hamii, a replay is:

```sh
swiftc -I .build/debug -L .build/debug -lHamiiFormat -lHamiiApplication -lHamiiCore "$HAMII_BRIDGE_ARTIFACTS/create-hamii.swift" -o /tmp/hamii-bridge-create-hamii
/tmp/hamii-bridge-create-hamii /tmp/hamii-bridge-hamii
.build/debug/hamii --project /tmp/hamii-bridge-hamii --json integration plan screen_bridge --product-repository "$HAMII_BRIDGE_REPLAY" --repository-profile config/hamii-profile.json
```

The Product repository must be at detached C1 for this replay. A fresh hamii fixture gets a new document identity, so compare the **semantic** receipt fields (`productCommitOID`, `profileBlobOID`, mapping key, status, scope, path, source blob), not its random hamii document ID. The original [source CLI output](source-cli-output.json) and [source evidence](source-evidence.json) preserve the exact measured C1 observation.

The measured fresh build was run from a full `git archive` of C1, not the mutable checkout. Use a separate archive and DerivedData path for each fresh trial:

```sh
mkdir -p /tmp/hamii-bridge-replay-all
git -C "$HAMII_BRIDGE_REPLAY" archive refs/heads/hamii-bridge-c1 | tar -x -C /tmp/hamii-bridge-replay-all
cd /tmp/hamii-bridge-replay-all
xcodebuild build -project 'Food Truck.xcodeproj' -scheme 'Food Truck All' \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/hamii-bridge-replay-dd \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  > /tmp/hamii-bridge-replay-build.log 2>&1
```

Keep the build command's exit status. Re-run **the same command and DerivedData path** once for the warm/no-op control. For relocation, extract C1 into a second distinct path and use a new DerivedData path. For C2, archive `refs/heads/hamii-bridge-c2` and use a new DerivedData path. Do not treat a successful warm build as fresh membership evidence if its log contains no executed SwiftDriver invocation. Inspect the selected arm64 SwiftDriver commands and their `@...SwiftFileList` inputs; compare `App/General/FlowLayout.swift` bytes with `git -C "$HAMII_BRIDGE_REPLAY" rev-parse refs/heads/hamii-bridge-c1:App/General/FlowLayout.swift` (or the C2 ref for the changed commit). The compact [build inventory](build-inventory.json) records the measured descriptors, selected modules, target input records, generated inputs, normalized command hashes, and timings. Raw Xcode logs and DerivedData were not committed.

The independent classifier is reproducible **from the committed compact artifacts**:

```sh
python3 "$HAMII_BRIDGE_ARTIFACTS/selftest.py"
python3 "$HAMII_BRIDGE_ARTIFACTS/evaluate.py" \
  --source "$HAMII_BRIDGE_ARTIFACTS/source-evidence.json" \
  --build "$HAMII_BRIDGE_ARTIFACTS/build-inventory.json" \
  --out /tmp/hamii-bridge-join-replay
```

`selftest.py` exercises synthetic controls. `evaluate.py` writes the six observed-join classifications and eight synthetic fail-closed classifications. It can recheck the compact artifacts' internal consistency; it **cannot independently authenticate the original raw Xcode logs or Git bytes after those raw files are gone**. Rebuild from the restored commits to remeasure that boundary. Neither script is production validation code.
