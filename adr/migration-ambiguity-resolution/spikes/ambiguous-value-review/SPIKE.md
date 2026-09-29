# Ambiguous value review

## Related Decision

[ADR.md](../../ADR.md) asks whether production v1→v2 `requiresResolution` input can resume deterministic candidate generation through a machine-readable Human choice bound to the exact historical source, without silent guessing or loss.

## Hypothesis

A typed resolution manifest can select only finite choices enumerated by the historical migrator. A choice may resolve a known ambiguity or explicitly authorize a known loss; it cannot invent semantics for unknown input. Any unresolved blocker prevents candidate generation. This is a test-only hypothesis, not a production contract.

## Questions

- Which real v1→v2 diagnostics admit safe finite choices, and which must remain hard blockers?
- Can a resolution item be identified by diagnostic code, canonical path, entity ID, and relevant historical value fingerprint, while the full manifest is bound to source OID and exact Canonical byte identity?
- Do stale or partial choices fail closed? Are output bytes, classification, diagnostics, unresolved items, and loss records deterministic across reruns?
- If a Human explicitly chooses to discard a cross-kind residual or a distinct duplicate capability declaration, does the review output permanently expose the exact discarded path/value and retain a lossy classification?
- Does an eligible candidate parse and validate as Current v2, while the existing safe automatic v1 path stays unchanged?

## Prototype Scope

Use `MigrationRegistry.analyze` and the production v1→v2 diagnostic codes as the oracle. Test raw historical bytes → analysis → finite candidate enumeration → source-bound resolution → test-only transformation. The candidate manifest has `formatVersion`, `sourceOID`, `sourceCanonicalIdentity`, `sourceFormatVersion`, `targetFormatVersion`, and decisions containing `diagnosticIdentity` and `selectedCandidateID`. A decision selects only an enumerated candidate ID; no arbitrary JSON path/value input is accepted. Candidate metadata includes affected semantic, paths/entities, loss class, and any exact discarded historical value. A candidate is handed to the actual Current v2 reader and `DocumentValidator` only by the outer test harness. `HamiiMigrations` production source remains unchanged.

### Precommitted oracle

The table fixes expected behavior **before** the prototype and evidence run. Every automatic choice is forbidden. `discard` is a test candidate to evaluate, not a product decision. Unknown meanings have zero candidates and remain blocking. A resolved loss must remain visible in candidate metadata and review output. The Current v2 validator rejects duplicate capability declarations for one target/key (`capability.duplicate`), so selecting a padding declaration alone cannot produce a valid v2 candidate while retaining all historical spacing declarations. Distinct duplicates require an explicit, reported loss; identical duplicates may be normalization if their entire semantic declaration agrees.

| Case | Production-derived input | Expected blocker | Enumerated choice allowed? | Explicit loss experiment? | Loss record after candidate? |
| --- | --- | --- | --- | --- | --- |
| A | Two distinct `token.spacing` declarations and padding use | `capability.ambiguousSpacing` | Test selecting one known declaration and explicitly discarding conflicting duplicates | Yes, exact discarded declarations | Yes |
| B | Two equivalent `token.spacing` declarations and padding use | `capability.ambiguousSpacing` | Test selecting one declaration and normalizing exact semantic duplicates | No, only if declarations are fully equivalent | No |
| C | Historical `effect.padding` capability already present | `capability.ambiguousPadding` | No safe reinterpretation assumed | No | Candidate blocked |
| D | Text layer carrying `assetID` | `layer.crossKindResidual` | Test hard block versus exact residual discard | Yes, only exact path/value | Yes |
| E | Multiple cross-kind residuals on different entities | One `layer.crossKindResidual` per residual | One explicit discard per known residual | Yes, independently | Yes, each |
| F | Unknown capability key | `capability.unknown` | No | No | Candidate blocked |
| G | Unknown Layer field | `schema.unknownField` | No | No | Candidate blocked |
| H | Unknown tagged case | `schema.unknownCase` | No | No | Candidate blocked |
| I | Unknown Layer kind | `layer.unknownKind` | No | No | Candidate blocked |
| J | Unknown Canonical path | `path.unknown` | No | No | Candidate blocked |
| K | Ambiguous spacing + residual + unknown capability; resolve only one | All three corresponding blockers | Only A/D choices; F remains zero-choice | D only | No candidate while any remain |
| L | Source S0 + resolution R0; alter historical Canonical bytes to S1 at the same path/entity | Source identity mismatch | No reuse of R0 | No | Candidate blocked |
| M | Existing safe v1 fixture | None; `losslessWithNormalization` | No choice required | No | No |

For A–M, compare the actual production diagnostic code, canonical path, and entity ID with this oracle. Also test nonexistent candidate IDs and duplicate/conflicting decisions. For every candidate-producing case, require exact Current v2 parsing and semantic validation. Apply identical source plus manifest at least three times and compare transformed bytes, classification, diagnostics, unresolved items, decisions, and loss records.

## Out of Scope

