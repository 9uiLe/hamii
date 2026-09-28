# Changed-entity source capture

## Related Decision

[Incremental Index Recovery](../../ADR.md): determine whether a stale Bound Index and a current coordinated CanonicalSnapshot can yield the exact changed projection-input entities without retaining the old Document.

## Hypothesis

**Tentative:** a versioned inventory of exact captured-file digests, stored atomically with one Bound Index generation, can reconstruct added, modified, and deleted Component, Scope, and Screen sources across multiple saves and process restart. Unknown or corrupt inventory falls back to full rebuild.

## Questions

- Can the prior inventory be bound to the same source identity and IndexGenerationID as published rows?
- Do per-file digests from the Snapshot's captured bytes match an exact-byte oracle for additions, modifications, deletions, and stable-ID rename?
- What historical dependency information remains necessary to turn changed entities into affected rows?
- What do source capture, inventory read, and diff cost at 1000 and 5000 Components?

## Prototype Scope

Use the production CanonicalRepository single-pass acquisition through a DEBUG-only byte callback. A test-only SQLite store commits actual `IndexProjection` rows, descriptor fields, and source inventory in one transaction. Inventory includes all observed Canonical JSON paths so changes outside current v1 projection inputs cause full rebuild fallback. Only `components`, `scopes`, and `screens` can yield a changed-entity set. Compare against exact old/new file bytes retained by the test oracle; use full old/new `IndexProjection` only for changed-row evidence.

## Out of Scope

Production Index schema or recovery changes, targeted projector, affected-row closure, SQLite generation publication design, threshold selection, Git/external-writer adoption, power-loss durability, and Product SLA.

## Measurements

Five runs per 1000-Component, 5000-Component, and mixed fixture at 1/10/100 changed entities: current Snapshot acquisition, digest callback overhead, prior inventory SQLite read, inventory diff, and ChangeSet construction. Record p50/p95, row count, digest bytes, SQLite file size. Full projection oracle is excluded from candidate timing.

## Success Criteria

- The test-only row set, descriptor, and inventory are committed atomically; inventory version and whole-inventory integrity are checked.
- Current inventory uses exactly the bytes captured for decode, validation, and Snapshot identity, without mtime/size equality.
- Added/modified/deleted entities match the exact-byte oracle, including cumulative saves and a new OS process.
- ExplicitlyUnbound, missing/obsolete/corrupt descriptor or inventory, and changes outside v1 projection inputs choose full rebuild.
- A ChangeSet is bound to both old Index source and current Snapshot/generation; a later source transition invalidates it.
- The production full-recovery path and stale-result rejection remain unchanged.

## Failure Criteria

The candidate needs an old full Document, last SemanticPatch, retained save journal, metadata-only equality, a second Canonical read, or unbound-source adoption; or it produces a changed set from mismatched/corrupt inventory.

## Result

**Confirmed in this test-only candidate:** `CanonicalRepository.withStableSinglePassProbe(captureFileDigests: true)` derives SHA-256 per Canonical JSON file from the same captured `Data` used for decode, validation, and Snapshot identity. Every path was captured once; every digest in the ten-case matrix matched a separate exact-byte test oracle. The candidate retains only path/kind/stable ID/digest for the old source, not its full Document, SemanticPatch, or transaction journal. The ordinary probe leaves digest capture disabled, so existing production and benchmark paths are unchanged.

The candidate SQLite transaction stages actual `IndexProjection` rows, the descriptor, source inventory, inventory version/count/whole-inventory digest, and a test-only projection-row digest. A second connection saw the complete old generation before commit and the complete new generation after commit; injected rollback retained the old generation. This tests transaction visibility, **not** production incremental generation publication or power-loss durability. Inventory/descriptor ID and source identity mismatch, wrong inventory or Index schema version, missing entry, duplicate path, invalid digest, missing metadata, and corrupted projection row each caused full-rebuild fallback. `ExplicitlyUnbound` and missing Index were negative controls. No stale rows were returned by this candidate because it never serves Query rows.

The exact-byte oracle and full old/new `IndexProjection` row diff were computed **after** the candidate source set and only for correctness. Matrix results are in [change-matrix.json](artifacts/change-matrix.json):

| Source change | Candidate entity set | Full projection changed rows |
| --- | --- | ---: |
| Component name modify | modified Component | 1 |
| Component availability modify | modified Component | 1 |
| Component add | added Component | 4 |
| Component delete | deleted Component | 4 |
| Screen usage add | modified Screen | 1 |
| Screen usage remove | modified Screen | 1 |
| Scope parent move | modified Scope | 1 |
| Scope add | added Scope | 5 |
| Scope delete | deleted Scope | 5 |
| Stable-ID rename | deleted old Component + added new Component | 8 |

All ten candidate changed-entity sets exactly matched the byte oracle. S0 Index build → coordinated save Component rename → coordinated save Screen usage → S2 recovery yielded both S0→S2 changes without intermediate history. A new OS process reopened SQLite and the Canonical worktree and reconstructed the changed set. A later coordinated save changed the stable generation/identity and invalidated the captured ChangeSet. A manifest-only title/revision mutation changed Snapshot identity but produced no v1 projection entity change; document ID was checked separately. A Token shard change chose full rebuild. This manifest exception is a versioned claim about current `IndexProjection` inputs, not a general claim about future projections.

**Dependency sufficiency for a later affected-row planner:** `ChangedEntitySet` identifies sources; it does not by itself contain the historical edges needed for all affected rows. Current Document and old published rows may supply some values, but a targeted planner must prove their sufficiency separately.

