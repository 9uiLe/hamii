# Tracked File and Declaration Locator Spike

## Related Decision

[Product Mapping Locator](../../ADR.md), option 2: a Product-root-relative tracked file, expected declaration kind, enclosing declaration, and member name. This is evidence for the ADR, not a Profile v2 schema or a production validator.

## Hypothesis

A pinned Git commit plus an exact regular-blob path and typed enclosing/member name can narrow common Swift declarations to one reviewable source candidate without a Product build. File moves and symbol renames should make the old locator fail. Source presence alone cannot prove that a declaration compiles, is reachable, or has the intended behavior.

## Questions

- Can this tuple distinguish Team MINO's `Profile.nickname`, optional `Profile.createdAt`, edit action, and coordinator route, plus a different Product architecture?
- What happens with duplicate names, deletion, move, rename, wrong kind, stale commit, relocated checkout, symlink, and traversal?
- Where does a build-free source scan stop being credible for internal types, members, enum cases, conditional compilation, extensions, overloads, generated declarations, and resources?

## Prototype Scope

`artifacts/reproduce.py` is a read-only Python probe. It checks clean, exact pinned HEADs; retrieves exact path/tree mode and file bytes through `git ls-tree -r --full-tree -z` and `git cat-file blob`; and scans direct type members with a deliberately small line/brace recognizer. It produces `candidateUniqueLexical`, `missing`, `ambiguous`, `kindMismatch`, `invalidLocator`, `staleCommit`, or `unverifiable`. The source checkout is never edited; pre/post Git index SHA-256 values were equal, and status uses `--no-optional-locks`. Delete/move/rename/duplicate/symlink cases replace **in-memory** tree entries or bytes, not Git history. For relocation it copies the clean Team MINO checkout and makes a clean local Food Truck clone at the same pinned commits.

