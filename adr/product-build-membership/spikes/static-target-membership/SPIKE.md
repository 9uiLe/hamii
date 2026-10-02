# Spike: Static Product target membership

## Related Decision

[Product Build Membership](../../ADR.md). This Spike tests how far pinned Swift Package manifests and an Xcode project can support a selected target/configuration membership claim before inspecting actual compiler inputs.

## Hypothesis

Pinned project metadata can identify declared source-phase membership and predict active Swift conditions for a selected target. It cannot alone prove that the compiler consumed those exact bytes, or that a declaration survived condition evaluation in an executed build.

## Questions

- Do the pinned Team MINO and Food Truck manifests/projects provide both positive and negative target-membership controls?
- Can one pinned Food Truck source file predict different declaration membership under two selected target/configuration settings?
- Which additional evidence is needed to move from a static prediction to an actual Product compiler-input claim?

## Prototype Scope

One read-only inspection pass over clean local Product repositories at exact commits: Team MINO `dca2202f4be21869190d19bbcf223eb8646a2acd` and Apple Food Truck `3954a769e99f3cc53297d94f2b960ceb2665b3d6`. Sources were checked with `git rev-parse HEAD`, `git status --porcelain`, `git ls-tree`, and `rg`/`sed` on the clean pinned checkouts. No Product build, generated project, compiler index, or source mutation was performed. These are static observations, not a production resolver.

## Out of Scope

Running Xcode/SwiftPM, resolving every inherited build setting, macro/plugin-generated sources, transitive dependencies, iOS runtime behavior, asset processing, patching, or verifying compiler inputs from a build log. No hamii production code was edited.

## Measurements

Reproducible read-only commands (replace `ROOT` only with a clean checkout of the stated SHA):

```sh
git -C /tmp/hamii-integration-spike/targets/team-mino rev-parse HEAD
git -C /tmp/hamii-integration-spike/targets/team-mino status --porcelain
git -C /tmp/hamii-integration-spike/targets/team-mino ls-tree -r --full-tree dca2202f4be21869190d19bbcf223eb8646a2acd -- Packages/FeatureProfile/Sources/FeatureProfile/Main/ProfileMainStore.swift Packages/FeatureProfile/Tests/FeatureProfileTests/ProfileMainReducerTests.swift
sed -n '1,35p' /tmp/hamii-integration-spike/targets/team-mino/Packages/FeatureProfile/Package.swift
git -C /tmp/hamii-integration-spike/targets/food-truck rev-parse HEAD
git -C /tmp/hamii-integration-spike/targets/food-truck status --porcelain
git -C /tmp/hamii-integration-spike/targets/food-truck ls-tree -r --full-tree 3954a769e99f3cc53297d94f2b960ceb2665b3d6 -- App/Account/AccountView.swift App/Navigation/Sidebar.swift 'Food Truck.xcodeproj/project.pbxproj' FoodTruckKit/Package.swift
rg -n 'AccountView.swift in Sources|Sidebar.swift in Sources|SWIFT_ACTIVE_COMPILATION_CONDITIONS|PBXSourcesBuildPhase' '/tmp/hamii-integration-spike/targets/food-truck/Food Truck.xcodeproj/project.pbxproj'
sed -n '465,510p;603,705p;756,844p;895,907p;966,1050p;1127,1155p' '/tmp/hamii-integration-spike/targets/food-truck/Food Truck.xcodeproj/project.pbxproj'
sed -n '12,35p' /tmp/hamii-integration-spike/targets/food-truck/App/Navigation/Sidebar.swift
sed -n '20,34p' /tmp/hamii-integration-spike/targets/food-truck/FoodTruckKit/Package.swift
```

Both `status --porcelain` outputs were empty. All named inputs were tracked regular `100644` blobs. Selected OIDs: Team MINO `ProfileMainStore.swift` `3538d4e7ffd38b7ce877a6fc70725fd36c94bb1e`, `ProfileMainReducerTests.swift` `289b7314575de562c8b40f0f8fbe5a3f8e40e32f`; Food Truck `AccountView.swift` `71acb5926563e001db78556752be10d75a7b9279`, `Sidebar.swift` `2a2ab91bfe71690dd0d773af080f9a528113bea9`, project file `c19cfb6280904406c1cdbde34c92969dd6035fce`. One inspection pass was made. Lookup timing and build cost were not measured.

