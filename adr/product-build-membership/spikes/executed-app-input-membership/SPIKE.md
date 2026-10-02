# Executed app input membership Spike

## Related Decision

`adr/product-build-membership/ADR.md`: what evidence can establish that an exact pinned tracked Swift source path/blob participated in an explicitly selected Product target/module/configuration compiler invocation? This Spike tests the same Food Truck source path under two real app schemes. It does not decide the ADR or claim declaration-level conditional compilation.

## Hypothesis

An executed, successful `SwiftDriver` invocation and its `SwiftFileList`, checked against the pinned Git blob, can distinguish `App/Account/AccountView.swift` as an input of `Food Truck All` and absent from the normal `Food Truck` build under otherwise matching selected build settings.

## Questions

- Does `AccountView.swift` enter an executed compiler invocation for `Food Truck All`, and is it absent from **all** executed Swift invocations for `Food Truck`?
- Do the Swift input paths and bytes match the pinned clean Product Git commit, including at relocated archive paths?
- Which inputs are generated, untracked, or outside the Product archive, and what claim remains unsupported?
- Does `Sidebar.swift` demonstrate the boundary between file membership and conditional declaration membership?

## Prototype Scope

Apple Food Truck checkout `/tmp/hamii-integration-spike/targets/food-truck` was clean before and after the experiment (`git --no-optional-locks status --porcelain=v2 --untracked-files=all` returned empty) at exact HEAD `3954a769e99f3cc53297d94f2b960ceb2665b3d6`. The committed shared schemes are `Food Truck.xcodeproj/xcshareddata/xcschemes/Food Truck All.xcscheme` and `Food Truck.xcscheme`; their build actions select distinct app targets. The full `git archive HEAD` tar stream was extracted independently to four unique paths under `/tmp/hamii-app-membership-wte59r03/{all,normal,relocated-all,relocated-normal}`. Each archive contains the same pinned Git tree. All builds and DerivedData stayed in `/tmp`; the original Product checkout was never built or edited.

The exact build invocation, run from each archive root, was:

```sh
xcodebuild build -project 'Food Truck.xcodeproj' \
  -scheme 'Food Truck All' \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/hamii-app-membership-wte59r03/all-DerivedData \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO
```

The other three trials changed only the scheme (`Food Truck` for `normal` and `relocated-normal`), archive working directory, and independent DerivedData path. No app was launched. Xcode 27.0 (`27A266a`), Apple Swift 6.4 (`swiftlang-6.4.0.34.1`), iPhoneSimulator27.0 SDK, Debug, and arm64 iOS Simulator were common conditions. Both app compiler commands used Swift language mode 5 and target triple `arm64-apple-ios16.4-simulator`. Target-defined conditions differed as expected: `Food_Truck_All` had `DEBUG` and `EXTENDED_ALL`; `Food_Truck` had `DEBUG`. The module names and `EXTENDED_ALL` are part of the selected target identity, not normalization noise.
Matching `-showBuildSettings` probes with the same scheme/configuration/SDK/architecture overrides resolved `CONFIGURATION = Debug`, `ARCHS = arm64`, and the respective app target names and conditional defines. The actual build logs, rather than settings alone, supplied the executed compiler evidence.

## Out of Scope

Full transitive build reproducibility, compiler-cache state, Release/device/other architecture builds, running either app, resource or runtime semantics, patch publication, and proof that a declaration inside a compiled file survives conditional compilation. The `SwiftFileList` and successful compile trace establish only tracked **file input membership** for these selected invocations.

## Measurements

Each trial produced `** BUILD SUCCEEDED **`, one arm64 `builtin-SwiftDriver` invocation for each of three selected modules (`Food_Truck_All` or `Food_Truck`, `Widgets`, `FoodTruckKit`), and three corresponding arm64 `*.SwiftFileList` files. The app invocation's `@...SwiftFileList` argument was read directly; independent `SwiftCompile normal arm64` log rows checked the file-level execution trace. All three lists in every trial were scanned for `AccountView.swift`, not only the app list.

| Trial | App target/module | App tracked / generated Swift inputs | AccountView in all selected lists / SwiftCompile | Sidebar in app list / SwiftCompile | Time |
| --- | --- | ---: | --- | --- | ---: |
| `all` | `Food Truck All` / `Food_Truck_All` | 44 / 1 | 1 / yes | yes / yes | 33.07 s |
| `normal` | `Food Truck` / `Food_Truck` | 43 / 1 | 0 / no | yes / yes | 28.74 s |
| `relocated-all` | `Food Truck All` / `Food_Truck_All` | 44 / 1 | 1 / yes | yes / yes | 28.95 s |
| `relocated-normal` | `Food Truck` / `Food_Truck` | 43 / 1 | 0 / no | yes / yes | 28.75 s |

The **only** app tracked-input difference between the two selected schemes was `App/Account/AccountView.swift`. It is one regular `100644` pinned Git blob, `71acb5926563e001db78556752be10d75a7b9279`. The archived bytes hashed with `git hash-object --no-filters` to that OID at both All locations. The successful All build log contained the target-owned `SwiftCompile normal arm64 .../App/Account/AccountView.swift` row; the normal build log contained **zero** `AccountView.swift` references and the path was absent from all three normal arm64 file lists. The two relocated trials repeated these results.

