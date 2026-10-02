# Source to selected build bridge Spike

## Related Decision

[`Product Build Membership Evidence`](../../ADR.md): can a receipt-pinned Swift direct declaration's exact tracked source path/blob be linked to an executed compiler input of an explicitly selected Product build? This Spike gathers evidence for that narrow question. It does not select a production validator design.

## Hypothesis

A production `pinnedSourceDeclaration` observation and a successful selected Swift compiler invocation can be joined when they name the same Product commit and exact tracked path/blob **and** the selected target and module are explicit. Build success alone, omitted module identity, and a warm build with no executed invocation cannot establish the same fact.

## Questions

- Can a production Profile v2 receipt and source evidence be generated for a direct declaration in a pinned Product commit without changing Product source/project bytes?
- Does that same commit's selected app invocation consume the exact tracked source blob? Does an explicit nonmember module reject it?
- What happens when the module is omitted, the build is warm, the Product commit changes, or Xcode silently resolves another configuration?
- Can the observations be repeated after relocating an exact archive and the scratch commits be restored from compact evidence?

## Prototype Scope

The base is Apple Food Truck commit `3954a769e99f3cc53297d94f2b960ceb2665b3d6`. A disposable child Product commit **C1** `3cf70a8775a8d528d27b560185ed6d1116557b99` adds only the 553-byte tracked Profile v2 `config/hamii-profile.json` (blob `ddd35c473a7b4d59cd45e155b69340d8fcd564c0`). The Product source and Xcode project bytes remain unchanged. `App/General/FlowLayout.swift` stays blob `92c12dc1f8ed077e2384d99792310648b9c8f718`. The synthetic hamii fixture requires only `input:probe.flowSpacing`, located at top-level `struct FlowLayout` / direct stored property `spacing`. This mapping tests the evidence chain; it makes no Product semantic or type-compatibility claim.

Three independent roles produced raw artifacts: source/receipt used the production `integration plan` CLI without build results; build inventory used exact C1 archives without source receipt results; an independent evaluator joined only the resulting artifacts and checked raw CLI/Git/build records. All Product builds ran in disposable `/tmp` archives with separate DerivedData, not in the original Product checkout. The selected build was `Food Truck All`, Debug, generic iOS Simulator, arm64, `CODE_SIGNING_ALLOWED=NO`, Xcode 27.0 (`27A266a`), Apple Swift 6.4 (`swiftlang-6.4.0.34.1`), iPhoneSimulator27.0 SDK. A separate disposable **C2** `4050d4f2c5e7bf357e4b82af4ef39a1ad9c7ed1b` changes only the FlowLayout source blob to `4be14546d1369f767c2c6a64284aef039acb37ee` for a real stale-commit control.

## Out of Scope

Production selected-build validator or output schema, full transitive/hermetic build closure, conditional declaration compilation, Product mapping semantics, runtime behavior, Product patch permission, other Xcode versions/platforms/configurations, and cold/warm latency distributions. The `SwiftFileList`/log parser and join evaluator are Spike tools, not a supported Xcode interface or production code.

## Measurements

The production CLI exited 0 for C1 and returned one `repositoryMappingEvidence` entry for `input:probe.flowSpacing`: `verified`, scope `pinnedSourceDeclaration`, source blob `92c12dc1f8ed077e2384d99792310648b9c8f718`, line 12. Its `RepositoryProfileReceipt.productCommitOID` is exactly C1 and its Profile blob matches C1's tracked tree. There were no resolution issues or blocked outputs.

| Build trial | Commit | `BUILD SUCCEEDED` | Executed arm64 SwiftDriver invocations | Wall time | FlowLayout tracked input |
| --- | --- | --- | ---: | ---: | --- |
| fresh C1 | C1 | yes | 3 | 33.24 s | `Widgets` and `Food_Truck_All`, C1 blob |
| warm C1, same DerivedData | C1 | yes | 0 | 2.35 s | no new compiler observation |
| relocated fresh C1 | C1 | yes | 3 | 28.81 s | same modules and C1 blob |
| fresh C2 | C2 | yes | 3 | 29.95 s | same modules, changed C2 blob |

Each row is one trial. These timings describe this machine and these archives; they are not p95 values or a Product performance guarantee. First and relocated C1 had equal relative Swift input records and normalized invocation-command hashes for all three selected modules. Every tracked input in the fresh C1 inventory matched its C1 Git blob. Generated DerivedData Swift inputs were classified separately; no external or untracked Swift source input was observed in these trials. The `FoodTruckKit` invocation did not contain `FlowLayout.swift`.

The independent join produced six **real-observation** outcomes:

