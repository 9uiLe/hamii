# Source isolation probe (disposable /tmp, 2026-10-02)

## Scope and provenance

- Pinned Product source: Food Truck C1 `3cf70a8775a8d528d27b560185ed6d1116557b99`, archive `/tmp/hamii-bridge-build-5_rduf7f/first` (29 MB). `App/General/FlowLayout.swift` Git blob `92c12dc1f8ed077e2384d99792310648b9c8f718`.
- Host: Xcode 27.0 (`27A266a`), Apple Swift 6.4, iPhoneSimulator27.0 SDK, arm64, Debug. All writes/tests were in `/tmp`; no hamii repository edits or privileged irreversible changes.
- This report tests source-path protection only. It does not test evidence-channel authenticity, and makes no `selectedBuildMember` production claim.

## Read-only disk image and build compatibility

Commands:

```sh
hdiutil create -srcfolder /tmp/hamii-bridge-build-5_rduf7f/first -format UDRO -volname HamiiPinnedC1 -ov /tmp/hamii-xcode-acq-probe.npwcYW/pinned.dmg
hdiutil attach -readonly -nobrowse -mountpoint /tmp/hamii-xcode-acq-probe.npwcYW/mount /tmp/hamii-xcode-acq-probe.npwcYW/pinned.dmg
cd /tmp/hamii-xcode-acq-probe.npwcYW/mount
xcodebuild build -project 'Food Truck.xcodeproj' -scheme 'Food Truck All' -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/hamii-xcode-acq-probe.npwcYW/derived ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO
```

The image creation took about 5 s, attach about 6 s. The fresh build exited 0 in 32.98 s and logged three executed arm64 SwiftDriver invocations plus `BUILD SUCCEEDED` (`mounted-build.log`, 237,948 bytes). The target FlowLayout blob remained exact. A same-UID append to the mounted source failed `EROFS`; making a symlink inside the mount failed `EROFS`. `chmod u+w` returned 0 but did not change mode or allow writing.

`xcodebuild -showBuildSettings -json` from the mount resolved `Food Truck All` / `Food_Truck_All`, Debug, arm64, and iPhoneSimulator27.0 SDK. Requesting `NoSuchConfig` exited 0 and resolved Release, so exit status is insufficient for selection validation (`settings.json` records the positive settings probe).

## Same-UID source substitution attacks

All attacks below used this account (UID 501), in disposable paths, and restored the original mount/path afterward.

1. `diskutil unmount /tmp/hamii-xcode-protected.Pu25SN/mount` exited 0. Afterward the same UID recreated that path with a fake `App/General/FlowLayout.swift` containing `struct FlowLayout { let spacing = 123 }`; reading the original logical path returned those bytes. The fake directory was removed and the same UDRO image remounted successfully.
2. With the UDRO image **still mounted**, `os.rename('/tmp/hamii-xcode-protected.Pu25SN', '/tmp/hamii-xcode-protected.Pu25SN.moved')` succeeded. A symlink at the original parent path redirected the original logical source path to an attacker tree containing `struct FlowLayout { let spacing = 999 }`; the mounted original source remained at the moved path. The symlink and fake tree were removed, and the parent was renamed back. This bypass did not require unmounting.
3. `chflags uchg` on a disposable parent denied rename while set, but the same UID ran `chflags nouchg` successfully and then renamed it. User immutable flags are not an adversarial same-UID boundary.

## Sandboxes and executable Product steps

An outer `sandbox-exec` profile with `(allow default)` and `(deny file-write* (subpath "/private/tmp/hamii-xcode-protected.Pu25SN"))` denied touch, backing-DMG append, and parent rename. It still permitted `diskutil unmount`; subsequent replacement mkdir was denied. More importantly, a Food Truck Xcode build under this outer profile exited 74 during package resolution in 2.29 s, with `sandbox-exec: sandbox_apply: Operation not permitted` and no Swift invocation (`sandbox-build.log`). Adding `-disableAutomaticPackageResolution` also exited 74 (`sandbox-locked-build.log`). Even an outer `(allow default)` profile caused `-showBuildSettings -json` to exit 74 with the same nested-sandbox error. This no-privilege sandbox was incompatible with the measured Product's local package path.

A separate disposable copy of Food Truck added one `PBXShellScriptBuildPhase` (therefore **not** exact C1). Its script ran:

```sh
touch /tmp/hamii-xcode-protected.Pu25SN/probe-script; echo HAMII_TOUCH_STATUS=$?
diskutil unmount /tmp/hamii-xcode-protected.Pu25SN/mount; echo HAMII_UNMOUNT_STATUS=$?
```

The build used `ENABLE_USER_SCRIPT_SANDBOXING=YES`, fresh DerivedData, and exited 0 in 28.9 s. `script-build.log` lines 1589–1592 show Xcode invoking `/usr/bin/sandbox-exec` for the Run Script, `HAMII_TOUCH_STATUS=0`, and `HAMII_UNMOUNT_STATUS=0`; the protected-root file existed afterward and the mountpoint disappeared. Thus Xcode's own script sandbox did not prevent this same-UID helper/mount attack. `sudo -n true` failed with `a password is required`; no privileged command was run. `diskutil` itself reached the system mount service without sudo.

## Candidates not validated

- Separate unprivileged build UID plus another principal owning source and mount topology: not tested. Current account has no passwordless sudo or ability to set up a second principal safely in this probe.
- Root-owned materialization/mount: not tested; requires privilege not available without approval/setup. No `chflags schg` or root ownership changes attempted.
- VM with read-only host-provided source and separately protected evidence channel: not tested; would require a provisioned VM and careful host/guest path and output attestation design.
- Xcode's script sandbox, outer `sandbox-exec`, same-UID UDRO, and `uchg` were measured above and did not jointly yield a compatible protected execution boundary.

## Assessment

**Observed:** exact C1 can build from a UDRO source, but hostile same-UID code can replace the logical source path via parent rename/symlink even while that image remains mounted. A Product Run Script can use `diskutil` to unmount it despite `ENABLE_USER_SCRIPT_SANDBOXING=YES`. The tested outer sandbox protected the parent against writes but prevented this Xcode package build. **Unknown:** a no-privilege mechanism that both permits this Product build and prevents source-path/topology substitution; separate-UID/root/VM feasibility and evidence-channel protection. A positive source protection flag cannot be justified by these probes.

Raw artifacts: `mounted-build.log`, `sandbox-build.log`, `sandbox-locked-build.log`, `script-build.log`, `settings.json`, `pinned.dmg` under `/tmp/hamii-xcode-acq-probe.npwcYW/`. The disposable modified project is `script-probe/`; the protected image is `/tmp/hamii-xcode-protected.Pu25SN/pinned.dmg`.

## Replay transcript (preserved follow-up)

[`replay-source-substitution.py`](replay-source-substitution.py) contains bounded, unprivileged reproductions of the mounted parent rename/symlink rebind and unmount/recreate controls. It requires the exact disposable image SHA-256 and source blob OID, refuses occupied temporary paths, uses 20-second command timeouts, and restores the parent and mount in `finally` blocks. Its direct [`source-substitution-replay.json`](source-substitution-replay.json) result records UID 501, both fake source observations, successful restoration, and final original blob `92c12dc1f8ed077e2384d99792310648b9c8f718`. The replay completed with `passed: true` in 0.016 and 0.492 seconds for the two controls. These are same-UID source-path attacks, not Product build executions or evidence-channel tests.
