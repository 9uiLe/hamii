# Ordered Edge Publication Spike

## Related Decision

[Migration Edge Composition](../../ADR.md): how an isolated migration subsystem can turn several reviewed format edges into one source-bound, reviewable, publishable Current-format candidate and recover it.

## Hypothesis

**Test-only candidate:** an ordered sequence of adjacent edges can produce one final candidate commit if the route is unique, each edge emits a receipt bound to exact input/output bytes, and review/publisher/recovery independently verify the entire path from the original source commit. Git ref compare-and-swap remains the only Canonical publication commit point; intermediate v2 bytes are never published as a source ref.

## Questions

- Can v1→v2→synthetic v3 and v2→synthetic v3 be resolved uniquely and transformed deterministically without modifying the installed registry?
- Can a Human resolution manifest bound to v1→v2 remain local to that edge while the final review target is v3?
- Can one persisted review bind original source OID/tree/identity, ordered edge receipts and loss audit, final candidate OID/tree/identity, and changed paths?
- Does independent publisher re-execution from the original source reject changed source, intermediate/final bytes, route/receipt, resolution, and candidate tampering?
- At representative stops around ref CAS and Index publication, does recovery converge to old or final state without exposing intermediate v2?

## Prototype Scope

The artifact uses the installed production `MigrationRegistry.transform` for the real v1→v2 edge. It adds a test-only edge catalog, route resolver, synthetic lossless v2→v3 transformer, strict v3 marker/empty-semantics validator, Git candidate/review/publisher/recovery harness, and Index binding double. The synthetic edge changes only manifest `formatVersion`/`versions.document` and adds empty `sources`, `outputs`, `relations` to Screen shards; it infers no relation from v2 binding or state. Publication uses an immutable candidate commit retained under a test ref, a pending gate, `git update-ref` CAS, worktree materialization, final identity validation, and an Index double bound to final identity/generation/document ID/revision. Run `python3 adr/migration-edge-composition/spikes/ordered-edge-publication/artifacts/run.py` from repository root. The runner temporarily copies the Swift fixture into the test target and removes it afterward.

## Out of Scope

Production migration code, production v3 reader/schema, production Index v3 projection, CLI, arbitrary external writers, SIGKILL, power-loss/fsync durability, throughput claims, and a final ADR Decision. The harness uses exception injection and test-local gate/index files; it is publication orchestration evidence, **not** evidence that production `CanonicalRepository` reads v3 or production `MigrationPublisher` supports multiple edges.

## Measurements

Record route outcomes, exact final byte identity, ordered receipt fields, loss audit, Git OIDs/tree binding, negative revalidation outcomes, pending/ref/worktree/index state for S1–S5, second recovery result, and whether an unrelated binary remains byte-identical. The initial focused XCTest run on macOS/Swift 6.4 executed **7 tests, 0 failures** in 51.242 seconds after a 3.65-second incremental build. An independent review then found the missing historical-source/Current-query distinction, unrelated resolution acceptance, and pending-record misclassification case. The first expanded run failed because two encodings of the same review were compared as raw JSON bytes with nondeterministic key order; the harness now uses sorted keys for this persisted review. The corrected focused run executed **8 tests, 0 failures** in 55.965 seconds. A separate one-test reproduction of the pending-record case passed in 3.247 seconds. These are fixture correctness runs, not product performance measurements.

## Success Criteria

- Exactly one route exists for v1→v3 and v2→v3, no-op v3→v3 is empty, and missing/ambiguous/invalid catalogs fail closed without implicit priority.
- Two runs over identical source bytes produce identical final bytes/identities and ordered receipts. Each receipt records `sourceVersion`, `targetVersion`, `edgeID`, `inputIdentity`, `outputIdentity`, `classification`; adjacent receipts join exactly.
- v1 Human resolution remains bound to 1→2, and its decision/loss audit travels with the final v3 review without reinterpretation by 2→3. A resolution supplied to a route without that edge is rejected.
- Publisher and post-CAS recovery recompute the full route from the original source commit and compare final bytes to the retained commit. The source ref is never set to intermediate v2.
- Before CAS, recovery preserves old historical source; this abort may clear the publication pending record but must not make the historical source available to Current-format queries. After CAS, recovery rolls forward to the validated final candidate. A Current-format query remains gated until a matching Index generation is available; repeated recovery does not publish a second Index generation.

## Failure Criteria

An ambiguous route chosen automatically, unbound per-edge resolution, accepted tampered receipt/candidate, intermediate v2 ref publication, stale/wrong Index accepted, or gate release before final identity validation blocks Option 1. A test-local success must not be reported as production v3 or power-loss proof.

## Result

**Measured route matrix:**

| Catalog/request | Result |
|---|---|
| installed 1→2 + synthetic 2→3; 1→3 | `1->2`, `2->3` |
| same catalog; 2→3 | `2->3` |
| same catalog; 3→3 | empty path |
| missing 2→3 | `noPath` |
| add direct 1→3 alongside composed route | `ambiguousPath` |
| backward/cyclic edge, self edge, duplicate 1→2 | rejected as invalid catalog |

