# Compiled input inventory Spike

## Related Decision

`adr/product-build-membership/ADR.md`: determine what evidence can establish that a pinned Product declaration belongs to a selected Product build. This Spike measures the Swift compiler input inventory for two pinned package schemes. It does not decide the ADR.

## Hypothesis

A selected Xcode package build exposes an arm64 Swift input list and compiler command that can be reconciled with exact Git blobs, while full build membership still depends on transitive build inputs outside that list.

## Questions

- Can the selected target and its package dependencies identify exact tracked Swift inputs from pinned clean Product commits?
- Are named declarations present in the selected compile inputs, and are unrelated targets absent from these particular builds?
- Does relocation preserve relative input sets and meaningful compiler settings?
- Which compiler, SDK, configuration, generated, resource, and dependency inputs remain outside a tracked Swift source list?

## Prototype Scope

Read-only Product checkouts:

| Product | Clean pinned HEAD | Tested scheme |
| --- | --- | --- |
| Team MINO | `dca2202f4be21869190d19bbcf223eb8646a2acd` | `Packages/FeatureProfile`, scheme `FeatureProfile` |
| Apple Food Truck | `3954a769e99f3cc53297d94f2b960ceb2665b3d6` | `FoodTruckKit`, scheme `FoodTruckKit` |

For each, `git archive HEAD` materialized exactly the selected package and local package dependencies in a unique `/tmp/hamii-build-membership-bhl5yqv0` directory. The same tree was independently archived at a second path. Each archive was built once:

The archive inputs were exactly:

```sh
git -C /tmp/hamii-integration-spike/targets/team-mino archive HEAD Packages/Domain Packages/FeatureProfile Packages/FlowCoordination Packages/MVI Packages/DesignSystem Packages/ProfileSetupUI
git -C /tmp/hamii-integration-spike/targets/food-truck archive HEAD FoodTruckKit
```

Each command's tar output was extracted beneath `<scratch>/mino` or `<scratch>/food`, then repeated beneath `<scratch>/relocated-mino` or `<scratch>/relocated-food`. The current working directory for the builds was the archived `Packages/FeatureProfile` or `FoodTruckKit` directory respectively. Only those package trees were included; the Product app projects were not built.

```sh
xcodebuild build -scheme FeatureProfile -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/hamii-build-membership-bhl5yqv0/MinoDD CODE_SIGNING_ALLOWED=NO
xcodebuild build -scheme FoodTruckKit -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/hamii-build-membership-bhl5yqv0/FoodDD CODE_SIGNING_ALLOWED=NO
```

The relocated builds used the same commands with `RelocatedMinoDD` and `RelocatedFoodDD` and their respective second archive paths. Xcode resolved local packages from the archive; no Product checkout, Git metadata, or hamii production file was changed. Pre/post `git --no-optional-locks status --porcelain=v2 --untracked-files=all` was empty for both Product checkouts. The inventory procedure and counts are recorded below. Raw build logs and DerivedData remain in `/tmp`; they are not repository artifacts.

For each measured module, the arm64 `*.SwiftFileList` referenced by `builtin-SwiftDriver` was normalized from the archive path to a Product-root-relative path. Its tracked `.swift` entries were compared to `git ls-tree -r --name-only HEAD`; each archived file's `git hash-object --no-filters` OID was compared with `HEAD:<path>`. Generated Swift inputs were counted separately. The same comparison ran on both archive locations.

The comparison used the compiler's `@.../<module>.SwiftFileList` argument, not a recursive filesystem scan as a substitute for build input. The latter was used only to check whether each listed regular tracked source belonged to the pinned Git tree. This does not enumerate non-Swift transitive compiler inputs.

## Out of Scope

Full iOS app or Widget schemes; Release builds; all destination architectures and build configurations; remote package resolution; runtime behavior, reducer or route semantics, resources in a selected bundle, patch publication, and a production build-membership validator. This is a package-scheme experiment, not proof about every Product target.

## Measurements

Environment: Xcode 27.0 (`27A266a`), Apple Swift 6.4 (`swiftlang-6.4.0.34.1`), iPhoneSimulator27.0 SDK. The measured arm64 commands used `arm64-apple-ios17.0-simulator` and Swift mode 6 for Team MINO; `arm64-apple-ios16.4-simulator` and Swift mode 5 for FoodTruckKit. They also contained `SWIFT_PACKAGE`, `DEBUG`, `-explicit-module-build`, module and index store paths, a compiler plugin path, SDK path, and target module name. The tested configuration was Debug iOS Simulator.

