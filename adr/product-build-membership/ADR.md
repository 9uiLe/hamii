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

**Tentative:** An exact selected-build compiler input inventory, checked against receipt-pinned Git blobs and the resolved target/configuration/build environment, may support a narrow `selectedBuildMember` claim. Static metadata may reject obvious nonmembers cheaply; compiler/index identities may corroborate a build. The minimum reproducible inventory and a reliable way to obtain it are not yet established. No option is selected.

## Unknowns

- Whether Xcode and SwiftPM expose a stable, portable selected-build input inventory without relying on private output conventions.
- Whether a source-verified direct declaration accepted by the current v2 validator can be linked to an observed selected app compiler input in one end-to-end trial. The Food Truck `AccountView.swift` differential is file-level evidence only because that file contains conditional compilation and is currently `unverifiable` to the source validator. `FlowLayout.spacing` has a plausible direct declaration and an observed app input, but no authoritative v2 Profile/receipt trial has validated that combination.
- How to capture an executed selected invocation and classify generated, untracked, external, and transitive inputs without claiming a hermetic or fully reproducible build.
- How conditional compilation and target membership interact when the same source path is present in multiple Product targets or configurations.
- How to handle app/Widget targets, multi-architecture builds, build-system caches, and a relocated exact clone.
- Cost of cold and warm evidence collection, and whether a read-only Product validation workflow can bound that cost acceptably.
- Whether compiler/index identities add trustworthy information after the selected invocation's source inventory, or only duplicate it.

## Required Evidence

- Use receipt-pinned clean Product commits from Team MINO and Food Truck. Record exact target/module/configuration/architecture and toolchain for each trial.
- Compare positive and negative membership for the same tracked path across actual selected Product app targets. Use conditional source only to demonstrate that file membership is not conditional-declaration membership. Separate manifest/project prediction from observed compiler inputs.
- Bind tracked compiler inputs to exact pinned Git blobs; inventory and classify generated, untracked, external, and unbound transitive inputs without requiring a complete build closure for the narrow membership claim. Repeat from a relocated exact archive or detached copy.
- Test nonexistent target, unknown configuration, failed build, unavailable compiler inventory, changed blob, omitted target input, ambiguous inputs, and outside-repository symlink as fail-closed cases.
- Measure evidence collection cost with trial counts and cold/warm conditions. Preserve complete commands and compact result artifacts; do not infer Product runtime behavior or patch safety from build membership.
- Focused Spikes: [static target membership](spikes/static-target-membership/SPIKE.md), [compiled input inventory](spikes/compiled-input-inventory/SPIKE.md), [compiler identity scope](spikes/compiler-identity-scope/SPIKE.md), and [executed app input membership](spikes/executed-app-input-membership/SPIKE.md). Whole-build reproducibility is outside this decision.

## Decision Criteria

A positive result must name the narrow `selectedBuildMember` scope and bind an executed Swift compiler invocation's exact tracked input path/blob to one explicit Product commit and selected target/module/configuration. It must distinguish `missingFromSelection`, `mismatchedSource`, `ambiguous`, and `unverifiable`; a failed build or missing inventory never produces positive evidence. Compare correctness and false-positive risk first, then read-only behavior, toolchain portability, cold/warm cost, and maintenance burden. If no option proves the narrow claim, keep the ADR open and report `unverifiable` rather than broadening `pinnedSourceDeclaration`.

## Status

Spike Required