The shared `App/Navigation/Sidebar.swift` blob was `2a2ab91bfe71690dd0d773af080f9a528113bea9`, and its path compiled in both app modules. Its `Panel.account` source is inside `#if EXTENDED_ALL`; the All app command defined that flag and the normal app command did not. This is a **file-level control only**: compiling `Sidebar.swift` in both modules does not prove `Panel.account` was compiled in both, or even validate a particular declaration.
`AccountView.swift` itself contains `#if os(iOS)` and attributed properties. From the current pinned-source declaration validator's file-wide conditional check, a locator into this file would conservatively return `unverifiable`; that inference was not separately exercised as a runtime test here. This Spike therefore does **not** demonstrate a production path that upgrades a `pinnedSourceDeclaration` result for `AccountView` into selected-build evidence. It measures the selected compiler's file-input fact independently.

Across each complete three-module selected build, the arm64 input lists contained 83 tracked source occurrences in All and 82 in normal (81/80 unique paths because `App/General/FlowLayout.swift` and `Widgets/TruckActivityAttributes.swift` appeared in two target lists). Every tracked occurrence was inside the archive, present in `HEAD`, and byte-identical to its `HEAD:<path>` blob. No untracked or external Swift source path appeared in these lists. The remaining four inputs per build were generated under DerivedData: one app `GeneratedAssetSymbols.swift`, one Widgets `GeneratedAssetSymbols.swift`, and FoodTruckKit `resource_bundle_accessor.swift` plus `GeneratedAssetSymbols.swift`. FoodTruckKit contributed 30 tracked + 2 generated entries; Widgets 9 tracked + 1 generated, in each trial. SDK, compiler, plugins, dependent modules, manifests, assets, build settings, and generated-file provenance remain outside this tracked-blob comparison.

The two relocated archives had exactly equal Product-root-relative Swift input sets for all three measured modules. After substituting only archive and DerivedData root paths, the app arm64 `builtin-SwiftDriver` command lines were byte-identical within each scheme across relocation. Absolute raw paths differed. Each trial used a separate DerivedData directory; shared host/compiler/SDK caches may have been warm. Four single trials do not establish a cold/warm cost distribution.

Independent audit controls were kept distinct from the four real builds. A synthetic wrong expected OID (`000…000`) compared with the real `AccountView.swift` OID classified `mismatchedSource`; two synthetic records for one logical path with conflicting OIDs classified `ambiguous`; and a scratch symlink that resolved outside the archive root classified `rejectOutsideRoot`. These are checks of proposed comparison rules, **not** observed Xcode build failures or production validator behavior. A real `xcodebuild -showBuildSettings` probe with nonexistent target exited 65. A probe requesting nonexistent configuration `NoSuchConfig` exited 0, warned that it used the default, and reported `CONFIGURATION = Release`; consequently, a later validator must check requested and resolved configuration equality, not merely process success. The real four build trials requested and resolved Debug.

## Success Criteria

Both schemes build successfully at both locations; All's executed app invocation contains the exact pinned `AccountView.swift` blob; normal's complete selected Swift invocation inventory excludes it; relocation preserves those outcomes; tracked file-list sources match pinned Git bytes.

## Failure Criteria

An unsuccessful or unobserved invocation, incomplete target inventory, a missing or duplicate logical `AccountView.swift` entry, a Git OID mismatch, or changed membership after exact relocation would prevent this narrow positive/negative conclusion.

## Result

The measured success criteria held in all four trials. The real normal scheme is a negative target-selection control: no `AccountView.swift` path occurred in any of its three executed arm64 SwiftDriver input lists or compile rows. The All scheme is positive for the same pinned path/blob and explicitly selected app target. The build logs and archived bytes were checked after successful build; a later changed blob or missing inventory would fail the stated equality/presence condition, but no production fail-closed validator was implemented in this Spike. Generated inputs were distinguished from Product-tracked sources rather than counted as pinned blobs.

## Conclusion

**Observed:** an executed selected app compiler invocation can distinguish the same tracked Food Truck source path as present for `Food Truck All` and absent for `Food Truck` under these exact pinned commit, target, configuration, architecture, compiler, SDK, and flag conditions. Exact relocation preserved the result. **Inferred:** these observations are evidence for a narrow tracked-source membership claim if a later validator can verify invocation ownership, success, complete selected inventory, and pinned bytes. **Unknown:** a stable supported machine-readable Xcode invocation format and broader reproducibility of all transitive inputs. `Sidebar.swift` confirms why this file claim must not be promoted to conditional declaration or runtime behavior evidence. No ADR option is selected here.

## Artifacts

- [app-inventory.json](artifacts/app-inventory.json): compact machine-readable counts, selected modules and flags, pinned blob comparison, and relocation results from all four real trials.
- Four raw `*-build.log` files, archives, and independent DerivedData directories remain under `/tmp/hamii-app-membership-wte59r03` and are intentionally not committed. Independent audit control scratch data remains under `/tmp/hamii-membership-audit.NUWP0V`. The Product checkout and production source were unchanged.