| Measured module | Arm64 SwiftFileList entries | Tracked Swift blobs matched | Generated Swift entries |
| --- | ---: | ---: | --- |
| Team MINO `Domain` | 88 | 88 | 0 |
| Team MINO `FeatureProfile` | 7 | 7 | 0 |
| Team MINO `ProfileSetupUI` | 4 | 4 | 0 |
| Team MINO `FlowCoordination` | 3 | 3 | 0 |
| Team MINO `MVI` selected target | 2 | 2 | 0 |
| Team MINO `DesignSystem` | 57 | 55 | 2 |
| Food `FoodTruckKit` | 32 | 30 | 2 |

All listed tracked inputs had matching Git blob OIDs; none of those listed paths was missing from the pinned tree. This comparison did not establish that the file list contains every file the target could compile under other settings. The generated entries were `resource_bundle_accessor.swift` and `GeneratedAssetSymbols.swift` in `DesignSystem` and `FoodTruckKit`. Their generated bytes and upstream resource inputs were not pinned by this comparison.

Positive compile-log observations: Team MINO `Packages/Domain/Sources/Domain/Entities/Profile.swift` compiled in `Domain`, and `Packages/FeatureProfile/Sources/FeatureProfile/ProfileCoordinator.swift` compiled in `FeatureProfile`; Food Truck `FoodTruckKit/Sources/Account/User.swift` and `AccountStore.swift` compiled in `FoodTruckKit`. Negative observations are bounded to the tested schemes: Team MINO `FeatureHome` had no SwiftFileList or compile command in the `FeatureProfile` build; Food Truck `App` and `Widgets` had none in the `FoodTruckKit` package build. Those targets were not selected or built here.

| Scheme | First archive | Relocated archive | Trials |
| --- | ---: | ---: | ---: |
| FeatureProfile | 18.01 s | 16.10 s | one per location |
| FoodTruckKit | 26.71 s | 25.99 s | one per location |

All four builds exited 0. For every module in the table, the relative tracked input set matched across locations. After replacing only archive and DerivedData roots, the measured arm64 `builtin-SwiftDriver` command lines for `Domain`, `FeatureProfile`, and `FoodTruckKit` were exactly equal. Absolute paths in raw commands and source locations did change. The times are local single trials, not an SLA or benchmark distribution.
Each trial had its own DerivedData path; system SDK and compiler caches may still have been warm. These measurements do not isolate cold versus warm system-cache cost.

## Success Criteria

The selected package builds succeed; compiler file lists identify positive and negative selected targets; every listed tracked Swift input matches an exact pinned Git blob; relocation retains the relative input sets and compiler conditions.

## Failure Criteria

A build fails, an input is not traceable to its pinned Git blob, a tracked input changes with relocation, or the compiler command omits the selected module/configuration evidence. Any such result would prevent a positive membership inference for this prototype.

## Result

The success criteria held for the measured arm64 package builds. The compiler input list provides evidence that specific pinned Swift blobs entered the selected package module compilation. It is not a complete inventory of all inputs that determine compiled symbols. The package manifests, dependent modules, compiler and SDK, build flags, resource catalogs, generated Swift sources, compiler plugins, and module caches are separate inputs or outputs. A source file can also be compiled while a conditional declaration inside it is inactive.
This Spike did not test the **same tracked path** as both included and excluded under different selected targets or configurations; that Required Evidence remains open in the ADR. It also did not run stale-commit, changed-blob, incomplete-inventory, or ambiguous-target rejection probes.

## Conclusion

**Observed:** exact Git blob binding is feasible for the selected tracked Swift inputs in these two package builds; relative file lists and sampled compiler commands survived relocation. **Inferred:** a future selected-build membership receipt would need a normalized build-target identity and a transitive input/toolchain closure, not only a path or SwiftFileList. **Unknown:** a stable portable Xcode build-plan contract, complete generated/resource dependency capture, app and Widget target behavior, other configurations or architectures, and whether such a receipt can be replayed independently. This Spike supports further ADR evaluation but does not establish a general Product build-membership validator.

## Artifacts

No committed artifact is needed beyond the measurements in this Spike. Temporary raw evidence is under `/tmp/hamii-build-membership-bhl5yqv0/` (build logs, source archives, and DerivedData); it is not committed.