The route resolver uses a test-only monotonic version rule (`source < target`) to reject backward/cyclic edges. It does not choose the shortest or direct route. Both v1→2→3 and v2→3 ran twice over identical exact source bytes and yielded identical final bytes and receipts. With an injected binary in the pure file set, both yielded final Canonical-byte identity `b04a84cc4521eb3804125f42138fb4670321f583ebec8fd91b05d33379916026`; without that binary in `MigrationRepositoryInput` (which intentionally excludes `assets/blobs`), the repository publication identity was `d19c6485b7515a023f5d7e256795c8b7ffff2a670927c1e480aee56dfa3a19e6`. These are different **input file sets**, not inconsistent hashing. The Git worktree's binary remained byte-identical across publication/recovery. For each 2→3 edge, every shard outside `hamii.json` and `screens/` matched its v2 input bytes. The strict test-local v3 validator rejected raw v2.

**Receipt/review binding:** each review records original source ref/OID/tree/identity/format, final target format, exact ordered receipts and their classifications, optional v1→2 resolution manifest plus selected decisions/losses, final candidate OID/tree/identity, changed paths, and retention ref. A v1 ambiguity fixture required an explicit `MigrationResolutionManifest` with `sourceFormatVersion=1`, `targetFormatVersion=2`; automatic preparation was rejected. With one selected choice, final review target was v3, the 2→3 receipt was `lossless`, the v1 edge recorded one loss, and publisher recomputation accepted the exact decisions. Example observed resolution case: source OID `a09eb6e45d5804512a5dab1250aac93ca833871c`, candidate OID `2ba96919fa0f071b202f02e021a354c90fde774e`, final Canonical identity `d19c6485b7515a023f5d7e256795c8b7ffff2a670927c1e480aee56dfa3a19e6`. Git commit OIDs depend on test commit timestamps and are run-specific; byte identities are deterministic for the stated file sets.

**Publisher negative matrix:** changing edge order, edge ID, source identity, per-edge classification, final identity, candidate tree/OID, changed paths, or v1 resolution choice was rejected. A v1→2 resolution supplied to the v2→3-only route was rejected. External mutation of source bytes after review was rejected. A maliciously altered intermediate v2 Screen produced a different final v3 candidate and was rejected by publisher recomputation from the original source. Altering the retained candidate ref to a commit with changed final Screen bytes was rejected. No pending gate or source ref update followed these prepublication failures. After CAS, tampering with an embedded receipt or rewriting the pending record to misclassify the published candidate as the old source caused recovery to retain the gate; restoring the exact record allowed roll-forward.

**Exception-injection stop matrix:**

| Stop | Source formats run | Ref at stop | Worktree / Index at stop | Recovery |
|---|---|---|---|---|
| S1 pending, before CAS | v1, v2 | old OID | old bytes; no Index | old retained; pending cleared; Current query rejected |
| S2 after CAS | v1, v2 | final candidate OID | old bytes until materialization; no Index | final v3 roll-forward |
| S3 materialized | v1 | final OID | final v3 bytes; no Index | final revalidated; Index bound |
| S4 canonical verified | v1, v2 | final OID | final v3 bytes; no Index | final retained; Index bound |
| S5 Index published, before gate release | v1 | final OID | final v3; bound Index; gate present | gate cleared; same Index ID/generation |

Every stop had a pending gate that refused Current queries. After S1 recovery, the old historical format still refused Current queries without a matching Current Index. Candidate-side recovery made Current queries available only after validating v3 bytes and Index identity, generation, document ID, and revision. A second recovery returned the same ref and did not change Index ID/generation. Representative S2 observations: v1 source OID `7be849a659e0538c1df5c6816d5eba1e2c9d5ae2` → final OID `b0b9f8eb04e54d273d6e32692ba963f620a68b66`; v2 source OID `a858d2765a50bf0e6f664952a943952109fb93f6` → final OID `384b6f823b38d05e36e03038ab197a50b51862c0`; both recovered to final identity `d19c6485b7515a023f5d7e256795c8b7ffff2a670927c1e480aee56dfa3a19e6`. These are test Git repositories. A source ref that was neither old nor candidate stayed gated with `unknownSource`; a correct candidate ref with dirty worktree was rematerialized from the retained commit while gated. A test Index bound to a different Canonical identity caused recovery to fail with gate retained.

**Implementation boundary at the time of the Spike:** production `MigrationCandidatePreparer` and `MigrationPublisher` then hard-coded source 1, target 2, `edgePath == ["1->2"]`, and Current reader v2. The Spike's successful test-only review and recovery do not remove those production constraints. A future implementation must reuse historical edges through the Migration boundary, bind every edge's classification/resolution to immutable review, and adapt candidate validation/index publication to Current v3 without moving historical models into Core.

## Conclusion

The tested ordered adjacent-edge candidate satisfies the focused route, transformation, review/recomputation, and exception-injection publication criteria for these fixtures. It supports moving the ADR to **Ready for Decision**, without selecting Option 1 in this Evidence commit. The production format, migration runtime, and Index remain v2. Power-loss guarantees remain governed by the separate durability decision.

## Artifacts

- [OrderedEdgePublicationSpikeTests.swift](artifacts/OrderedEdgePublicationSpikeTests.swift): test-only catalog, real v1→v2 adapter, synthetic v2→v3 edge, review/publisher/recovery harness, tamper and stop matrices.
- [run.py](artifacts/run.py): reproducible focused runner, with temporary test-target copy removed on completion.
