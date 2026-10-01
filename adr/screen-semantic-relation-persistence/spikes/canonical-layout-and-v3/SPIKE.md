# Canonical Layout and v3 Spike

## Related Decision

[Screen Semantic Relation Persistence](../../ADR.md): where screen typed semantics belong in Canonical IR and how older formats migrate without inferred meaning.

## Hypothesis

**Tentative:** storing declared sources, outputs, and relations in the existing Screen shard makes exact observation and transaction recovery simpler than a new sidecar. A declared output can anchor a relation to one existing screen binding/input.

## Questions

- Can an output declaration uniquely identify an existing screen input/binding and reject absent, duplicate, or dangling references?
- Can Screen-shard and sidecar candidates round-trip typed semantics and project all fields into `IntegrationContract` without inference?
- Does a relation edit change Canonical identity under each layout?
- Does the current v2 reader reject v3, and can a future v3 reader reject raw v2 pending migration?
- Can a lossless v2→v3 edge compose with the installed v1→v2 edge while preserving unrelated shard/blob bytes?
- Which actual path, journal, Git freshness, and migration publication rules change under each layout?

## Prototype Scope

Use test-only candidate schema and raw JSON fixtures. Run against the current repository's reader and migration code where possible. Compare Screen-shard A and Screen-owned sidecar B without changing production format markers, Core types, or CLI behavior. Candidate output anchoring may compare semantic input references with direct layer/property references, but may not contain Product symbols.

## Out of Scope

Production Format v3 implementation, Product Repository mapping validation, Product runtime behavior, source generation, relation inference from v2 bindings or interactions, power-loss proof, and migration publication changes.

## Measurements

Record case counts and pass/fail for anchor validity, semantic round-trip, extraction, identity, reader rejection, migration path, and unchanged bytes. Record touched production boundaries for A and B. Benchmark timing is not a decision criterion for this small fixture; do not present prototype runtime as product performance.

Run `python3 adr/screen-semantic-relation-persistence/spikes/canonical-layout-and-v3/artifacts/run.py` from the repository root. The runner temporarily copies its Swift fixture into the test target, runs only `CanonicalLayoutSpikeTests`, and removes the copy afterward. Evidence below was measured on macOS with Swift 6.4, using the v1 safe-project fixture and a temporary v2 repository. It is not a throughput benchmark.

## Success Criteria

- Empty/duplicate output or source key, missing binding anchor, undeclared relation output, missing relation/visibility dependency, and duplicate relation are rejected.
- A declared output anchors one existing input/binding; typed sources/outputs/relations survive encode→decode→encode and project into the screen contract exactly.
- A one-value relation edit changes candidate Canonical identity; current v2 reader rejects a v3 manifest, and candidate v3 reader refuses raw v2 as Current.
- v2→v3 adds no inferred relation. v1→Current has a deterministic, validated path. Unrelated Canonical shard/blob bytes remain identical.
- Every new path or changed schema has explicit snapshot, client precondition, Git freshness, journal, reader, and migration implications.

## Failure Criteria

Any false accepted dangling/ambiguous anchor, silent reader downgrade, synthesized relation during migration, ignored sidecar in identity, missing v1→Current path, or unaccounted transaction path blocks a decision.

## Result

**Measured, test-only:** Five focused XCTest cases passed, zero failed. Fourteen invalid direct-Screen output/source/relation/anchor variants were rejected: empty or duplicate source/output keys, missing or duplicate layer/property anchor, wrong binding, undeclared output, missing relation or dependency, non-Boolean visibility source, and duplicate relation. The valid candidate projected existing `inputs` through production `IntegrationContracts.make` and attached the candidate's exact typed sources/relations in a test-only projection helper. The helper is not production extraction. Component-instance internals are outside the prototype's direct-Screen anchor set; a bare definition Layer ID would not uniquely identify an instance.

Both candidate layouts survived sorted-key encode→decode→encode with identical candidate bytes. Editing one `whenNil` value changed `CanonicalByteIdentity` in each *supplied file set*. This proves the pure identity function distinguishes changed bytes when the caller includes the file; it does not establish that production enumerates a sidecar. Conversely, the actual v2 `Screen` decoder accepted candidate A JSON but discarded its unknown `semantics` on re-encode. A v3 marker is mandatory before adding fields to the current reader.

