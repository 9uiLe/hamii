# Product compiler cross-check (2026-10-02)

This is a narrow, read-only cross-check for the typed-locator Spike. It uses **actual Product package module names** from exact pinned Git source, not a scratch `Probe` module. Machine-readable OIDs, USRs, kinds, source lines, comparisons, and sample times are in [compiler-crosscheck.json](compiler-crosscheck.json). All build output stayed under a unique `/tmp/hamii-typed-locator-crosscheck-*` directory; neither Product checkout nor hamii production source was edited.

## Input and method

- Team MINO iOS: clean HEAD `dca2202f4be21869190d19bbcf223eb8646a2acd`. `git archive HEAD` materialized the exact `Packages/{Domain,FeatureProfile,FlowCoordination,MVI,DesignSystem,ProfileSetupUI}` trees into scratch. The Product `Package.swift` manifests name the built modules `Domain` and `FeatureProfile`. `xcodebuild build -scheme FeatureProfile -destination 'generic/platform=iOS Simulator' -derivedDataPath <scratch> CODE_SIGNING_ALLOWED=NO` succeeded. This compiles `Domain` as a package dependency. A second archive at another absolute path built `Domain` and `FeatureProfile` again.
- Apple Food Truck: clean HEAD `3954a769e99f3cc53297d94f2b960ceb2665b3d6`. `git archive HEAD FoodTruckKit` materialized its real package. `xcodebuild build -scheme FoodTruckKit -destination 'generic/platform=iOS Simulator' -derivedDataPath <scratch> CODE_SIGNING_ALLOWED=NO` succeeded. An independent **clean local `git clone --shared`** at the same commit built `FoodTruckKit` again at another path. The clone shares its source object store; this is not evidence for a self-contained network clone.
- Each selected file was checked with `git ls-tree -r --full-tree -z <commit> -- <exact path>` for exactly one mode `100644` blob, read by `git cat-file blob <OID>`, and compared byte-for-byte with the archived file. The five Git blob OIDs and SHA-256 values are recorded in JSON. Pre/post status of both original Product checkouts remained empty; status used `--no-optional-locks`.
- Xcode 27.0 (27A266a), Apple Swift 6.4, iPhoneSimulator27.0 SDK, arm64 iOS Simulator. Team MINO package builds used Swift 6 mode and target `arm64-apple-ios17.0-simulator`; FoodTruckKit used Swift 5 mode and `arm64-apple-ios16.4-simulator`. Build logs also show `SWIFT_PACKAGE` and `DEBUG`. `xcrun swift-symbolgraph-extract -module-name <actual module> -I <scratch products> -F <scratch products> -sdk <iPhoneSimulator27.0.sdk> -target <matching target> -minimum-access-level internal -output-dir <scratch graph>` read those compiled modules. Graph source positions are zero based; the lines below are one based.

## Confirmed graph identities

| Product source declaration | Actual module / graph kind | Precise compiler ID (USR) |
| --- | --- | --- |
| Team MINO `Packages/Domain/Sources/Domain/Entities/Profile.swift:10` `Profile.nickname` | `Domain` / `swift.property` | `s:6Domain7ProfileV8nicknameSSvp` |
| Same file `:12` `Profile.createdAt: Date?` | `Domain` / `swift.property` | `s:6Domain7ProfileV9createdAt10Foundation4DateVSgvp` |
| Team MINO `Packages/FeatureProfile/Sources/FeatureProfile/Main/ProfileMainStore.swift:83` `ProfileMainAction.tapEditProfile` | `FeatureProfile` / `swift.enum.case` | `s:14FeatureProfile0B10MainActionO07tapEditB0yA2CmF` |
| Same file `:94` `ProfileMainNav.pushProfileSetup` | `FeatureProfile` / `swift.enum.case` | `s:14FeatureProfile0B7MainNavO04pushB5SetupyA2CmF` |
| Team MINO `Packages/FeatureProfile/Sources/FeatureProfile/ProfileCoordinator.swift:11` `ProfileRoute.profileSetup` | `FeatureProfile` / `swift.enum.case` | `s:14FeatureProfile0B5RouteO12profileSetupyA2CmF` |
| Food Truck `FoodTruckKit/Sources/Account/User.swift:10` `User.authenticated(username:)` | `FoodTruckKit` / `swift.enum.case` | `s:12FoodTruckKit4UserO13authenticatedyACSS_tcACmF` |
| Food Truck `FoodTruckKit/Sources/Account/AccountStore.swift:39` `AccountStore.currentUser` | `FoodTruckKit` / `swift.property` | `s:12FoodTruckKit12AccountStoreC11currentUserAA0G0OSgvp` |

The `AccountStore` file is guarded by `#if os(iOS) || os(macOS)`. Its property is present in this **iOS Simulator build**, which resolves the earlier lexical/parse-only uncertainty for this configuration. It does not establish presence under every Product configuration. The Team MINO action and route are compiled enum cases; graph identity does not prove the reducer sends that action, the coordinator handles it, or the destination works at runtime.

The second location produced exactly equal `(pathComponents, kind, USR)` sets for `Domain` **566/566**, `FeatureProfile` **1851/1851**, and `FoodTruckKit` **5991/5991** graph symbols. Graph `location.uri` contains each scratch absolute path and changes with relocation; the URI itself is not portable locator authority. Matching identities here depend on the same module names, compiler, SDK, target, flags, and source.

## Cost and failure observations

One local trial per build: initial FeatureProfile build (including dependencies) about **27.9 s**; initial FoodTruckKit build about **27.7 s**; relocated Domain **6.2 s**, FeatureProfile **16.1 s**, FoodTruckKit **27.1 s**. First graph extractions took Domain **26.636 s**, FeatureProfile **19.596 s**, FoodTruckKit **6.846 s**, reflecting cold compiler/SDK/cache effects. Three subsequent warm graph extractions took Domain **0.120/0.111/0.108 s**, FeatureProfile **0.284/0.277/0.287 s**, and FoodTruckKit **0.735/0.575/0.604 s**. These are local wall times, not an end-to-end validator benchmark or an SLA.

Without the compiled `FeatureProfile.swiftmodule`, the same extractor with an empty `-I` search path exited **1** with `Couldn't load module 'FeatureProfile' in the current SDK and search paths.` No IndexStore reader was run here. The measurements establish symbol-graph identity, not a build-free index lookup. No iOS app target or UI/runtime test was run in this cross-check.

## Boundary and unresolved checks

**Confirmed:** these seven direct Product declarations have compiler kind and USR in the named modules/configurations, and the selected source locations refer to bytes identical to regular blobs in the pinned commits. Exact relocation held their compiler IDs stable in the measured setting. The Food Truck result is an actual Product package module, unlike the earlier `FoodTruckProbe` standalone module.

**Unknown:** stability across Swift/Xcode/SDK or target/configuration changes; private/local/macro-generated declaration coverage; whether a production resolver can verify *all transitive compiler inputs* came from the pinned Git tree; end-to-end lookup cost; asset-catalog, token-resource, and native-capability identity; and Product action/route behavior. The graph's `location.uri` points into scratch and cannot by itself authenticate the original repository. A production verifier still needs a pinned commit/blob guard, exact module/build context, and typed non-Swift evidence or explicit unsupported results.
