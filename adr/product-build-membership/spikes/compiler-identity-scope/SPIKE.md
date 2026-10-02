# Compiler identity and selected-build scope

## Related Decision

[Product Build Membership](../../ADR.md): what evidence permits hamii to say that a mapped declaration is present in a **selected Product target and configuration**, beyond the existing pinned-source declaration claim. This Spike evaluates compiler, symbol-graph, and IndexStore evidence only; it does not choose the Product contract.

## Hypothesis

A kind-tagged compiler symbol in an artifact built from a pinned Product tree can corroborate selected-module membership when the root target, configuration, module, and compiler invocation are known. A USR, symbol graph, or IndexStore record alone cannot establish the selected Product app target, source freshness, or the provenance of all compiler inputs. A complete transitive closure belongs to a stronger build reproducibility claim.

## Questions

- Which previously measured symbols prove presence in an actual pinned Product package module, and which selected-app claim remains untested?
- Can the same pinned source be present yet excluded by a target or compilation condition?
- Does a compiler identity remain useful after a commit change, module change, or source input escaping the pinned tree?
- What selected compiler-invocation input inventory would a narrow tracked-source membership claim require, which other inputs remain unbound, and what is the unmeasured cost?

## Prototype Scope

- Read-only review of the historical compiler/index Spike at commit `a35e371` and the typed locator compiler cross-check with `compiler-crosscheck.md`, `compiler-crosscheck.json`, and `fail-closed-audit.md` at commit `339fb29`. Those completed locator ADR files were deleted from the current tree; retrieve exact evidence with `git show COMMIT:PATH` as listed under Artifacts.
- Direct `git show` inspection of pinned Team MINO commit `dca2202f4be21869190d19bbcf223eb8646a2acd` (`Packages/FeatureHome/Package.swift`) and Food Truck commit `3954a769e99f3cc53297d94f2b960ceb2665b3d6` (`App/Navigation/Sidebar.swift`). Both local source checkouts had those exact HEADs at inspection.
- No new compiler invocation, Product build, or production repository edit in this Spike. Previous scratch compiler outputs were outside hamii and the Product repositories.

## Out of Scope

- A full Team MINO or Food Truck app-target build, negative target/configuration compiler run, complete transitive-input attestation, runtime behavior, resource-bundle membership, Product patch authorization, and implementation of a membership verifier.
- Treating a package scheme build as proof that an app target links the package, or treating the `FoodTruckProbe` standalone module from the earlier experiment as the actual Product module.

## Measurements

No new timing trial was run. The following **prior local measurements** have one build trial each unless noted, with Xcode 27.0 (27A266a), Apple Swift 6.4, iPhoneSimulator27.0 SDK, and isolated scratch build outputs. See historical `compiler-crosscheck.json` at `339fb29` for exact conditions and sample values.

| Prior operation | Observed result | Wall time |
| --- | --- | --- |
| Pinned Team MINO `FeatureProfile` iOS Simulator package build, including dependencies | Succeeded; actual `FeatureProfile` and `Domain` module symbols extracted | About 27.9 s, one trial |
| Pinned Food Truck `FoodTruckKit` iOS Simulator package build | Succeeded; actual `FoodTruckKit` module symbols extracted | About 27.7 s, one trial |
| Warm symbol-graph extraction from built modules | `Domain`, `FeatureProfile`, `FoodTruckKit` | Three trials each: 0.108–0.120 s, 0.277–0.287 s, 0.575–0.735 s respectively |
| Symbol-graph extraction without built `FeatureProfile.swiftmodule` | Exit 1: module could not be loaded | One failure; no Product-wide lookup time measured |
| One-file Food Truck typecheck with IndexStore (earlier macOS probe) | 2,077 files, about 25 MB including SDK imports | 3.64 s, one warm trial; not an end-to-end reader |

The prior full graph triples matched across relocated builds: `Domain` 566/566, `FeatureProfile` 1851/1851, `FoodTruckKit` 5991/5991. Relocation and warm-cache measurements do not establish cross-toolchain stability or whole-Product verification latency.

## Success Criteria

- State the exact module/configuration scope supported by prior positive compiler identities without promoting it to an app-target or runtime claim.
- Exhibit concrete source-present/build-absent risks, distinguish a demonstrated compiler negative from a manifest-only inference, and identify an experiment that would falsify an unsafe membership rule.
- Identify missing transitive-input and freshness evidence; keep all unproven selected-build cases `unverifiable`.

## Failure Criteria

- Claim selected Product app membership from a source blob, a package symbol graph, a USR, or `location.uri` alone.
- Treat a same-USR/different-commit result or an outside-root symlink compiler input as fresh pinned-tree evidence.
- Turn one-off build times into a Product SLA or assert that an unrun negative target build succeeded.

## Result

