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

- [ ] Production-derived A–M cases are covered; no blocker is silently guessed.
- [ ] Safe choices are explicit and finite; unknown meanings can remain unresolvable.
- [ ] Resolution is bound to exact source identity; stale and nonexistent choices are rejected.
- [ ] Partial resolution remains partial and cannot produce a review-ready candidate.
- [ ] Same source and resolution produce identical bytes and reports in at least three runs.
- [ ] Explicit Human-approved loss remains observable and is never promoted to lossless.
- [ ] Produced candidates parse and validate as Current v2; the safe automatic v1 path is unchanged.
- [ ] Production migration/publication source is unchanged; comparison and machine-readable matrix artifacts exist.
- [ ] Full local gate and exact pushed-SHA CI succeed.

## Failure Criteria

Stop if safe resolution requires arbitrary free-form JSON patching; unknown semantics must be guessed; path/entity alone permits stale resolution reuse; partial resolution produces a candidate; approval hides a loss; new Current v2 semantics are needed solely to preserve unknown v1 data; publication/CAS/recovery changes become necessary; or existing automatic migration behavior changes.

## Result

Not yet validated. Record observations, failed cases, raw machine-readable matrix, and links to artifacts here after the precommitted oracle is in Git history.

## Conclusion

Not yet validated. Compare the three approaches and state what evidence supports, what remains blocked, and whether the ADR can move to a decision.

## Artifacts

Planned: `artifacts/resolution-matrix.json` and `artifacts/resolution-comparison.md`. Create them only with the evidence commit.