| Observation | Outcome | Reason |
| --- | --- | --- |
| C1 receipt + explicit `Food Truck All` / `Food_Truck_All` invocation | `selectedBuildMember` candidate | exact C1, path, blob and selected app module input |
| C1 receipt + relocated C1 app invocation | `selectedBuildMember` candidate | same normalized descriptor and input identity |
| C1 receipt + explicit `FoodTruckKit` invocation | `missingFromSelection` | source absent from that module |
| C1 receipt + module/owner target omitted | `ambiguous` | source occurs in both `Widgets` and app invocations |
| C1 receipt + actual C2 invocation | `staleProduct` | commit mismatch rejected **before** comparing source blobs |
| C1 receipt + successful warm C1 build | `unverifiable` | no executed compiler invocation |

Two Xcode controls were observed separately: nonexistent scheme exited 65 with no SwiftDriver invocation; requesting `NoSuchConfig` from `-showBuildSettings` exited 0 while resolving `Release`. A future validator must compare requested and resolved configuration. Eight additional **synthetic classifier controls** checked wrong blob (`mismatchedSource`), missing inventory, failed build, unknown configuration fallback, generated-only target, outside-root symlink target, and unknown target (`unverifiable`), plus conflicting duplicate logical source (`ambiguous`). Synthetic outcomes are not production validator behavior or observed build failures.

The two small incremental Git bundles were verified and replayed in a fresh clone that already had the exact base commit. C1 bundle is 795 bytes; C2 bundle is 691 bytes and requires C1. Neither bundle contains the full upstream Product tree. The original Product checkout and both scratch Product clones were clean after these trials.
The committed compact inventory supports deterministic reclassification and internal consistency checks, but it cannot independently authenticate the original Xcode logs or Git bytes after the disposable raw logs are gone. Rebuilding the restored Product commits is required to remeasure that provenance boundary.

## Success Criteria

The production Profile v2 path issues a C1-pinned `pinnedSourceDeclaration` for the direct property; a successful fresh selected app invocation contains its exact path/blob; explicit nonmember module, omitted module, C2 commit, and warm no-op build do not produce positive membership; relocation preserves the positive result; generated inputs and synthetic controls remain separately classified.

## Failure Criteria

A source receipt tied to a different commit, a changed or untracked target blob, an unsuccessful build, an unavailable executed invocation inventory, a requested/resolved configuration mismatch, or a missing/ambiguous selected module would prevent this narrow positive result. A positive claim based only on build success or a past compiler input list would fail this Spike.

## Result

The measured success criteria held for the specified C1/C2 fixtures and build descriptor. The independent evaluator reproduced two positive and four rejecting real joins. Its eight synthetic classifier cases rejected or marked ambiguous as specified. The production source validator was exercised; **the build-side join is a Spike evaluator, not production implementation**. A warm successful build ran no SwiftDriver invocation, so it did not produce fresh membership evidence.

## Conclusion

**Observed:** a production receipt-pinned direct declaration can be linked by exact Product commit/path/blob to a selected executed app compiler source input in this fixture. The same source is absent from an explicit selected `FoodTruckKit` module and ambiguous without a module. Relocation preserved the result; a C2 commit and a warm no-op build failed closed in the independent join. **Inferred:** an additive `selectedBuildMember` scope could use an executed selected Swift invocation and exact tracked source binding; static metadata and build success alone cannot authorize a positive result. **Unknown:** a supported, durable production acquisition contract for selected Swift invocation inventories, cache/no-op handling, and behavior across other toolchains or Product targets. This Spike does not decide the ADR or implement the validator.

## Artifacts

- [source CLI output](artifacts/source-cli-output.json), [source receipt/evidence](artifacts/source-evidence.json), [Profile v2 fixture](artifacts/profile-v2.json), and [hamii fixture creator](artifacts/create-hamii.swift).
- [build inventory](artifacts/build-inventory.json) records selected invocations, exact target source inputs, generated inputs, descriptors, controls and timings. Full raw build logs and DerivedData were left in disposable `/tmp/hamii-bridge-build-5_rduf7f/` and are not committed.
- [independent join results](artifacts/join-results.json), [join evaluator](artifacts/join.py), [artifact adapter](artifacts/evaluate.py), and [synthetic self-test](artifacts/selftest.py) distinguish observed joins from synthetic controls.
- [C1 incremental bundle](artifacts/food-truck-profile-c1.bundle), [C2 incremental bundle](artifacts/food-truck-source-c2.bundle), [bundle replay record](artifacts/bundle-preservation.json), and [reproduction instructions](artifacts/REPRODUCTION.md). The bundles require the exact pinned upstream base commit; future availability of that upstream object from its remote was not tested.
