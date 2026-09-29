# Historical migration resolution contract

## Context

The installed v1→Current v2 edge safely transforms known historical input. `MigrationRegistry.analyze` returns `requiresResolution` blockers for ambiguous or unrepresentable input, and production candidate preparation stops. Human review must not turn unknown historical meaning into a guessed Current value or hide data loss. The source commit remains the Canonical migration base.

## Decision to Make

For historical input classified `requiresResolution` or `manual`, can hamii record a machine-readable Human choice bound to the exact historical source and resume deterministic candidate generation without silent guessing or loss? The choice contract, partial-resolution behavior, and permanent loss visibility are one decision boundary. GUI editing, worktree publication, and Current v3 semantics are outside it.

## Constraints

- Only installed historical-edge knowledge can enumerate meanings. Unknown meaning remains blocking.
- The Human selects a migrator-enumerated candidate; the resolution format is not an arbitrary JSON editor.
- A resolution is bound to the exact source OID and Canonical path/byte identity. Path or entity ID alone is insufficient.
- Every unresolved blocker prevents candidate generation. Human approval never changes a lossy result to lossless.
- Current Core/Format must not import historical parsing. Candidate validation uses the actual Current reader and semantic validator.
- The existing safe automatic v1→v2 path remains unchanged. Migration publication and recovery remain separate responsibilities.

## Options

1. **Hard block and manual repository editing.** Safe default, but decisions and loss may not be machine-readable in the migration workflow.
2. **Typed resolution manifest selecting finite enumerated choices.** Enables reproducible Human decisions for known ambiguities or explicitly approved known loss; unknown meaning still blocks.
3. **Free-form mapping or JSON patch.** General, but creates an arbitrary Canonical mutation surface and cannot inherit the historical edge's finite meaning boundary.

## Current Hypothesis

**Tentative hypothesis before the Spike:** a source-bound typed manifest might resolve some installed-edge blockers without guessing. The [Spike](spikes/ambiguous-value-review/SPIKE.md) tested it. The Decision below records the selected contract; no alternative is being kept open merely because production implementation remains.

## Unknowns

The decision boundary is resolved. The production implementation is under validation. Closure review must confirm the full gate, exact-SHA CI, release builds, current documentation, and absence of remaining work inside this decision boundary. The Spike's test-only helper is evidence, not the production implementation. GUI review is a separate product task. A diagnostic with no safe enumerated choice continues to require an externally prepared and independently validated source; this ADR does not invent a meaning for it.

## Required Evidence

- [Ambiguous value review](spikes/ambiguous-value-review/SPIKE.md), whose A–M oracle was committed before prototype results.
- [Machine-readable matrix](spikes/ambiguous-value-review/artifacts/resolution-matrix.json) and [workflow comparison](spikes/ambiguous-value-review/artifacts/resolution-comparison.md).
- Actual Current v2 parse and semantic validation for every test-produced candidate; unchanged automatic v1 fixture; stale and partial resolution rejection; deterministic reruns.
- Local full gate: 14/14 checks, 266 Swift tests executed, 58 skipped, 0 failures (`.build/verify-logs/20260929-053118-397816-36179-full.log`, local untracked log). Evidence commit `ae6e38809358e20687af39a2888d346f5ffef34e` passed exact-SHA Verify CI run `36527679629` before this decision commit.

## Decision Criteria

Select a contract only if candidate choices are finite, explicit, source-bound, deterministic, and reviewable; unresolved and unknown meaning remain hard blockers; exact loss stays visible with a lossy classification; produced candidates validate as Current v2; and the automatic safe edge is unchanged. Reject a universal mapping surface if it requires guessed semantics or arbitrary Canonical JSON edits. Preserve this Decision and Spike in Git history before implementation, and delete this ADR only under the [ADR workflow](../../docs/adr-workflow.md) closure rules.

## Decision

**Adopt Option 2 for known, finite choices. Retain Option 1 as the required behavior when the installed edge cannot enumerate a safe choice. Reject Option 3 as a migration resolution interface.**

A `MigrationResolutionManifest` is a versioned, machine-readable set of decisions. It identifies the exact committed source by source OID and exact Canonical path/byte identity, declares source and target format versions, and names each resolution item through diagnostic code, Canonical path, entity ID where present, and a relevant historical-value fingerprint. Each decision names a candidate ID emitted by that historical edge. The edge reports affected semantic, paths/entities, and loss class for every candidate. Unknown fields, tagged cases, Layer kinds, capability keys, paths, and historical `effect.padding` without safe interpretation have zero candidates and remain blocking.

No candidate is generated while any blocker is unresolved. A stale source, absent candidate ID, or conflicting/duplicate decision is rejected. Identical source plus resolution must yield identical transformed bytes, diagnostics, unresolved set, decisions, classification, and loss report. A known lossy choice records the exact historical path/value in candidate/review metadata and remains `potentiallyLossy`; approval does not erase loss. Exact semantic duplicate normalization may remain `losslessWithNormalization` if Current validation succeeds. Every produced candidate still passes the actual Current v2 reader, schema/reference/Authoring validation, and migration review workflow before publication.

The [Spike](spikes/ambiguous-value-review/SPIKE.md) demonstrates the contract for tested cases only. In particular, distinct duplicate spacing declarations cannot all be preserved because Current v2 rejects duplicate target/key declarations. Selecting one and discarding another is therefore a visible lossy action. Cross-kind residual discard is an explicit known-loss candidate, not an automatic behavior or a general permission to drop unknown data. Production must implement and validate these rules without importing the test-only prototype wholesale.

## Implementation Progress

`HamiiMigrations` now contains Foundation-only typed resolution schema, finite choice enumeration, strict manifest decoding, and a resolution-aware path that reuses the installed v1→v2 transformer. `HamiiMigrationRuntime` binds reports to clean committed Git source OID and exact Canonical bytes, prepares Current v2 candidates, and persists version 2 review records with decisions and exact losses. Publication revalidates the source, manifest, loss report, and retained candidate bytes before the existing pending/CAS protocol; successful resolved publication retains the local audit. CLI exposes `migrate resolution --json` and `migrate prepare --resolution PATH --json`. The safe automatic path and version 1 review record remain supported. Production domain/runtime tests and CLI smoke cover the new contract. The local full gate passed 14/14 checks, with 276 Swift tests executed, 58 skipped, and no failures in 855.293 seconds (`.build/verify-logs/20260929-064733-426694-91410-full.log`, local untracked log).

## Closure Review

The production implementation is committed as `c2836f5020d40fe994c42da3c6ae673d20a33e9b`. Its exact-SHA [Verify CI run](https://github.com/9uiLe/hamii/actions/runs/36534386070) passed. Local release builds passed for `HamiiMigrations`, `HamiiMigrationRuntime`, and `hamii`; the full gate result above includes architecture, ADR, documentation-link, Swift version/build/test, CLI, sample, and application package checks. Domain tests cover both spacing choices, known loss, zero-choice blockers, partial/stale/invalid manifests, and deterministic output. Runtime tests cover real Git source binding, Current v2 candidate validation, both review versions, tamper rejection before pending, publication, Index binding, and recovery after ref CAS. CLI smoke covers the structured resolution → manifest → review → publish path.

This decision boundary has no remaining implementation or research task. Unknown historical meaning continues to block migration by design. GUI choice editing, a future Format edge, and power-loss durability are separate concerns. The Spike's independent test-only transformer has been superseded by production code and regression tests; remove it with this ADR after this review is preserved in Git history. The current architecture and README already describe the enduring contract without relying on this ADR.

## Status

Implementation Required
