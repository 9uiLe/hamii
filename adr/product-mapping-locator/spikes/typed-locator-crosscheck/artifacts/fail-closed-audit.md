# Fail-closed audit of a tracked-file typed declaration locator

This is independent audit evidence for [Typed Locator and Compiler Cross-check](../SPIKE.md), not a Product Profile schema or ADR decision. No Product, hamii production, or canonical file was edited. The two Product checkouts were clean at the pinned HEADs before and after the probes.

## Authority boundary

A locator that names `(Product commit, tracked path, declaration kind, enclosing path, member)` can identify **a source candidate** only if the implementation reads the exact regular blob from that commit. `git ls-tree -r <commit> <path>` supplies the tree mode/object ID, and `git cat-file blob <OID>` supplies bytes; worktree paths, `git grep` hits, graph `location.uri`, and an unpinned compiler index are not substitutes. An accepted path must be one canonical Product-root-relative Git path, with no absolute prefix, `..`, empty component, NUL, or symlink/submodule tree entry. It must not be resolved through the host filesystem. The [tracked-file probe](../../tracked-file-declaration/SPIKE.md) rejected traversal and simulated mode `120000`; the [compiler probe](../../compiler-index-identity/SPIKE.md) showed that compiling through a scratch symlink can emit a symbol from bytes outside the source root. These probes support a necessary guard, not a complete production path validator.

Pinned primary objects used here:

| Product | Commit | Git path | Mode/blob | Relevance |
| --- | --- | --- | --- | --- |
| Team MINO | `dca2202f4be21869190d19bbcf223eb8646a2acd` | `Packages/Domain/Sources/Domain/Entities/Profile.swift` | `100644 f15ccde1464aea6db82685fde706b81f47e7f9d5` | Direct `Profile.nickname`, `Profile.createdAt`. |
| Team MINO | same | `Packages/FeatureProfile/Sources/FeatureProfile/ProfileCoordinator.swift` | `100644 836e8470735bd66f7d36babe7b23f0e5554cd150` | Direct `ProfileRoute.profileSetup`; `@Observable` on `ProfileCoordinator`. |
| Team MINO | same | `Packages/DesignSystem/Sources/DesignSystem/AtomicColors.swift` | `100644 bb77fcc386605d249882ea514c0ab95e0be06d54` | `public extension ShapeStyle where Self == Color` declares `mhRed60`. |
| Food Truck | `3954a769e99f3cc53297d94f2b960ceb2665b3d6` | `App/Navigation/Sidebar.swift` | `100644 2a2ab91bfe71690dd0d773af080f9a528113bea9` | `Panel.account` is under `#if EXTENDED_ALL`. |
| Food Truck | same | `App/Assets.xcassets/AccentColor.colorset/Contents.json` | `100644 4bf40ac690ada9843d6f86ca1391f9d412ad9582` | Asset catalog entry, not a Swift declaration. |

These were checked with `git -C ROOT ls-tree -r COMMIT PATH` and `git -C ROOT show COMMIT:PATH`. The source roots are `/tmp/hamii-integration-spike/targets/{team-mino,food-truck}`. The same Team MINO commit materialized by a shared-object Git clone and `git archive` produced matching compiler USR triples in the earlier Spike; that is positive relocation evidence for the tested toolchain, not a reason to accept a different commit. A USR stayed unchanged across two different scratch Git commits in that Spike, so neither USR nor manifest revision proves freshness. A resolver must bind the lookup to the reviewed Product commit/blob and reject a stale receipt or unknown current worktree state separately.

## Focused conditional-compilation probe

