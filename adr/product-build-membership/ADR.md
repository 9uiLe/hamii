# Product Build Membership Evidence

## Context

An authoritative Product Repository Profile v2 can identify one explicitly written Swift declaration in a receipt-pinned Git blob. The read-only validator reports `pinnedSourceDeclaration` evidence for this restricted claim. It does not establish that the declaration belongs to a selected Product build. Product targets, modules, configurations, conditional compilation, generated files, dependencies, and toolchains can change that answer without changing the declaration locator. The current boundary is documented in `docs/final-architecture.md` and `docs/integration-profile.md`.

## Decision to Make

What fail-closed evidence is sufficient to establish that the exact receipt-pinned source path and blob of a source-verified direct Swift declaration were observed as an input to an executed Swift compiler invocation for an explicitly selected Product target, module, and configuration?

## Constraints

- Keep Product build metadata and repository-specific architecture outside hamii Core IR.
- Preserve the existing `pinnedSourceDeclaration` evidence scope. A later `selectedBuildMember` result means only that the exact pinned path/blob was observed in one executed, selected Swift compiler invocation. It must be additive and must not imply that a conditional declaration was compiled, that the whole build is reproducible, or that type correctness, runtime behavior, semantic mapping correctness, or Product patch publication is established.
- Bind the selected Product commit, source path/blob, target/module, configuration, architecture, SDK, compiler executable identity/version, and relevant Swift compiler arguments to the observed invocation. Classify generated, untracked, external, and unbound transitive inputs explicitly. Their presence limits a whole-build reproducibility claim, but does not by itself negate observed membership of a distinct, exact tracked blob.
- A static project or package declaration predicts membership but does not by itself prove an executed compiler input. A compiler symbol without a pinned input set does not establish current membership.
- Read-only validation must not mutate the Product worktree or treat an unpinned worktree file as source authority. Builds, if required for evidence, must run in isolated disposable locations with bounded resource and time costs.
- Profile v1 remains structural-only. Resource and Native mapping evidence have separate decision boundaries.

## Options

1. Static SwiftPM manifest and Xcode project/target membership with resolved settings.
2. Selected build plan, Swift compiler invocation, or explicit compiler file list tied to pinned Git blobs and build inputs.
3. Compiler index, symbol graph, or comparable compiler-produced declaration identity tied to a selected invocation and its source inventory.
4. A staged combination: static selection for early rejection, followed by compiler-input evidence for a positive membership claim.

## Current Hypothesis

The staged compiler-input hypothesis is resolved by the Decision below. The source-to-build Spike established a narrow tracked-file input join for its measured Xcode build; it did not establish a supported production inventory acquisition mechanism.

## Decision

Adopt **Option 4, a staged, fail-closed check**. Static Product project/package metadata may validate or reject a selection when that conclusion is sound, and may predict membership, but it is not authority for a positive `selectedBuildMember` result. Compiler symbol, USR, symbol-graph, or index identities may corroborate a result; none replaces Product commit/path/blob provenance.

`selectedBuildMember` is additive evidence, eligible only after a Product Profile v2 receipt has `verified` `pinnedSourceDeclaration` evidence for the same mapping key and exact Product commit, regular tracked source path, and Git blob. The caller must explicitly select the project/workspace or package, scheme/root target, owning target, Swift module, requested configuration, platform/SDK, and architecture. The resolved configuration and other relevant resolved settings must agree with that selection. A successful build must yield an unambiguous **executed** Swift compiler invocation owned by that selected target/module and a complete, recognized input inventory for that invocation. Exactly one regular tracked input in that invocation must match the receipt-pinned Product-relative path and blob. The source used for the build must be an immutable pinned materialization or have an equivalent protected binding to those bytes; a post-build hash alone is insufficient against concurrent mutation.

Positive evidence binds the receipt's Product commit and source mapping key/path/blob to the build-system selection, owning target/module, requested and resolved settings, compiler executable identity/version, relevant normalized compiler arguments or digest, executed invocation identity, selected input-inventory identity, and matching tracked input path/blob. It claims only that this **source file** was an input to that selected invocation. It does not claim that the particular declaration survived conditional compilation, its type or Product semantics are correct, it runs, the complete build is reproducible, or a Product patch may be generated or published.

The build-evidence outcomes have distinct meanings:

- `selectedBuildMember`: the eligible source and one explicit selected executed invocation have the exact commit/path/blob match above.
- `missingFromSelection`: an explicit, unambiguous selection has a complete observed executed input inventory, and the source is absent. Static prediction alone cannot establish this absence.
- `mismatchedSource`: the Product commit matches, but an otherwise matching tracked logical path has a different blob.
- `ambiguous`: the selected target/module or invocation/input identity cannot be made unique, including multiple matching invocations or competing logical inputs.
- `unverifiable`: the selected build failed; its executed invocation or recognized complete inventory is unavailable; requested and resolved settings disagree; the only candidate is generated, external, or untracked; or the selection is incomplete without a basis for a more precise verdict. A successful warm/no-op build with no executed selected invocation cannot issue fresh positive evidence from a prior build's inventory.
- `staleProduct`: the source receipt's Product commit differs from the build commit. Check this before comparing source blobs.

An unverified `pinnedSourceDeclaration` is ineligible for build membership evaluation. Omitted target/module cannot support `missingFromSelection`; absence from an unspecified selection is not a proven negative. The Spike's join prototype tested ambiguity for an omitted module with two matching invocations, but its other omitted-selection classifier branches are not normative production behavior.

Generated, untracked, external, and unbound transitive inputs remain separately classified. Their presence limits a whole-build reproducibility claim, but does not negate the observed membership of a distinct exact tracked source input. `reproducibleBuildClosure` is a separate decision boundary.

The production read-only selected-build validator and its inventory acquisition adapter are **not implemented**. The Spike's Xcode log/`SwiftFileList` parser is not a supported production contract. If the installed build system/toolchain cannot provide a recognized, complete executed-invocation inventory, return `unverifiable`. A future receipt-reuse/cache mechanism requires its own validated contract; this Decision authorizes no inference from a previous no-op build.

## Unknowns

- Which supported production adapter can acquire, authenticate, and validate a complete executed-invocation inventory for each supported Xcode or SwiftPM/toolchain output. Unknown formats fail closed.
- How to bound isolated build cost and handle warm/no-op builds without treating past compiler inputs as fresh evidence.
- How production validates toolchain/compiler identity, response-file arguments, multi-architecture/app-and-Widget selection, and protected immutable source materialization across supported environments.
- Whether a separately validated receipt-reuse mechanism is valuable. It is not part of this Decision or the initial production validator.

## Required Evidence

The [static target membership](spikes/static-target-membership/SPIKE.md), [compiled input inventory](spikes/compiled-input-inventory/SPIKE.md), [compiler identity scope](spikes/compiler-identity-scope/SPIKE.md), [executed app input membership](spikes/executed-app-input-membership/SPIKE.md), and [source-to-selected-build bridge](spikes/source-to-selected-build-bridge/SPIKE.md) Spikes supply the Decision evidence. The bridge linked a production Profile v2 source receipt to the same disposable Food Truck C1 commit's selected app compiler input; an explicit nonmember module, omitted module, changed Product commit, warm no-op build, and unknown configuration did not authorize positive evidence. Relocation reproduced the normalized result. Its one-trial timings and synthetic controls are labeled as such; compact artifacts alone cannot authenticate discarded raw Xcode logs. These results justify the narrow evidence contract, not production acquisition or another Product/toolchain's support.

Implementation validation must demonstrate the production adapter's recognized inventory and selection ownership, protected pinned build source, exact blob binding, fail-closed verdicts, cold/warm behavior, read-only Product worktree/ref behavior, and bounded cost on each supported environment. It must not infer conditional-declaration compilation, Product runtime semantics, or patch safety from source-file membership.

## Decision Criteria

The Decision is satisfied by the preceding Spike evidence for the narrow tracked-file input claim. Implementation is complete only when production code binds one recognized executed invocation to the exact receipt-pinned Product commit/path/blob and explicit selected target/module/configuration, returns the distinct fail-closed outcomes above, leaves the Product checkout/ref unchanged, and has validation for supported build environments. A failed build, missing inventory, or unknown toolchain format never produces positive evidence. Evaluate correctness and false-positive risk before read-only behavior, toolchain portability, cold/warm cost, and maintenance burden. If the production adapter cannot prove the claim for a selected environment, it returns `unverifiable` without broadening `pinnedSourceDeclaration`.

## Status

Implementation Required