| Source change | Changed set alone enough for affected rows? | Additional old-source evidence likely needed |
| --- | --- | --- |
| Component name | Yes for its component row | None for current v1 row structure |
| Component availability | No | Old availability rows and old reverse Component-definition dependency edges for removed relations |
| Component delete | No for dependent Components | Old reverse definition edges; old availability rows identify direct deleted-component rows |
| Screen usage add | No for exact usage delta | Prior per-Screen Component usage contribution, compared with current Screen tree |
| Screen usage remove | No | Prior per-Screen Component usage contribution, because removed references are absent from current tree |
| Scope parent move | No | Old ancestry/descendant relation or old closure rows, plus current Scope tree |
| Scope delete | No for descendant effects | Old ancestry/descendant relation and old availability/closure rows |

**Measured:** Swift 6.4 debug XCTest on one Apple M1 Pro, arm64 macOS 27.0; local temporary Canonical project and test-only SQLite file. The mixed fixture has 100 Components, 13 Scopes, and 21 Screens. Five sequential runs per cell; nearest-rank p50/p95 in milliseconds. Fixture creation, candidate SQLite publication, Git oracle, full projection correctness oracle, and Query are excluded. `snapshot` includes the digest callback; `baseline` uses the same DEBUG probe with digest capture disabled. `inventory read` includes descriptor/inventory decode and whole-inventory integrity; projection-row integrity read is separate. The complete raw summary is [benchmark.json](artifacts/benchmark.json).

| Fixture / changed Components | Snapshot baseline | Snapshot + digest | Digest callback | Inventory read | Row integrity read | Inventory diff + ChangeSet | Inventory rows / SQLite bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1000 / 1 | 97.40 / 99.30 | 103.56 / 104.44 | 5.66 / 5.68 | 8.78 / 8.83 | 19.48 / 19.56 | 2.53 / 2.59 | 1006 / 643072 |
| 1000 / 10 | 97.90 / 99.92 | 104.72 / 107.74 | 5.69 / 5.82 | 8.81 / 9.35 | 19.44 / 20.71 | 2.56 / 2.63 | 1006 / 643072 |
| 1000 / 100 | 97.67 / 98.00 | 104.45 / 106.12 | 5.68 / 5.81 | 8.78 / 8.83 | 19.45 / 19.49 | 2.58 / 2.60 | 1006 / 638976 |
| 5000 / 1 | 493.03 / 519.46 | 528.76 / 561.06 | 28.78 / 29.54 | 43.73 / 46.15 | 88.71 / 96.10 | 11.40 / 12.13 | 5006 / 3174400 |
| 5000 / 10 | 495.82 / 515.23 | 529.25 / 540.91 | 28.73 / 29.01 | 43.10 / 43.28 | 86.86 / 89.51 | 11.44 / 11.47 | 5006 / 3186688 |
| 5000 / 100 | 497.19 / 542.51 | 529.51 / 543.24 | 28.76 / 29.08 | 43.13 / 43.19 | 86.96 / 87.75 | 11.29 / 12.08 | 5006 / 3153920 |
| mixed / 1 | 12.67 / 12.79 | 13.41 / 13.62 | 0.76 / 0.78 | 1.29 / 1.34 | 6.07 / 6.10 | 0.27 / 0.29 | 136 / 196608 |
| mixed / 10 | 12.60 / 12.62 | 13.51 / 13.75 | 0.76 / 0.79 | 1.28 / 1.32 | 6.00 / 6.04 | 0.27 / 0.28 | 136 / 196608 |
| mixed / 100 | 12.69 / 13.10 | 13.42 / 13.60 | 0.77 / 0.79 | 1.29 / 1.34 | 6.04 / 6.06 | 0.33 / 0.35 | 136 / 196608 |

The SQLite file includes actual projection rows and test schema overhead; it is not pure inventory storage. Digest payload alone is 32 bytes per inventory row (1006 → 32192 bytes; 5006 → 160192 bytes; mixed 136 → 4352 bytes). Per-file SHA-256 overhead scales with file count. The candidate row-integrity scan is deliberately conservative and costly; its design is not selected for production. Five runs and one machine do not define a Product SLA.

**Unknown:** a production inventory schema and write boundary, durable publication under power loss, minimal old dependency evidence, affected row closure, targeted projector, end-to-end incremental recovery, and workload crossover. Non-coordinated external writers are outside this test's Snapshot guarantee; this Spike does not change their Product Contract.

## Conclusion

The tested index-bound source inventory is a viable **source-capture candidate** for a coordinated Bound Index: exact entity changes survived multiple saves and process restart, while unknown/corrupt/unbound cases fell back to full rebuild. The next focused decision input is **Affected Projection Dependency Capture**: determine the smallest old-source summaries needed to map this ChangeSet to complete affected row keys. No production incremental path is selected. The parent ADR remains **Spike Required** and production full recovery/fail-closed Query are unchanged.

## Artifacts

- [ChangedEntitySourceCaptureSpikeTests.swift](../../../../Tests/HamiiTests/ChangedEntitySourceCaptureSpikeTests.swift): DEBUG probe, test-only SQLite store, exact-byte/oracle matrix, restart, negative controls, atomic transaction visibility, benchmark.
- [change-matrix.json](artifacts/change-matrix.json): ten source changes and actual full-projection row differences. Regenerate with `HAMII_SOURCE_CAPTURE_MATRIX_RESULT=/tmp/hamii-source-capture-matrix.json swift test --filter ChangedEntitySourceCaptureSpikeTests/testChangeMatrixAgainstExactBytesAndProjectionRows`.
- [benchmark.json](artifacts/benchmark.json): five-run raw timing summaries. Regenerate with `HAMII_SOURCE_CAPTURE_BENCHMARK_RESULT=/tmp/hamii-source-capture-benchmark.json swift test --filter ChangedEntitySourceCaptureSpikeTests/testMeasuredSourceCaptureCost`.