GUI editor; production CLI/API or migration schema; `MigrationCandidatePreparer`, `MigrationPublisher`, `WorktreeCoordinator`, CanonicalGeneration, Index publication, CAS/recovery, Git LFS fetch, new Current Format v3 or portable IR semantics. Free-form mapping/JSON patch is a negative comparison control, not a candidate implementation. The Spike prototype does not become production code automatically.

## Measurements

- For each A–M scenario: diagnostic code/path/entity, source binding, candidate count/IDs, selected choice, classification before/after, visible loss, remaining blockers, candidate eligibility, Current v2 validity, and three-run determinism.
- Compare hard block/manual repository editing, typed enumerated-choice manifest, and free-form mapping/JSON patch by silent-loss risk, source binding, determinism, reviewability, partial resolution, AI/CLI suitability, arbitrary mutation surface, and production integration cost.
- Record command, Swift/toolchain and fixture identity, test result, limitations, and exact implementation commit. Do not present test-only timings as production performance.

## Success Criteria

- [x] Production-derived A–M cases are covered; no blocker is silently guessed.
- [x] Safe choices are explicit and finite; unknown meanings can remain unresolvable.
- [x] Resolution is bound to exact source identity; stale and nonexistent choices are rejected.
- [x] Partial resolution remains partial and cannot produce a review-ready candidate.
- [x] Same source and resolution produce identical bytes and reports in at least three runs.
- [x] Explicit Human-approved loss remains observable and is never promoted to lossless.
- [x] Produced candidates parse and validate as Current v2; the safe automatic v1 path is unchanged.
- [x] Production migration/publication source is unchanged; comparison and machine-readable matrix artifacts exist.
- [x] Full local gate succeeds.
- [ ] Exact pushed-SHA CI succeeds (pending evidence commit).

## Failure Criteria

Stop if safe resolution requires arbitrary free-form JSON patching; unknown semantics must be guessed; path/entity alone permits stale resolution reuse; partial resolution produces a candidate; approval hides a loss; new Current v2 semantics are needed solely to preserve unknown v1 data; publication/CAS/recovery changes become necessary; or existing automatic migration behavior changes.

## Result

The precommitted oracle was recorded in `7cd7ff2368037e685818dc34a3607eb270beea4b` before the evidence run. Its exact-SHA CI run `36525898343` succeeded. The [test-only prototype](../../../../Tests/HamiiTests/AmbiguousMigrationResolutionSpikeTests.swift) exercised A–M against actual production `MigrationRegistry.analyze` diagnostics. The final focused local XCTest run executed 3 tests with 0 failures in 0.246 seconds; this is test execution time, not a product performance measurement. The first artifact-writing run failed because the output directory did not exist; creating the Spike artifact directory and rerunning succeeded. Two initial full-gate runs were cancelled after the build stage to add alternative-choice and machine-readable choice metadata assertions. A redundant full-gate start after the successful run was cancelled when only this Markdown report had changed. None of these cancelled attempts is counted as validation.

[The matrix](artifacts/resolution-matrix.json) records every observed diagnostic, candidate set with affected semantic/path/loss class, classification, unresolved count, Current v2 validation, three-run determinism, and exact loss details. A/L produced a valid candidate only by selecting one distinct spacing declaration and visibly discarding the conflicting duplicate (`potentiallyLossy`). Both A choices were tested; each selected support/reason reached the Current v2 padding declaration and the discarded declaration remained reported. B normalized a fully equivalent duplicate (`losslessWithNormalization`). D/E produced valid candidates after explicit residual discard while preserving `potentiallyLossy` and exact historical path/value. C and F–J remained hard blocked with zero choices. K remained blocked after partial resolution. L rejected a manifest after unrelated historical Canonical bytes changed even though the relevant diagnostic item identity remained the same. M preserved the existing automatic result and exact output bytes. Invalid candidate IDs, duplicate decisions, and source OID mismatch were rejected.

The candidate manifest was JSON round-tripped before application. Produced candidates were parsed by the actual Current v2 reader and passed `DocumentValidator`. Production migration/publication sources were not changed. [The workflow comparison](artifacts/resolution-comparison.md) records tradeoffs and the prototype's limits. The local full gate passed all 14 checks in 753.235 seconds: 266 Swift tests executed, 58 skipped, 0 failures. Detailed log: `.build/verify-logs/20260929-053118-397816-36179-full.log` (local, untracked). Exact-SHA CI for the evidence commit is pending.

## Conclusion

The tested evidence supports a bounded typed resolution contract for **known** choices, provided exact source binding, partial-blocker rejection, deterministic candidate generation, and persistent loss reporting remain mandatory. It does not support a universal Human mapping path: historical `effect.padding` and unknown semantics still have zero safe choices. Distinct duplicate spacing declarations and cross-kind residuals demonstrate that a Human choice can be intentionally lossy; approval must not relabel such a result lossless. These results justify comparing the typed contract with hard block at the ADR decision stage after full-gate/CI validation; they do not make this prototype production code.

## Artifacts

- [Machine-readable resolution matrix](artifacts/resolution-matrix.json)
- [Workflow comparison and limitations](artifacts/resolution-comparison.md)
