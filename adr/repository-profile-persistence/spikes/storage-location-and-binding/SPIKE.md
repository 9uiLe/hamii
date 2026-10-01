# Storage Location and Binding Spike

## Related Decision

[Repository Profile Persistence](../../ADR.md): where Profile authority lives and how its repository/source identity and format version are bound.

## Hypothesis

A Git-reviewable Profile can be replayed after branch switch, but neither file location nor `repositoryName` alone proves that mappings apply to the Product source state. The required binding and writer guarantees must be measured before selecting a placement.

## Questions

- Does the same Profile v1 reproduce after checkout/branch switch in each placement?
- What happens when Product source changes while Profile bytes remain unchanged?
- Which identity changes for a mapping-only edit, and which changes for an unrelated Product edit?
- Can a Profile change be reviewed independently and coordinated with hamii saves/Git transitions?
- Which missing, malformed, stale, and wrong-repository cases can be rejected mechanically?
- How can v1→future Profile migration remain independent of Document migration?

## Prototype Scope

Use one Profile v1 and temporary hamii/Product Git repositories. Place the same bytes in a hamii Canonical root shard, a Product repository file, and an external file. For each placement, record Git tree/OID, raw Profile content identity, hamii CanonicalSnapshot identity when applicable, branch behavior, a mapping-only diff, and an intentionally stale or wrong Product binding. Test existing `IntegrationProfileFile` validation and current `integration plan` separately from any test-only binding prototype. Use isolated temporary paths and preserve all existing Canonical projects.

## Out of Scope

Production Profile writer, Product source patches, P0–P4 runtime behavior, I03 visual conflict, Human correction, build/test execution protocol, and a general Profile schema migration implementation.

## Measurements

Record case, option, starting and resulting Git OIDs/branches, exact Profile bytes identity, observed Canonical identity, planned binding verdict, structured failure category, and review diff. Measure elapsed time only if the prototype actually times a comparable operation; do not infer product performance from a test harness.

## Success Criteria

Evidence distinguishes actual guarantees from assumptions for every option. The tested binding rejects stale and wrong-repository Profiles, branch switching reproduces a reviewed mapping, and mapping-only edits have an identifiable authority change. Candidate version behavior is independent of Document version.

## Failure Criteria

Any option silently accepts a known stale/wrong-repository Profile, treats local-only bytes as shared authority without a reproducible source, or claims atomicity from a sequential test without a coordination boundary. Incomplete coverage remains an explicit unknown, not a passing result.

## Result

**Observed, 2026-10-02:** `python3 artifacts/reproduce.py` completed against the locally built CLI and three disposable Git repositories. [The script](artifacts/reproduce.py) contains assertions and [the result](artifacts/results.json) records one run's OIDs and verdicts. This is a correctness experiment, not a latency benchmark or production writer test. Three independent read-only code audits of the three placement candidates preceded the run; their findings were checked against the cited code below.

| Placement | Checkout/review observation | Current authority gap |
| --- | --- | --- |
| hamii root file | Git branch changed the Profile bytes and checkout restored them. A Profile-only byte edit and branch change left `inspect.statePrecondition` unchanged. | `CanonicalRepository.canonicalJSONPaths` lists `hamii.json`, optional agent profiles, and known shard folders, but no Profile root file. The same omission affects Snapshot identity, save journal, strict v3 decode, and Git freshness pathspec. Merely committing the new file does not make it Canonical. |
| Product tracked file | Checkout of the base commit restored identical Profile bytes. Mapping-only edit produced a one-file Git diff and a new Profile blob OID. Product source-only edit changed commit OID while retaining the Profile blob. | Current CLI still accepted a plan after source changed, and accepted the same Profile while a different Product repository was the intended target. The CLI has no Product repository input or source binding. |
| caller-selected external file | Initially identical bytes to the Product tracked file; external edit changed bytes and CLI accepted the new valid value. | A path and `repositoryName` provide no replayable Git authority on their own. Current plan JSON does not carry the selected Profile content identity or Product OID. |

**Negative controls:** missing file returned `storage`, malformed JSON returned `contract`, and Profile `formatVersion: 2` returned `migrationRequired`. These are existing Profile v1 format checks; none establishes Product repository identity. A test-only `(Product HEAD OID, tracked Profile blob OID)` comparison rejected the measured source change, mapping change, and different repository. A documentation-only Product commit changed HEAD while leaving Product source and Profile blobs unchanged, so exact HEAD equality also causes a false-positive invalidation. This test-only pair is **not** a chosen production binding algorithm.

**Code evidence:** `IntegrationProfileFile.load(at:)` validates the selected v1 bytes but only checks that `repositoryName` is nonempty. `HamiiCLI` reads the Document first, then reads the selected Profile separately, and `IntegrationPlan` has no Profile or Product source identity field. `CanonicalRepository.canonicalJSONPaths` omits an arbitrary root Profile path. `docs/integration-profile.md` states that the explicit file is read-only and not Canonical; it also says the Profile is an assertion rather than proof that a Product symbol exists. These facts explain the observations without treating a prototype comparison as production behavior.

**Inferred requirement, not yet implemented:** a production plan needs a captured Profile identity and a Product repository/source identity, then must revalidate both before any Product patch. A Product-owned tracked Profile naturally shares Git review and checkout with Product source, but tracked placement alone does not validate mappings or prevent a source change between plan and use. A hamii-owned Profile could be made Canonical only by extending the same capture, transaction, migration, and client precondition boundaries. An external file could be authoritative only with a separate explicit durable binding and review protocol.

**Unknown / untested:** concurrent hamii save versus Product Git transition, Profile writer ordering, dirty Product worktree, symlink/remote identity, mapping-to-real-symbol validation, and independent Profile v2 migration. No production Profile writer or Product repository adapter exists, so a concurrent writer guarantee cannot be inferred from this sequential CLI experiment. The `versions.integrationProfile` marker is independent of the Document format marker, but current CLI requires both marker and file format to be v1; a cross-repository upgrade procedure remains to be defined.

## Conclusion

Location alone is insufficient authority. The evidence distinguishes the current three placements and exposes the minimum binding requirement; it does not select the final placement or binding encoding. The ADR remains `Spike Required` until the evidence is reviewed and a separate decision is recorded.

## Artifacts

- [Disposable repository reproduction](artifacts/reproduce.py)
- [One machine-readable run](artifacts/results.json)
