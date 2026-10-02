# Protected build execution boundary Spike

## Related Decision

[Product Build Membership Evidence](../../ADR.md) requires an immutable pinned source materialization or equivalent protected binding, and a recognized executed-invocation input inventory before `selectedBuildMember` is issued. This Spike asks whether an Xcode 27 Product build can satisfy both proof obligations under same-UID Product executable steps. It gathers implementation evidence; it does not reopen the narrow file-membership Decision.

## Hypothesis

A read-only pinned source image plus Xcode's build-script sandbox, or a usable outer process sandbox, might let a selected Product build succeed while preventing Product code from changing the source path/bytes and the evidence hamii uses to identify an executed compiler input.

## Questions

- Can the exact receipt-pinned Food Truck C1 build run from a read-only source image with separate DerivedData?
- Can a Product build process under the same UID modify the source bytes, a parent path, mount topology, or the compiler-input evidence channel?
- Is a no-privilege sandbox usable for this Product's Xcode build? Which alternatives require privilege or separate infrastructure?
- Which observed outcomes establish a protected source and trusted executed-invocation record, and which only demonstrate a vulnerability or an untested candidate?

## Prototype Scope

The source fixture is the disposable Food Truck C1 commit `3cf70a8775a8d528d27b560185ed6d1116557b99`, preserved by the [bridge Spike](../source-to-selected-build-bridge/SPIKE.md) bundles. Its `App/General/FlowLayout.swift` blob is `92c12dc1f8ed077e2384d99792310648b9c8f718`. The selected build uses Xcode 27.0 (`27A266a`), Apple Swift 6.4, `Food Truck All`, Debug, iPhoneSimulator27.0, arm64, and a fresh separate DerivedData directory. The source-isolation role used disposable `/tmp` C1 archives/images and one modified disposable Product project for a Run Script attack probe. The independent evidence-channel role used scratch copies of prior logs, file lists, and normalized inventory; it did not change C1 or run a malicious Xcode script. A third role audited both reports and raw artifacts independently. The hamii repository and original Product checkout were not modified by these probes.

## Out of Scope

Production Xcode acquisition/validator implementation; an adversarial compiler-time substitution demonstration; a proven way to authenticate an Xcode executed-invocation feed; fully isolated Xcode execution; root/separate-UID/VM deployment; power-loss durability; general Product build safety; whole-build reproducibility. A successful build alone is not a source or evidence-channel proof.

## Measurements

All timings below are **single trials on this host**, not distributions or Product guarantees.

| Source-boundary trial | Observation | Measured cost / limit |
| --- | --- | --- |
| UDRO APFS image from exact C1 archive, mounted read-only | Direct FlowLayout write and symlink creation inside the mount failed `EROFS`; selected fresh Xcode build succeeded with three arm64 SwiftDriver text lines and the pinned blob. | Image create about 5 s, attach about 6 s, build 32.98 s. |
| Same-UID `diskutil unmount` and fake-tree reconstruction | Unmount exit 0; the original logical source path read fake `spacing = 123`, then original image remounted. | Replay recorded 0.492 s for this control. |
| Mounted parent rename plus symlink rebind | Parent rename succeeded **while the UDRO image remained mounted**; original logical path read fake `spacing = 999`, while moved mount still held the pinned blob. The original path and mount were restored. | Replay recorded 0.016 s for this control. |
| User immutable flag `uchg` | Rename was blocked while set, but the same UID cleared it and renamed the parent. | No hostile same-UID guarantee. |
| Outer `sandbox-exec` deny-write profile | Parent writes/rename were denied, but the Food Truck Xcode build exited 74 during package resolution (`sandbox_apply: Operation not permitted`), including with automatic package resolution disabled. No Swift invocation occurred. | One measured configuration; not a compatible build proof. |
| Modified disposable Product Run Script with Xcode `ENABLE_USER_SCRIPT_SANDBOXING=YES` | Xcode ran the script via `/usr/bin/sandbox-exec`; the script touched the test parent and unmounted the UDRO image, both exit 0. The modified-project build exited 0. | 28.9 s; **not** the exact C1 project/commit. |

The bounded [source substitution replay](artifacts/source-substitution-replay.json) records preflight UID/image/blob/mount identity, both attacks, and postflight restoration. The [replay script](artifacts/replay-source-substitution.py) reruns the controls on the captured disposable fixture; it is not a production test and must be pointed at a recreated private fixture to run elsewhere. The [source isolation report](artifacts/source-isolation-assessment.md) gives commands, conditions, and raw-log locations. A short [script-build excerpt](artifacts/script-build-excerpt.txt) preserves the Xcode script sandbox invocation, successful touch/unmount, and subsequent SwiftDriver line. Full build logs and disk images remain in disposable `/tmp`, not Git.

The evidence-channel role measured **controlled scratch artifacts**, not malicious Xcode script execution:

| Evidence control | Observation | Limit |
| --- | --- | --- |
| Warm successful build log plus copied cold `builtin-SwiftDriver` line | Original warm log had 0 matching driver lines; forged copy had 1 matching a simple scanner. | A text occurrence alone cannot prove execution; no production parser was fooled. |
| Old `Food_Truck_All.SwiftFileList` after warm no-op | File list remained readable and named the pinned source despite no new SwiftDriver invocation. | Current-run binding is required. |
| Scratch file-list mutation/replacement | An appended `FoodTruckKit` source path changed observed count 0→1; `os.replace` changed copied file-list bytes; duplicate source lines were retained. | Same-UID writable file lists are not authenticated evidence. |
| Forged normalized warm/Kit inventory fed to the bridge Spike join | Each forged record produced the candidate `selectedBuildMember` verdict; duplicate normalized records produced `ambiguous`. | The pure join trusts its input by design; this is an acquisition-channel limit, not a production validator result. |
| Compact bridge inventory with nonexistent raw provenance paths | The artifact-only evaluator still exited 0 and reclassified its internally consistent JSON. | It does not authenticate discarded raw Xcode logs, as the bridge Spike already records. |

The [evidence-channel report](artifacts/evidence-channel-report.md), [probe script](artifacts/probe-evidence-channel.py), and [bounded results](artifacts/evidence-channel-results.json) preserve the controls. No production build-membership acquisition adapter exists. The evidence role did not establish that an actual Product script injected text into Xcode's parent output or raced a current-run file list.

Separate unprivileged build UID, root-owned source/mount topology, and VM isolation were **not tested**. `sudo -n true` required a password, so no privileged setup was attempted. Even source isolation by a different principal would not by itself authenticate logs or DerivedData written by the build process.

## Success Criteria

A candidate may enable strong `selectedBuildMember` only if the exact pinned source path/bytes remain unchangeable to Product executable steps throughout compilation; parent rename, symlink substitution, unmount/rebind, and helper-mediated changes fail; the executed invocation and its complete current-run source inventory come from a channel the Product process cannot forge; the selected build succeeds; and exact target/module/configuration/path/blob binding survives relocation. Attack attempts must fail closed. Pre/post hash equality alone is not success.

## Failure Criteria

If a same-UID Product step can substitute the logical source path or manufacture the text/file-list evidence, or if isolation prevents the selected build, the candidate cannot justify `sourceMaterializationProtected` or a production positive. An unavailable/unknown acquisition format yields `unverifiable` even when source protection succeeds.

## Result

**Confirmed / Measured:** Food Truck C1 built from a UDRO image; direct writes inside it failed. Same UID could unmount it or rename its mounted parent and rebind the original path to fake source bytes; the replay restored the original mount/blob. A disposable modified Product Run Script under Xcode's script sandbox touched the test parent and unmounted the image. The tested outer sandbox denied writes but blocked this Product build. Controlled scratch text, file lists, and normalized records could be forged/replaced and changed the Spike join's verdicts as documented.

**Inferred:** Neither tested same-UID UDRO/Xcode script sandbox nor the tested outer sandbox is a compatible, sufficient source-plus-evidence protection mechanism. A production adapter that trusted ordinary same-UID writable plain-text log/file-list bytes could false-positive. The source-path attacks demonstrate substitution capability, not a compiler-time attack trace; the evidence-channel attacks were controlled scratch forgeries, not observed malicious Product build output.

**Unknown / Blocked:** A protected compatible mechanism using a separate principal, root-owned topology, VM, or a trusted executed-invocation feed; behavior on other Product projects/toolchains; the performance and installation cost of those candidates. Privileged candidates were blocked by unavailable passwordless setup and were not attempted.

**Not implemented:** A production acquisition adapter, protected positive path, or Product CLI build-membership option.

## Conclusion

No candidate tested here protects **both** receipt-pinned source path/bytes and executed-invocation evidence while supporting this selected build. Keep `product-build-membership` at `Implementation Required`. Commit A's typed evidence/pure fail-closed join remains valid. Do not enable production `selectedBuildMember` from UDRO+hashes, Xcode script sandboxing, a generic `sandbox-exec` wrapper, ordinary Xcode text/file-list parsing, or a warm no-op build. The production boundary returns `unverifiable` until protected source and authenticated current-run inventory can be demonstrated. This Spike does not decide an isolation mechanism; a separate architecture decision is warranted only if multiple viable mechanisms create a material irreversible trade-off.

## Artifacts

- [Source-isolation report](artifacts/source-isolation-assessment.md), [source substitution replay](artifacts/source-substitution-replay.json), [replay script](artifacts/replay-source-substitution.py), and [script-build excerpt](artifacts/script-build-excerpt.txt).
- [Evidence-channel report](artifacts/evidence-channel-report.md), [probe script](artifacts/probe-evidence-channel.py), and [bounded results](artifacts/evidence-channel-results.json).
- Full disposable raw logs, images, and DerivedData were not committed; paths and reproducibility limits are recorded in the reports.
