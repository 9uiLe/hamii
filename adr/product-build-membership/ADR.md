# Product Build Membership Evidence

## Context

An authoritative Product Repository Profile v2 can identify one explicitly written Swift declaration in a receipt-pinned Git blob. The read-only validator reports `pinnedSourceDeclaration` evidence for this restricted claim. It does not establish that the declaration belongs to a selected Product build. Product targets, modules, configurations, conditional compilation, generated files, dependencies, and toolchains can change that answer without changing the declaration locator. The current boundary is documented in `docs/final-architecture.md` and `docs/integration-profile.md`.

## Decision to Make

What reproducible, fail-closed evidence is sufficient to prove that a source-verified direct Swift declaration's exact pinned path and blob participate in the compiler inputs of an explicitly selected Product target, module, and configuration?

## Constraints

- Keep Product build metadata and repository-specific architecture outside hamii Core IR.
- Preserve the existing `pinnedSourceDeclaration` evidence scope. A later `selectedBuildMember` result must be additive and must not imply type correctness, runtime behavior, semantic mapping correctness, or permission to generate or publish a Product patch.
- Bind the selected Product commit, source blob, target/module, configuration, architecture, SDK, toolchain, flags, dependency resolution, and generated or transitive inputs where the claim depends on them. Unknown or mismatched inputs must be `unverifiable`, not `verified`.
- A static project or package declaration predicts membership but does not by itself prove an executed compiler input. A compiler symbol without a pinned input set does not establish current membership.
- Read-only validation must not mutate the Product worktree or treat an unpinned worktree file as source authority. Builds, if required for evidence, must run in isolated disposable locations with bounded resource and time costs.
- Profile v1 remains structural-only. Resource and Native mapping evidence have separate decision boundaries.

## Options

1. Static SwiftPM manifest and Xcode project/target membership with resolved settings.
2. Selected build plan, Swift compiler invocation, or explicit compiler file list tied to pinned Git blobs and build inputs.
3. Compiler index, symbol graph, or comparable compiler-produced declaration identity tied to a selected build and complete input inventory.
4. A staged combination: static selection for early rejection, followed by compiler-input evidence for a positive membership claim.

## Current Hypothesis

**Tentative:** An exact selected-build compiler input inventory, checked against receipt-pinned Git blobs and the resolved target/configuration/build environment, may support a narrow `selectedBuildMember` claim. Static metadata may reject obvious nonmembers cheaply; compiler/index identities may corroborate a build. The minimum reproducible inventory and a reliable way to obtain it are not yet established. No option is selected.

## Unknowns

- Whether Xcode and SwiftPM expose a stable, portable selected-build input inventory without relying on private output conventions.
- Which transitive inputs must be pinned or recorded before a positive claim is reproducible: manifests, package resolution, dependent modules, generated Swift, resources, plugins, SDK, compiler version, flags, and environment.
- How conditional compilation and target membership interact when the same source path is present in multiple Product targets or configurations.
- How to handle app/Widget targets, multi-architecture builds, build-system caches, and a relocated exact clone.
- Cost of cold and warm evidence collection, and whether a read-only Product validation workflow can bound that cost acceptably.
- Whether compiler/index identities add trustworthy information after a complete selected-build input inventory, or only duplicate it.

## Required Evidence

- Use receipt-pinned clean Product commits from Team MINO and Food Truck. Record exact target/module/configuration/architecture and toolchain for each trial.
- Compare positive and negative membership for the same tracked path across selected targets/configurations, including conditional declarations. Separate manifest/project prediction from observed compiler inputs.
- Bind tracked compiler inputs to exact pinned Git blobs; identify generated and transitive inputs that cannot be pinned by this method. Repeat from a relocated exact clone.
- Test stale commit, changed blob, omitted target input, untracked or externally generated input, ambiguous target, and incomplete build inventory as fail-closed cases.
- Measure evidence collection cost with trial counts and cold/warm conditions. Preserve complete commands and compact result artifacts; do not infer Product runtime behavior or patch safety from build membership.
- Focused Spikes: [static target membership](spikes/static-target-membership/SPIKE.md), [compiled input inventory](spikes/compiled-input-inventory/SPIKE.md), and [compiler identity scope](spikes/compiler-identity-scope/SPIKE.md). Add a focused app/configuration or transitive-input Spike if these leave the decision unsupported.

## Decision Criteria

A positive result must name its exact evidence scope and be reproducible from pinned Product inputs for one explicit selected target/module/configuration. It must reject known counterexamples and distinguish missing, wrong target, mismatched, and unverifiable evidence. Compare correctness and false-positive risk first, then read-only behavior, toolchain portability, cold/warm cost, and maintenance burden. If no option proves the narrow claim, keep the ADR open and report `unverifiable` rather than broadening `pinnedSourceDeclaration`.

## Status

Spike Required
