# Capability granularity comparison

## Conditions

- macOS 27.0 (arm64), Swift 6.4; focused `swift test --filter CapabilityGranularitySpikeTests`.
- 14 scenario/profile/approval rows A–J, 33 semantic requirement observations. `oracle.json` was committed first at `0f2694f`. Initial extraction found D's real root Stack omitted from the oracle; it was corrected before candidate result measurement. Both versions remain in Git history.
- `macos27-host` represents the implemented runtime subset. iOS 15/16 and Android 15 rows are **framework feasibility probes**, not product Preview Host support declarations. The `approximation-probe` is intentionally artificial.
- The baseline TargetPlanner is given exact declarations for the fixture's visible node kinds and token; G uses an approximate overlay declaration. This isolates granularity; it does not assert that every target implementation has these capabilities.
- The production planner, capability declarations, Preview, generator, and Format are unchanged. Candidate registries, effects, extension, and four consumer adapters exist only in a Swift test.

## Counts

| Candidate | Registry profile/key entries | False positive requirements | False negative requirements | Consumer divergences | Silent approximations | Duplicate declarations | Entries edited for one-profile Button event change | Other Button requirements sharing that entry |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Node | 10 | 9 | 0 | 0 | 0 | 0 | 1 | 2 |
| Property | 24 | 3 | 0 | 0 | 0 | 0 | 1 | 1 |
| Semantic contract | 28 | 0 | 0 | 0 | 0 | 0 | 1 | 0 |

All registries use unique profile/key entries by construction. The 33 requirement observations include repeated keys across fixtures; these are lookups, not duplicate declarations. The change amplification column counts declarations and collateral semantic requirements, not source edit time.

Node false positives: product handler (Button and Toolbar), product binding, Apple symbol mapping on Compose, remote fetch, three ordered effects, and target extension on macOS. Property false positives: product handler (Button and Toolbar) and product binding. A more detailed property model could split these; once it identifies the independently lossy meaning, it converges toward the semantic contract model tested here. Zero false negatives is limited to this corpus.

The production TargetPlanner baseline passes seven oracle-blocked rows (B, C, D, Compose E, iOS 15 H, I, macOS J) with the fixture declarations. It rejects remote assets with `preview.asset` and unapproved approximation with `capability.approvalRequired`. It does not extract product handler, target runtime boundary, test-only effect, or test-only typed extension requirements. This is a capability reporting gap in the baseline, not a measured runtime execution failure.

The approved G row remains `approximate` with `approvedApproximation` in the candidate report. Four test-only Canvas / Native Host / Generator / AI adapters call one evaluator and show zero divergence. This establishes the architecture seam in the prototype; it does not validate production adapters.

## Decision evidence and limits

A requirement-granular semantic contract with explicit target/runtime profile is the only tested candidate satisfying the pre-registered hard gates: false positives = 0, consumer divergence = 0, silent approximation = 0. Registry size is 28 entries for this small corpus, versus 10 node entries; broader framework coverage and declaration maintenance cost remain implementation concerns. The prototype's mappings are test data, not a framework support promise.

Primary availability input for iOS 15/16 sheet detents: Xcode 27 iOS SDK SwiftUI interface marks `presentationDetents` available on iOS 16 and newer; [Apple documentation](https://developer.apple.com/documentation/swiftui/view/presentationdetents%28_%3A%29). Android [image documentation](https://developer.android.com/develop/ui/compose/graphics/images/loading) distinguishes Compose image display and resource/remote loading; the Apple symbol mapping row is a mapping obligation, not a claim that Compose cannot render images.

Machine-readable per-requirement results, approximation approval, profile, and current planner diagnostics are in [capability-matrix.json](capability-matrix.json). The fixed expected support is in [oracle.json](oracle.json).
