# Product Mapping Locator

## Context

An authoritative `RepositoryProfileReceipt` pins one Product commit and Profile blob to one hamii observation. Profile v1 mapping values are free strings. A nonempty value can satisfy structural planning but does not identify a Product declaration or resource with machine-verifiable meaning. [Product Integration Contract](../product-integration-contract/ADR.md) owns the later Product validation gate; [Repository Profile Persistence](../repository-profile-persistence/ADR.md) owns Product Profile placement and receipt identity. This ADR narrows the locator schema required before a read-only source validator can claim verified mappings.

## Decision to Make

What is the smallest Product-owned Profile mapping locator schema that uniquely and reproducibly identifies an expected-kind source or resource within a pinned Product commit?

## Constraints

- Product architecture, source paths, model/action/route names, and compiler identities remain outside hamii Core IR.
- Profile format version is independent of Document format v3.
- Profile v1 free strings remain valid for external and authoritative **structural-only** planning; they do not become source-verified or patch-authorizing locators by reinterpretation.
- Zero or multiple matches, wrong declaration kind, invalid path, stale receipt, and unprovable lookup fail closed. Locator resolution reads immutable Git objects and does not modify the Product worktree.
- `verified`, `missing`, `ambiguous`, `invalidLocator`, `kindMismatch`, and `unverifiable` are distinct source-evidence outcomes. A missing Profile key remains `missingMapping`; a present but nonexistent target is `invalidMapping`. `conflictingMapping` from semantic behavior such as I03 is a separate Product audit result.
- This decision does not choose Product patch generation/publication, runtime behavior validation, or Product build policy beyond measuring locator prerequisites.

## Options

1. Qualified semantic symbol without a file path.
2. Tracked Product-root-relative file path plus declaration kind and enclosing/member path.
3. Compiler/index identity such as USR, symbol graph, or IndexStore identity.

Git line numbers and raw substring matches are evidence controls, not source authority candidates.

## Current Hypothesis

**Tentative:** A tracked file plus typed declaration locator may provide the narrowest build-free, fail-closed first version. It makes file moves explicit Profile edits. This hypothesis requires direct comparison with same-name declarations, local/internal cases, clone/relocation, and compiler-derived alternatives before a decision. No Profile v2 schema or validator is committed here.

## Unknowns

- Which locator represents Team MINO's `Profile.nickname`, optional `Profile.createdAt`, reducer action, and coordinator route without guessing scope or declaration kind?
- Whether the same locator shape applies to another architecture such as Food Truck or SyncUps.
- Which Swift constructs need a compiler parse/index to distinguish overloads, extensions, local declarations, or generated symbols?
- Whether compiler identity can be reproduced from an immutable commit without a costly or environment-specific build.
- What reviewed Product Profile v1→v2 migration input is needed if a typed locator is chosen.

## Required Evidence

Compare all options against Team MINO iOS commit `dca2202f4be21869190d19bbcf223eb8646a2acd` and at least one other pinned Product repository. Record exact source files and candidate locators. Exercise duplicate names, deletion, file move, symbol rename, wrong kind, commit change, exact clone/relocation, symlink/path traversal, and internal/member/enum-case constructs. Measure build/index requirements, environment dependencies, and lookup cost with conditions and trial count. Keep controls and prototypes under focused Spikes: [qualified semantic symbol](spikes/qualified-semantic-symbol/SPIKE.md), [tracked file declaration](spikes/tracked-file-declaration/SPIKE.md), and [compiler/index identity](spikes/compiler-index-identity/SPIKE.md).

## Decision Criteria

Prefer a locator that identifies exactly one expected-kind target from the pinned commit, rejects stale/ambiguous/malformed evidence, is independent of absolute checkout path, and is practical for common Product constructs. Account separately for initial complexity, file move/rename UX, build/index cost, and future extension. If none meets this boundary, leave the decision open and narrow the missing evidence. A later implementation must emit typed source evidence separately from structural `IntegrationMappingStatus` and keep Profile v1 structural-only.

## Status

Spike Required