| Pinned fixture | Static positive | Static negative | What was actually observed |
| --- | --- | --- | --- |
| Team MINO SwiftPM library vs tests | `Packages/FeatureProfile/Package.swift:8,17-21` declares library target `FeatureProfile`; `Sources/FeatureProfile/Main/ProfileMainStore.swift` is in its conventional source tree. | `Package.swift:22-27` declares separate `FeatureProfileTests`; `Tests/FeatureProfileTests/ProfileMainReducerTests.swift` is in that test tree, outside the library's conventional source tree. | Target definitions and paths. The manifest does **not** list individual Swift source files, so exact per-file membership is a SwiftPM-default-layout **inference**, not an observed compiler input. |
| Food Truck Xcode app targets | `Food Truck All` target references Sources phase `E0510734` (`project.pbxproj:469-485,604-653`), whose list contains `App/Account/AccountView.swift` via build-file ID `E0510761` (`:49,650`). | Normal `Food Truck` target references Sources phase `E0C37BBD` (`:491-510,655-704`); `AccountView.swift` has no entry in that phase. | Explicit PBX target→phase→build-file relationship. This is declared source-phase membership and absence, not proof of a completed compile. |
| Food Truck selected configuration, same source blob | `Sidebar.swift` is listed in both app Sources phases (`project.pbxproj:640,696`). `Panel.account` is in `#if EXTENDED_ALL` (`App/Navigation/Sidebar.swift:19-22`). `Food Truck All` Debug/Release set `EXTENDED_ALL` (`project.pbxproj:794,838`). | Normal `Food Truck` target Debug/Release settings (`project.pbxproj:966-1048`) have no `EXTENDED_ALL` override; project Debug sets only `DEBUG` (`:903`), and `Configuration/SampleCode.xcconfig` has no active-compilation-condition entry. | Static settings **predict** `Panel.account` in All and not in normal target for the selected configurations. We did not execute either app build or inspect its compiler arguments. |
| Food Truck package vs app | `FoodTruckKit/Package.swift:20-32` declares library target `FoodTruckKit` at `Sources`; `FoodTruckKit/Sources/Account/User.swift` is inside that path. | `App/Account/AccountView.swift` is outside that package target path. | Manifest path scope; actual package compile membership still requires SwiftPM expansion/compiler evidence. |

The earlier Product compiler cross-check built the real Team MINO `FeatureProfile` and Food Truck `FoodTruckKit` package modules and found selected declaration identities. It did not build either Food Truck app target, so it does not convert the All-versus-normal app predictions above into observed compiler membership. A separate same-byte conditional fixture compiled with and without `-D PRODUCT_FEATURE` and produced different properties; that establishes the *language* condition effect, not this app's selected settings.

## Success Criteria

At least one positive and negative target or configuration fixture in pinned Product metadata, with exact target/phase/configuration edges and source blobs; no static result described as an actual compiler-input proof.

## Failure Criteria

A project-file name occurrence is treated as target membership without following target→phase→build-file edges; inherited settings are assumed without checking project/xcconfig; or a conditional source occurrence is called compiled Product evidence without an executed selected build.

## Result

**Observed:** Team MINO declares separate library and test targets; the selected files occupy their conventional source/test trees. Food Truck declares two app targets with different explicit Sources phase membership for `AccountView.swift`; both phases include `Sidebar.swift`. The All target configurations set `EXTENDED_ALL`; the normal target's inspected settings do not. All evidence files are regular blobs at the pinned clean commits.

**Inferred:** SwiftPM default discovery would place `ProfileMainStore.swift` in the library target and `ProfileMainReducerTests.swift` only in its test target. Food Truck All should compile `Panel.account`, while normal Food Truck should not, under the inspected configurations. These inferences depend on actual manifest/project evaluation, inherited settings, selected SDK/flags, and whether the build ran as expected.

**Unknown:** Exact executed compiler input lists for the selected app targets; CLI/environment build-setting overrides; generated/plugin/script inputs; every transitive module source; whether all compiler inputs are regular blobs from the pinned commit; and actual Food Truck app symbol presence under each configuration. `swift package --package-path <Team-MINO/Packages/FeatureProfile> describe --type json` and `xcodebuild -project 'Food Truck.xcodeproj' -target 'Food Truck All' -configuration Debug -sdk iphonesimulator -showBuildSettings` (plus the normal target) would expand some static metadata, but still would not prove an executed Swift compile. A scratch DerivedData build with recorded Swift driver inputs and matching Product symbol evidence would test that stronger claim.

## Conclusion

Pinned static metadata provides reviewable planned target membership and a concrete positive/negative configuration matrix. It cannot by itself establish a Product compiler-input or compiled-symbol claim. The Product Build Membership decision still needs selected-build evidence or a deliberately weaker, explicitly named static-membership scope.

## Artifacts

No additional artifact files. The exact pinned Git blob OIDs, commands, file locations, and one-pass observations are recorded above; no generated output was retained.
