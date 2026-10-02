# Spike: Pathless qualified semantic symbol

## Related Decision

[Product Mapping Locator](../../ADR.md), option 1. This Spike evaluates `Type.member` (optionally with a module qualifier) as a Product-owned locator. It does not choose the ADR outcome.

## Hypothesis

A qualified Swift declaration name plus expected declaration kind may identify common Product mappings from immutable Git source without recording a file path or building the Product.

## Questions

- Can it distinguish Team MINO's `Profile.nickname`, `Profile.createdAt`, edit action and route, plus a different architecture's declarations?
- What happens under duplicate names, deletion, rename, file move, wrong kind, conditional compilation, extension members, clone relocation, and commit changes?
- Can the same symbol shape cover asset catalog entries, token symbols, and native capabilities?

## Prototype Scope

Read-only syntax probe of clean pinned [Team MINO](https://github.com/mash-up-kr/Team-MINO-iOS) `dca2202f4be21869190d19bbcf223eb8646a2acd` and clean pinned [Food Truck](https://github.com/apple/sample-food-truck) `3954a769e99f3cc53297d94f2b960ceb2665b3d6`. The [probe](artifacts/probe.py) reads Git objects at those SHAs, uses `git grep` only to preselect byte-containing Swift blobs, then `swiftc -frontend -dump-parse` to identify syntax declarations and enclosing nominal/extension ranges. Controlled mutations exist only in memory. A temporary relocated Git clone and two temporary independently compiled Swift modules test specific identity cases.

## Out of Scope

Production validator/schema, complete Swift type checking, actual Product build/index, macro expansion, semantic behavior, asset compilation, signing/capability verification, patch publication. No Product or hamii production files were changed.

## Measurements

Reproduce with `python3 adr/product-mapping-locator/spikes/qualified-semantic-symbol/artifacts/probe.py --target team-mino` and `--target food-truck`. Captured one trial each in [team-mino.json](artifacts/team-mino.json) and [food-truck.json](artifacts/food-truck.json). Machine: local macOS Swift compiler via `swiftc`; times are one warm local trial, wall milliseconds for Git grep, Git blob reads, and per-candidate Swift parse, not an SLA. Team MINO has 545 regular tracked Swift blobs; Food Truck has 82. No Product build or index was required for these syntax observations. Raw byte prefilter and parse-dump do **not** prove compiled declaration identity or semantic uniqueness.

| Pinned source and requested symbol | Syntax observation | Git grep blobs / parsed blobs | Elapsed |
| --- | --- | ---: | ---: |
| Team MINO `Profile.nickname` | one property candidate, `Packages/Domain/Sources/Domain/Entities/Profile.swift:10` | 54 / 47 | 4.1 s |
| Team MINO `Profile.createdAt` | one property candidate, same file `:12` | 79 / 37 | 3.5 s |
| Team MINO `ProfileMainAction.tapEditProfile` | one enum case, `Packages/FeatureProfile/Sources/FeatureProfile/Main/ProfileMainStore.swift:83` | 4 / 3 | 0.28 s |
| Team MINO `ProfileMainNav.pushProfileSetup` | one enum case, same file `:94` | 4 / 4 | 0.36 s |
| Team MINO `ProfileRoute.profileSetup` | one enum case, `Packages/FeatureProfile/Sources/FeatureProfile/ProfileCoordinator.swift:11` | 7 / 2 | 0.23 s |
| Team MINO `MHTypography.display1Bold` | one Swift token property, `Packages/DesignSystem/Sources/DesignSystem/MHTypography.swift:117` | see JSON | 0.19 s |
| Food Truck `Donut.name` / `City.name` | one property each, `FoodTruckKit/Sources/Donut/Donut.swift:13` / `City/City.swift:13` | 29 / 15; 29 / 8 | 1.4 s; 0.88 s |
| Food Truck `Donut.classic` | one extension property, `FoodTruckKit/Sources/Donut/Donut.swift:63` | 6 / 6 | 0.55 s |
| Food Truck `Panel.account` | zero parse-dump candidates; source `App/Navigation/Sidebar.swift:21` is behind `#if EXTENDED_ALL` | 8 / 3 | 0.32 s |

The `ProfileMainAction` reducer handles `.tapEditProfile` in `ProfileMainStore.swift:204-205`, emits `.pushProfileSetup`, and `ProfileCoordinator.swift:101-104` pushes `.profileSetup`; the symbol locator identifies declarations only, not this behavior. Food Truck's `Panel` is an **internal** enum. Its app project sets `SWIFT_ACTIVE_COMPILATION_CONDITIONS` to `EXTENDED_ALL` (`Food Truck.xcodeproj/project.pbxproj:794,838`). `-dump-parse` omitted `account` even with `-D EXTENDED_ALL`; `swiftc -frontend -D EXTENDED_ALL -dump-ast App/Navigation/Sidebar.swift` showed the `account` enum case at line 21 but also failed `no such module 'FoodTruckKit'` without the Product build context. This is a measured limit of the probe, not proof of absence in the app.

Controlled in-memory `Profile.nickname` mutations: copying the declaration into an independent module made two syntax candidates (`ambiguous`); deleting or renaming the member yielded zero (`missing`); moving its file retained one syntax candidate; changing the property to a method or requesting enum-case kind yielded `kindMismatch`. Two separate `swiftc -emit-module` invocations of `struct Profile { let nickname: String }` as `ModuleA` and `ModuleB` both exited 0: the duplicate is legal across modules. A module-qualified name could disambiguate *if* the resolver proves the declaration's module from the pinned build graph. Neither simple `Type.member` nor parsing single blobs supplies that proof. Overloads, same-name members in extensions, nested/local declarations, aliases, macros, generated code, and conditional branches need stricter handling; this probe did not measure their full behavior.

A temporary `git clone --shared --no-checkout` of Team MINO at another absolute directory had the same HEAD and byte-identical `Profile.swift` blob (848 bytes, SHA-256 `c6a27abe08e93befcf6c3d11f1950b63024274df0aaa96a191441565a20a22d4`). Thus Git-object syntax lookup is independent of the checkout location in this case. A pinned receipt must still reject a different Product commit; a pathless symbol alone carries no commit identity. The in-memory rename demonstrates that a changed blob can make the symbol disappear, but no real second commit was built. Both pinned trees had zero tracked symlink blobs; the probe accepts only `100644` Swift blobs and reads Git objects, so worktree symlink traversal was not exercised. A pathless symbol has no user-supplied file path traversal field; resource lookup would need its own path validation.

Non-Swift classes have distinct evidence: Team MINO `Packages/DesignSystem/Sources/DesignSystem/Resources/Icon.xcassets/aiReview.imageset/Contents.json` and Food Truck `FoodTruckKit/Sources/Assets.xcassets/donut/donut.symbolset/Contents.json` are asset catalog entries, not Swift declarations; Team MINO `App/App.entitlements` records `aps-environment` and associated domains, not Swift symbols. A Swift-declared token such as `MHTypography.display1Bold` is a syntax candidate, while catalog color/token values require resource-specific resolution. **Inferred:** a single Swift `Type.member` variant cannot cover these resource/capability classes; typed resource/capability locator variants or explicit unsupported outcomes would be needed. Whether asset-generated Swift symbols and entitlements can be validated in a future build/index is unknown here.

## Success Criteria

One syntax candidate for each requested Team MINO declaration and at least one alternative Product declaration; controlled duplicate/missing/wrong-kind behavior is distinguishable; clone and file-move behavior is measured; evidence does not overstate syntax as semantic verification.

## Failure Criteria

Pathless names cannot be resolved uniquely in common valid module arrangements, configuration-dependent declarations cannot be established from simple parse, or required non-Swift mapping classes have no representable symbol. These are candidate limitations, not a final ADR decision.

## Result

**Measured:** Team MINO's requested declarations each yielded one syntax candidate. Food Truck supplied one candidate for model members and an extension member. Valid duplicate modules made an unqualified symbol ambiguous. Deletion, rename, file move, and wrong-kind outcomes were distinguishable in controlled syntax input. Clone relocation preserved exact Git blob bytes. The Food Truck internal conditional enum case required build-condition awareness; parse-only lookup missed it. Assets and entitlements are committed non-Swift objects and did not enter Swift declaration scanning.

**Confirmed boundary:** `git grep` is a byte occurrence filter; `-dump-parse` is a source syntax check; neither is an authoritative compiler declaration identity. The parent ADR's `verified` status must not be assigned from this probe's `oneSyntaxCandidate`. **Inferred:** a pathless symbol schema needs at least declaration kind, module/build-condition binding, and separate typed non-Swift variants or explicit unsupported outcomes. **Unknown:** whether a build-free implementation can establish those bindings reliably, handle overloads/macros/aliases, and keep acceptable lookup cost at scale.

## Conclusion

Pathless `Type.member` is convenient across file moves and produced useful syntax candidates in both pinned repositories, but this experiment does not establish a fail-closed source-verification locator. Module ambiguity, build conditions, and non-Swift mapping classes remain decisive concerns for comparison with the other ADR options. No ADR option is selected here.

## Artifacts

[probe.py](artifacts/probe.py), [team-mino.json](artifacts/team-mino.json), [food-truck.json](artifacts/food-truck.json). Temporary clone, modules, and compiler outputs were discarded; no large build output was saved.