**Confirmed positive, with narrow scope:** Previous pinned iOS Simulator package builds found seven kind-tagged declarations in the actual `Domain`, `FeatureProfile`, and `FoodTruckKit` modules. For example, Team MINO `Profile.nickname` had `swift.property` USR `s:6Domain7ProfileV8nicknameSSvp`; `ProfileMainAction.tapEditProfile` had a `swift.enum.case` USR in `FeatureProfile`; Food Truck `AccountStore.currentUser` had a `swift.property` USR in `FoodTruckKit`. Five selected source files matched regular Git blobs byte-for-byte. The exact module/configuration builds corroborate declaration compilation in **those package modules**. No app target or UI/runtime test was built in that cross-check.

**Confirmed language-level exclusion; Product negative untested:** The pinned Food Truck `App/Navigation/Sidebar.swift` contains `Panel.account` inside `#if EXTENDED_ALL`. Its project settings include configurations with `EXTENDED_ALL` and one with only `DEBUG` (historical `fail-closed-audit.md`, project lines 794/838 and 903). A separate same-byte scratch source compiled with and without `-D PRODUCT_FEATURE` yielded mutually exclusive symbol-graph properties. This directly demonstrates conditional compiler exclusion; the specific Food Truck app configurations were **not** built here.

**Observed target-selection input; negative compile still unmeasured:** Pinned Team MINO `FeatureHome/Package.swift` names `FeatureHome` and dependencies including `Domain`, but not `FeatureProfile`. Its listed local dependency manifests did not name `FeatureProfile` on inspection. `ProfileMainAction.tapEditProfile` existing in the separately built `FeatureProfile` graph therefore cannot prove inclusion in a selected `FeatureHome` package build. A complete resolved build graph and negative `FeatureHome` compiler run were not captured, so absence from that built artifact is an inference, not a measured graph result.

**Confirmed identity/input limits:** Prior controlled edits produced the same `Profile` USR at different Git commits, while changing the probe module name changed `FlowLayout`'s USR. A compiler invoked on a symlink inside a scratch source root emitted a symbol from bytes outside that root. Graph `location.uri` changed with absolute checkout location. Thus compiler ID and graph location are insufficient as a commit or input-provenance proof. The previous cross-check checked five selected blobs but did not account for every transitive source, manifest, generated file, macro/plugin output, build setting, SDK/toolchain input, or resource. Team MINO's pinned `DesignSystem/Package.swift` processes asset catalogs and fonts; Food Truck's Xcode project uses SDKROOT frameworks and configuration-dependent compilation conditions. These are concrete input classes beyond the five checked Swift blobs.

**Measured cost boundary:** The table reports prior package builds, module extraction, and one-file IndexStore generation. It does not include a production IndexStore reader, selected root-target build, complete input audit, failure recovery, or end-to-end membership validation. Compiler symbol graphs did not supply asset catalog entry or token/native semantic identity in the prior probe.

**Inferred safe requirement:** A narrow `selectedBuildMember` result needs a named Product root target, destination/platform and configuration, compiler and SDK identity, an executed compiler invocation attributable to that selected build, and exact path/blob binding for the **target tracked source input**. A complete inventory of relevant Swift invocations is needed before declaring the target absent. Generated, external, and other transitive inputs must be classified; their unbound state limits a broader reproducible-build claim, but does not by itself negate the observed target-blob membership. If the target input itself is unknown or escapes the pinned tree, its membership remains `unverifiable`.

**Unknown:** Whether both real Product app targets and their relevant negative configurations can be reproduced from a fully pinned input closure; whether an IndexStore reader can authenticate its records against that closure; stability under other Xcode/Swift/SDK settings; complete private/local/macro declaration coverage; resources and bundle membership; end-to-end latency and failure rate. No evidence here proves Product action/route behavior or patch permission.

## Conclusion

Compiler evidence corroborates the seven tested declarations in their actual pinned **package module builds** and distinguishes kinds and overloads under measured settings. It does not yet prove membership in a selected Product **app target/configuration**. A source-present conditional declaration and the untested target-exclusion case show why the selected build context matters; unchanged USRs across commits and outside-root compiler inputs show why a graph cannot be its own authority. The next focused experiment should build named positive and negative Product root targets/configurations from immutable pinned trees, record the executed compiler invocation input inventory, explicitly classify unbound/transitive inputs, and verify exact tracked source membership. Conditional declaration presence remains a separate claim. Until that evidence exists, the existing `pinnedSourceDeclaration` result must not be elevated to selected-build membership.

## Artifacts

No new artifact file. Historical evidence remains in Git: `git show a35e371:adr/product-mapping-locator/spikes/compiler-index-identity/SPIKE.md`, `git show 339fb29:adr/product-mapping-locator/spikes/typed-locator-crosscheck/artifacts/compiler-crosscheck.md`, `git show 339fb29:adr/product-mapping-locator/spikes/typed-locator-crosscheck/artifacts/compiler-crosscheck.json`, and `git show 339fb29:adr/product-mapping-locator/spikes/typed-locator-crosscheck/artifacts/fail-closed-audit.md`.