The actual v2 `CanonicalRepository.load` rejected a v3 manifest with `unsupportedFormat(3)`. A test-local v3 header guard rejected a raw v2 manifest. The installed `MigrationRegistry.transform` upgraded the safe v1 fixture to v2. A test-local marker-and-Screen v2→v3 transformer then produced deterministic v3 candidate bytes, added **empty** sources/outputs/relations, preserved all non-Screen/non-manifest shard bytes and an injected repository blob byte-for-byte, and left `versions.integrationProfile` unchanged. This demonstrates sequential edge *composability in a prototype*, not an installed v1→Current-v3 path: production `MigrationRegistry.transform(v1, to: 3)` still rejects. Migration runtime preparation/publication also assumes v2 and one edge.

**Failure evidence for unregistered sidecar B:** Writing `integration/screens/example.json` to a real temporary v2 repository changed neither the production `CanonicalSnapshot.identity` nor its `ClientPrecondition`. The current `canonicalJSONPaths` only lists one-level known folders ([CanonicalRepository.swift](../../../../Sources/HamiiFormat/CanonicalRepository.swift)); `CanonicalTransaction.currentFiles` and `validPath` similarly exclude a nested sidecar ([CanonicalTransaction.swift](../../../../Sources/HamiiFormat/CanonicalTransaction.swift)). [GitCanonicalRevisionCalculator.swift](../../../../Sources/HamiiIndex/GitCanonicalRevisionCalculator.swift) omits it from Git pathspecs, and [MigrationRepositoryInput.swift](../../../../Sources/HamiiMigrations/MigrationRepositoryInput.swift) omits its folder. B requires these boundaries and validated Document ownership to change together. Updating only path enumeration would make `transaction.preflight` disagree with `encodedFiles(Document)`.

| Boundary | A: Screen shard | B: Screen-owned sidecar |
|---|---|---|
| Canonical paths and byte identity | Existing `screens/<id>.json` path is observed; v3 reader/encoder and manifest gate must change together. | New nested path, capture/decode/encode, filename↔Screen ID and orphan validation, client token and snapshot inclusion are required. |
| Save journal/crash recovery | Existing Screen shard and manifest can use the current path/plan mechanism after a v3 writer is installed; checkpoint tests remain required. | Journal `currentFiles`, `validPath`, temporary cleanup, directory sync, install, and recovery must accept the sidecar as one transaction with the manifest. No crash proof was run. |
| Git/index freshness | Existing Screen pathspec covers A; changed candidate bytes feed identity only after the v3 reader validates them. | Git tracked/dirty/untracked pathspecs and migration input must include B before any current result can be trusted. |
| Diff/upgrade cost | Relation edit changes the Screen aggregate; v2→v3 rewrites affected Screen shards to add empty semantics. | Relation edits can be isolated; v2→v3 can retain Screen bytes but adds new owned sidecars and more path/transaction rules. |

**Inferred from code, not experimentally proven:** A has the smaller path and journal change surface. B is feasible only after the additional rules above are implemented and tested together. Neither candidate is production-ready from these five tests.

The prototype imports typed relations from `HamiiIntegration` only because it lives in a test target. Current `HamiiCore` cannot depend on `HamiiIntegration` ([Package.swift](../../../../Package.swift)); a production Screen-owned type must move the Product-independent semantic definitions into Core and project outward. `ComponentResolver` retains definition Layer IDs across instances ([ComponentResolver.swift](../../../../Sources/HamiiCore/ComponentResolver.swift)), so the prototype intentionally validates only direct Screen layers. An instance path or a different unambiguous anchor is still required before component-internal outputs can be declared.

## Conclusion

The initial evidence favors A but does **not** select it. At the time of this Spike, output anchoring for component instances, production v3 ownership/validation, a real v1→Current migration route and migration publication, and journal stop/recovery tests were unresolved. In particular the installed registry had no v1→3 route. The subsequent [Component output anchor Spike](../component-output-anchor/SPIKE.md) tested occurrence-safe anchors; [Migration Edge Composition](../../../migration-edge-composition/ADR.md) now owns the independent route/publication question. At the time of this Spike, the persistence ADR remained `Spike Required`; the subsequent Screen shard decision moved it to `Implementation Required`. Do not treat the sequential test-only transform as production edge chaining or write typed relation fields under the v2 marker, because the v2 Screen decoder drops them.

## Artifacts

- [CanonicalLayoutSpikeTests.swift](artifacts/CanonicalLayoutSpikeTests.swift): test-only candidate schemas, validator, projection helper, version/identity/migration probes.
- [run.py](artifacts/run.py): reproducible focused runner that leaves no test-target file behind.
