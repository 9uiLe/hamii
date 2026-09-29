# Resolution workflow comparison

## Evidence scope

The evidence-only XCTest prototype uses actual `MigrationRegistry.analyze` diagnostics from the installed v1→v2 edge and the existing `format-v1-safe-project` fixture. It changes historical bytes only in memory. Produced candidates pass through `MigrationRegistry.transform` and then the outer test harness loads them with `CanonicalRepository` and validates them with `DocumentValidator`. No production migration, review preparation, publication, CLI, or Current Format source was changed.

Run: `HAMII_SPIKE_MATRIX_PATH=adr/migration-ambiguity-resolution/spikes/ambiguous-value-review/artifacts/resolution-matrix.json swift test --filter AmbiguousMigrationResolutionSpikeTests`. Local Swift toolchain: 6.4 (`Package.swift` requires tools version 6.4). The final focused run executed 3 tests, 0 failures; XCTest execution was 0.246 seconds. This is a test-only timing and says nothing about production migration throughput. Machine-readable per-scenario results and exact reported loss values are in [resolution-matrix.json](resolution-matrix.json).

## Comparison

| Criterion | Hard block + manual repository editing | Typed manifest selecting enumerated choices | Free-form mapping / JSON patch |
| --- | --- | --- | --- |
| Silent-loss risk | No migration loss while blocked; subsequent manual edits need separate review | Known discarded values remain in explicit loss records; unknown meaning stays blocked | High unless a broad validator and review grammar is added |
| Source binding | Git review can bind a commit, but manual edits have no migration-specific source token | Source OID and exact path/byte identity checked before applying decisions | Possible in principle; not intrinsic to arbitrary patches |
| Determinism | Depends on the external editing workflow | Identical source + manifest yielded identical candidate bytes, classification, diagnostics, unresolved items, decisions, and losses in 3 reruns for tested cases | Possible only with additional patch ordering/validation rules |
| Reviewability | Repository diff shows edits; why a historical meaning was selected may be absent | Diagnostic, affected path/entity, candidate ID, and exact loss are reportable | JSON edits can obscure semantic intent |
| Partial resolution | Human can keep working manually, but no machine-readable partial state | One choice leaves other blockers unresolved and produces no candidate | Easy to accidentally patch around or drop unhandled data |
| AI/CLI suitability | Requires direct repository editing outside the official migration workflow | Structured finite choices can be rendered as JSON without prose parsing | Exposes an arbitrary canonical editing surface |
| Mutation surface | Full repository edits | Only installed historical edge choices | General JSON modification |
| Production integration | No new migration code; Human must construct/validate a result | Requires production item enumeration, manifest schema, exact source binding, report, and candidate integration | Requires a general patch interpreter and broad safety policy |

## Observed boundaries

- A and B both emitted `capability.ambiguousSpacing`. Current v2 rejects duplicate target/key capability declarations. The prototype therefore selected one historical spacing declaration and removed the other before transformation. Distinct values (A) produced a visible exact-value loss and `potentiallyLossy`; fully equivalent values (B) normalized without semantic loss and retained `losslessWithNormalization`. Both distinct A choices were tested: the chosen declaration's support/reason populated both the retained spacing and generated padding declaration, while the discarded declaration remained in the loss report. Choosing a padding support/reason while retaining both spacing declarations would fail Current v2 validation.
- C and F–J had no safely enumerable candidate. Human presence alone did not permit reinterpretation of historical `effect.padding` or unknown capability, field, tagged case, Layer kind, or Canonical path.
- D and E tried explicit discard of known cross-kind residuals. Each discarded path and original value remained in the report, and the classification stayed `potentiallyLossy`; a valid Current v2 candidate was produced only after all such residuals were selected. The test does not decide that this lossy action should be offered in production.
- K combined ambiguous spacing, a cross-kind residual, and an unknown capability. Selecting only spacing left two unresolved blockers and no candidate.
- L changed another Canonical file while keeping the blocker path, entity, and relevant historical declaration unchanged. The old manifest failed the exact-source identity check.
- M retained the production automatic `losslessWithNormalization` result and identical transformed bytes without a resolution decision.
- Nonexistent candidate IDs, duplicate decisions, and a mismatched source OID were rejected. The candidate manifest was encoded and decoded as JSON before use.

## Limitations

The manifest and transformation helpers are test-only. The source OID is a fixture value; a production entry point would have to bind it to the actual Git source. The prototype uses whole containing-file bytes as a conservative fingerprint for unknown fields, but does not claim to interpret their meaning. It does not test worktree publication, CAS, crash recovery, GUI review, LFS fetch, or performance of a production resolution API. SIGKILL and power-loss behavior are outside this decision.