The pinned Food Truck blob includes `Panel.account` inside `#if EXTENDED_ALL`. Its Xcode project has `SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG EXTENDED_ALL"` at lines 794 and 838, and `DEBUG` without `EXTENDED_ALL` at line 903. Thus a line/AST hit in the pinned blob is not enough to establish that the member exists in every selected Product configuration. The [Swift language reference](https://docs.swift.org/swift-book/ReferenceManual/Statements.html) says a conditional compilation block allows code to be “conditionally compiled depending on the value of one or more compilation conditions.”

To isolate that risk without building Food Truck, one scratch file at `/tmp/hamii-typed-crosscheck/Conditional.swift` contained:

```swift
struct ConditionalModel {
#if PRODUCT_FEATURE
    var enabled: Int
#else
    var disabled: Int
#endif
}
```

Its SHA-256 was `45c8f329e425c3ee5b8289b626e75fce9536b711bb138b319c641cba857a68ce` for both invocations. `xcrun swiftc -emit-module -parse-as-library -module-name ConditionalProbe` with identical macOS 27 SDK/target and either no `-D` or `-D PRODUCT_FEATURE`, followed by `swift-symbolgraph-extract -minimum-access-level internal`, produced:

| Same source bytes | Compiled `ConditionalModel` property | Missing property |
| --- | --- | --- |
| No `-D PRODUCT_FEATURE` | `disabled` | `enabled` |
| With `-D PRODUCT_FEATURE` | `enabled` | `disabled` |

**Observed:** A pinned blob and syntactically unique property name can still be absent from a selected compiled module. **Inferred guard:** If selected target/build conditions cannot be established and checked, classify a conditional declaration `unverifiable`; do not report `verified` from source text. This fixture demonstrates language behavior, not a complete Food Truck build.

## False-verified matrix

| Input or construct | Concrete evidence and risk | Conservative source outcome |
| --- | --- | --- |
| Direct unconditional nominal member or enum case | Pinned Team MINO `Profile.nickname`/`createdAt` and `ProfileRoute.profileSetup` are direct declarations. Domain compiler graph independently found `Profile.nickname` as one `swift.property` and `AvatarColor.red` as `swift.enum.case` under the tested macOS package build. A parsed source match still does not prove the iOS Product target includes it. | Eligible for **pinned-source declaration existence** only after exact blob, unique typed AST node, direct enclosing scope, and commit checks. A Product-compiled-symbol claim needs matching target/module/configuration evidence. |
| Wrong kind or duplicate | Previous tracked-file matrix returned `kindMismatch` for enum-case request at `Profile.nickname` and `ambiguous` for duplicate direct members. Compiler graph distinguishes `Profile.nickname` property from a method request. | `kindMismatch` or `ambiguous`; never first-match wins. |
| Conditional declarations | Pinned Food Truck `Panel.account` and same-byte two-configuration probe above. | `unverifiable` without selected build conditions and compiler cross-check. |
| Extension member | Team MINO `ShapeStyle.mhRed60` is in a constrained extension, outside a direct nominal body; the extension may be in another blob/module and can overlap other extensions. | `unverifiable` for a direct-member-only grammar. Do not mistake a same-name direct member or textual token for the extension declaration. |
| Overloaded function/initializer | Controlled compiler graph had two `FlowLayoutRenamed.locatorProbe(_:)` methods with the same displayed path/kind but distinct precise IDs (`…S2iF` versus `…S2SF`). | `ambiguous` or `unverifiable` unless a signature-level locator and compiler binding are validated. |
| Nested or local declaration | Food Truck's pinned `FlowLayout.FlowResult.Row` is nested and appeared in an internal symbol graph; a one-level enclosing path cannot describe it. Local declarations were not compiled in this audit. | `unverifiable` unless the grammar covers every enclosing scope and uniqueness is proven. Do not silently flatten. |
| Macro-expanded/generated member | Pinned Team MINO `ProfileCoordinator` uses `@Observable`. [Swift macro documentation](https://docs.swift.org/latest/documentation/swift/applying-macros/) says an attached macro “generates code and adds that code to the declaration.” Generated build sources may not be blobs in the pinned tree. | Direct source grammar may verify only explicitly written members; generated members require pinned generator/build evidence or `unverifiable`. |
| Same blob compiled into multiple modules | The exact pinned Food Truck `FlowLayout.swift` was compiled in scratch under `FoodTruckProbe` and `FoodTruckAlternative`; `FlowLayout` USR changed from `s:14FoodTruckProbe10FlowLayoutV` to `s:20FoodTruckAlternative10FlowLayoutV`. This is a module-dependence probe, **not** evidence the real Product compiles the file twice. | `unverifiable` as a Product symbol without actual target/module membership; path+source-kind may still locate only a source candidate. |
| Symlink, traversal, submodule, untracked/generated path | Tracked-file matrix rejected simulated `120000` and traversal. Compiler symlink fixture emitted an outside-root symbol. | `invalidLocator` for malformed or nonregular Git path; `unverifiable` for generated/nontracked source unless another pinned evidence scheme exists. |
| Asset catalog entry | Team MINO `Red/60.colorset/Contents.json` and Food Truck `AccentColor.colorset/Contents.json` are regular Git JSON blobs. `mhRed60` is a Swift extension accessor referencing `Red/60`, but accessor existence does not validate bundle/name/variant resolution. | A Swift declaration locator must return `unverifiable` for resource identity; a separate kind-specific asset locator could verify pinned bytes, then needs catalog/bundle semantics. |
| Token or Native capability | A Swift token accessor can be a declaration; underlying color/resource value or system navigation behavior is different evidence. `ProfileRoute.profileSetup` proves an enum case, not a navigation transition. Entitlements are a tracked non-Swift file (`App/App.entitlements`, blob `e3389d5e122c5b9592fe5392dc45c85228c91579`). | Verify only the precisely declared Swift symbol. Token value, asset, entitlement, and Native capability need distinct contracts; otherwise `unverifiable`. |
| Clone, branch, commit transition | Earlier exact-source relocation retained identities; a different commit retained the `Profile` USR in a controlled edit. | Bind to receipt commit/blob and current observation, not a symbol name/USR alone. Unknown or stale state fails closed. |

## Exact defensible subset and remaining unknowns

For a **source-existence-only** result, a future typed parser could conservatively accept an exact regular blob at the pinned commit containing exactly one explicitly written, direct, unconditional Swift nominal declaration and exactly one explicitly written direct stored property or enum case of the expected kind. The parser must account for enclosing braces/comments/strings rather than scan lines, reject conditional ancestors and ambiguous duplicates, and keep selected module membership outside that claim. The existing lexical probe narrows these candidates but does **not** implement that parser or establish this result as production `verified`.

If `verified` means “exists as a declaration in the selected Product build,” the current probes establish that extra proof only for tested `Domain` declarations under one macOS package/compiler context; they do not establish it for the pinned Team MINO iOS app or Food Truck app as complete Products. Build settings, module graph, macro expansion, generated sources, availability, and platform SDK remain necessary inputs or `unverifiable` outcomes. No one of the probes establishes mapping behavior such as I03, runtime execution, navigation, asset bundle resolution, or patch authorization. Profile v1 free strings remain structural-only.

This audit does not select the ADR option. Its specific failure criterion is any source-only candidate being promoted to a Product-verified mapping while one of the above inputs is unknown.