Target A is [Team MINO iOS](https://github.com/mash-up-kr/Team-MINO-iOS) at `dca2202f4be21869190d19bbcf223eb8646a2acd`; target B is [Apple Food Truck](https://github.com/apple/sample-food-truck) at `3954a769e99f3cc53297d94f2b960ceb2665b3d6`. Both local target checkouts were clean before and after the run. Source selection follows the [existing profile-state evidence](../../../product-integration-contract/spikes/existing-profile-state/SPIKE.md) and [repository-mapping evidence](../../../product-integration-contract/spikes/repository-mapping/SPIKE.md).

## Out of Scope

Full Swift parsing/type checking, compiler/index identity, macro expansion, conditional build configurations, Product behavior/reachability, resource bundle resolution, Profile v1→v2 migration, production API, and Product patching. No synthetic source variant was compiled. A lexical candidate is never reported as `verified`.

## Measurements

Run `python3 adr/product-mapping-locator/spikes/tracked-file-declaration/artifacts/reproduce.py > /tmp/tracked-file-result.json` from this repository with the default `/tmp/hamii-integration-spike/targets/{team-mino,food-truck}` checkouts, or pass those two roots as arguments. Compare the output to [the recorded one-run result](artifacts/results.json). The environment was local macOS, Git 2.52.0, Python 3.14.6, warm OS/Git caches; no Xcode build or symbol index. One correctness run contains 24 cases; lookup timing has five warm trials per target. Timings include Git subprocess startup, tree lookup, blob read, and the small scan. They are exploratory local latency, not a performance budget.

The exact candidate tuples and observed source lines are:

| Target | Product-root-relative tracked file | Enclosing / expected kind / member | Observed |
| --- | --- | --- | --- |
| Team MINO | `Packages/Domain/Sources/Domain/Entities/Profile.swift` | `Profile` struct / property / `nickname`; property / `createdAt` | Unique lexical lines 10 and 12; `createdAt: Date?` is optional. |
| Team MINO | `Packages/FeatureProfile/Sources/FeatureProfile/Main/ProfileMainStore.swift` | `ProfileMainAction` enum / enum case / `tapEditProfile` | Unique lexical line 83. |
| Team MINO | `Packages/FeatureProfile/Sources/FeatureProfile/ProfileCoordinator.swift` | `ProfileRoute` enum / enum case / `profileSetup` | Unique lexical line 11. |
| Team MINO | `Packages/FeatureHome/Sources/FeatureHome/HomeCoordinator.swift` | internal `HomeMapFocus` struct / property / `coordinate` | Unique lexical line 22, demonstrating source lookup is not restricted to `public` symbols. |
| Team MINO | `Packages/Domain/Sources/Domain/ValueObjects/MemberProfile.swift` | `MemberProfile` struct / property / `nickname` | Unique lexical line 10; the same member name exists on another type/file. |
| Food Truck | `FoodTruckKit/Sources/Account/User.swift` | `User` enum / enum case / `authenticated` | Unique lexical line 10, including an associated value. |
| Food Truck | `FoodTruckKit/Sources/Account/AccountStore.swift` | `AccountStore` class / property / `currentUser` | `unverifiable`: enclosing file is under `#if os(iOS) || os(macOS)` without a selected Product build configuration. |

The action and route are distinct source locators. Team MINO source shows `tapEditProfile` returns `.navigate(.pushProfileSetup)` and the coordinator pushes `.profileSetup`; finding the two enum cases alone does **not** prove that chain or a displayed destination. The earlier Product Integration Spike separately audited the chain and ran FeatureProfile tests; this locator probe does not reuse those tests as proof of its own validation.

**Observed scenario results:** a second `nickname` on `MemberProfile` and a synthetic second type with `nickname` did not disturb a file+enclosing-qualified locator. A synthetic second `Profile.nickname` in the same file produced `ambiguous` (that synthetic Swift would itself be invalid; it tests fail-closed candidate counting). Removing or renaming the member produced `missing`; moving the blob to a different path made the old locator `invalidLocator` and the updated path a unique lexical candidate. Asking for an enum case at `Profile.nickname` produced `kindMismatch`. A different expected commit produced `staleCommit` before lookup. Traversal and absolute paths, and an in-memory Git mode `120000` symlink at the same path, produced `invalidLocator`. An exact relocated clean Team MINO checkout copy produced the same candidate. A clean local Food Truck `git clone --shared` at its exact commit also produced the same enum-case candidate. A normal local Team MINO clone was attempted but its partial clone tried to fetch unavailable promisor object `13986ee18d0c6946a33f7a10532eb17aeeddac7e`; a fresh Team MINO clone therefore remains unverified here. The Food Truck clone and Team MINO copy are distinct measured relocation conditions, not interchangeable evidence of remote clone behavior.

**Observed unsupported constructs:** a `ShapeStyle` extension token `mhRed60` in `Packages/DesignSystem/Sources/DesignSystem/AtomicColors.swift` is `unverifiable` by this direct-type recognizer. Food Truck `AccountStore.signIntoPasskeyAccount` is `unverifiable` as a function/possible overload. A macro-generated member requested under `@Observable ProfileCoordinator` is `unverifiable` because it is absent as a direct source declaration. A conditional file is marked `unverifiable` even when text contains the requested property. These outcomes are intentional conservative classifications, not evidence that the Product symbols are absent.

**Resources:** Team MINO's `Packages/DesignSystem/Sources/DesignSystem/Resources/AtomicColor.xcassets/Red/60.colorset/Contents.json` and Food Truck's `App/Assets.xcassets/AccentColor.colorset/Contents.json` are regular tracked JSON blobs at the pinned commits. Exact file paths can identify their bytes, but the Swift declaration tuple does not establish logical asset name, bundle namespace, asset-catalog interpretation, or platform variant. The Team MINO token accessor `ShapeStyle.mhRed60` is an extension property referring to `Red/60`; this probe does not validate that relationship. A native intent such as system navigation is a semantic capability, not one Product Swift declaration; a route case locator does not verify it. Assets, token symbols, and native capabilities therefore need separate kind-specific evidence and cannot be claimed by one universal Swift locator syntax.

**Cost:** warm five-trial median was about 16 ms for each target on this machine, with no build/index. This is only Git object access and lexical candidate lookup. A full Swift parser, compiler index, build-configuration matrix, and resource resolver may have materially different costs.

## Success Criteria

At least the four named Team MINO declarations and a second Product construct are uniquely narrowed from pinned regular Git blobs; stale/wrong path/kind and duplicated candidates fail closed in the measured matrix; unsupported syntax is reported as unverified rather than silently accepted.

## Failure Criteria

Any path outside the pinned regular Git blob is accepted, a wrong kind or duplicate is reported uniquely, a commit change is ignored, or a lexical hit is called compiler-verified Product evidence.

## Result

The stated narrow lexical criteria were met in this one run. The four Team MINO targets, an internal member, and Food Truck's `User.authenticated` were unique lexical candidates; conditional `AccountStore.currentUser` and extension/function/generated examples remained `unverifiable`. The in-memory negative matrix failed closed as recorded. No compiler symbol identity, compiled existence, runtime behavior, or resource meaning was measured. The exact-commit receipt remains the authority for source identity; this probe adds only a candidate lookup within it.

## Conclusion

The file/kind/enclosing/member tuple is concrete and reviewable for the measured direct declarations and makes moves or renames explicit locator updates. It is insufficient by itself to certify a Swift symbol or Product mapping: conditional compilation, extensions, overloaded functions, macros, resource catalogs, and behavioral wiring require additional evidence or an explicit unsupported result. The ADR remains open for comparison with the other locator options and for a decision on what verified source evidence must mean.

## Artifacts

- [Read-only reproduction script](artifacts/reproduce.py)
- [One result matrix and timing sample](artifacts/results.json)
