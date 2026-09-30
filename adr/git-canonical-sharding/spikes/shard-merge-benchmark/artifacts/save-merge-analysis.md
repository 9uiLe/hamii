# Canonical payload and Git merge comparison

## Conditions and scope

Precommitted plan: `045858ad4f7b88939cb5c86bc6636a6d334461f7` ([Verify](https://github.com/9uiLe/hamii/actions/runs/36658551609)). Source at execution has that SHA; production `Sources/`, `Package.swift`, and `Package.resolved` are identical to the previously verified Release build at `2d7d7815238511ba93018d0e30ebc39900b61de0`. Binary and prototype SHA-256, environment, base/source/target OIDs, every changed path and every trial are in [raw results](save-merge-matrix.json).

Environment: macOS 27 arm64, Swift 6.4 Release CLI, Git 2.52.0, 10 logical CPUs. Reused local dependency/build state and warm filesystem; no competing full gate. Three sequential fresh branch pairs per scenario/scale. All candidates use the same logical production CLI mutations, fixed Git author/date/config, no custom filters/drivers/attributes. Candidate repositories are disposable; valid input branches are retained.

The two scales contain exactly 1,000 / 10,000 Layers, two Screens, two Stack subtrees per Screen and two Component roots. The baseline has the same ArchitectureScopes, Components, Token, AppSurface and Target. Test candidates reconstruct current data for validation; Current Core does not learn their layouts.

**Measurement:** replacement Canonical serialized payload, changed paths and Git diff/conflicts. This excludes `.hamii` journal/generation writes, filesystem durability, Git metadata, Index/cache, encoding work and transaction overhead. It is not measured production save latency or physical device write traffic. CURRENT uses actual production bytes; prototype candidates use the plan’s deterministic Python encoder. Byte comparisons therefore include serialization/indentation differences as well as aggregate boundaries. They do not isolate granularity alone.

## Payload sizes

Each Text mutation assigns an equal-length eight-character value. Each writer performs one semantic mutation. Medians below pool 24 Text writes or six append writes per scale/layout; raw trial values and file sizes remain available. CURRENT/SUBTREE change two paths (manifest plus Screen/subtree); MONOLITHIC changes one aggregate path. Both branches have the same new manifest revision, so this fixture introduces no manifest counter conflict.

| Layers | Layout | Text replacement bytes median | Append replacement bytes median | Changed paths | Total baseline paths |
|---:|---|---:|---:|---:|---:|
| 1,000 | CURRENT | 201,642 | 202,044 | 2 | 13 |
| 1,000 | MONOLITHIC | 366,431 | 366,792 | 1 | 1 |
| 1,000 | SUBTREE | 66,809 | 67,074 | 2 | 17 |
| 10,000 | CURRENT | 2,015,142 | 2,015,544 | 2 | 13 |
| 10,000 | MONOLITHIC | 3,624,431 | 3,624,792 | 1 | 1 |
| 10,000 | SUBTREE | 665,309 | 665,574 | 2 | 17 |

## Merge correctness and conflicts

Per scale, each candidate has 15 merges: nine clean independent Text merges and six conflicted merges. Across both scales each candidate has 18 clean / 12 conflicted / zero command or semantic validation failures. This is 54 clean and 36 conflicted merges overall; all 90 round-trip base/A/B sets passed (270 current-format branch validations), and every clean merge passed exact intended-delta preservation and current Canonical validation.

| Scenario | CURRENT | MONOLITHIC | SUBTREE |
|---|---|---|---|
| different-screen | 6 clean / 0 conflict | 6 clean / 0 conflict | 6 clean / 0 conflict |
| different-subtree | 6 clean / 0 conflict | 6 clean / 0 conflict | 6 clean / 0 conflict |
| same-subtree-distinct-leaves | 6 clean / 0 conflict | 6 clean / 0 conflict | 6 clean / 0 conflict |
| same-property | 0 clean / 6 conflict | 0 clean / 6 conflict | 0 clean / 6 conflict |
| same-parent-append | 0 clean / 6 conflict | 0 clean / 6 conflict | 0 clean / 6 conflict |

Every conflicted trial had one unmerged path. Same-property conflicts had one marker block in every layout. Same-parent append had two marker blocks in CURRENT and one in each prototype layout; these counts repeat at both scales. Encoding/context differences are part of this comparison, so the hunk count difference does not establish fewer semantic conflicts. CURRENT conflicted on the Screen shard; MONOLITHIC on `document.json`; SUBTREE on the shared subtree shard. Base/ours/theirs bytes are recorded separately per path. These are path/hunk counts, not semantic conflict counts. The smaller conflict file limits the bytes needing inspection in this fixture, but no reduction in conflict frequency was observed.

Independent changes to distant leaves in one file merged cleanly even for MONOLITHIC. Thus this fixture does not establish that entity shards reduce conflict frequency. Same-parent appends conflicted for all layouts; no clean append ordering result exists. No format is selected and no semantic append policy is inferred.

## Git merge command duration

Wall time is `git merge` launch through process exit, excluding fixture preparation, transform, validation, save, recovery and publication. Three trials per row, median (min–max) milliseconds. No p95, throughput, Product SLA, cold-start or end-to-end claim.

| Layers | Scenario | CURRENT ms | MONOLITHIC ms | SUBTREE ms |
|---:|---|---|---|---|
| 1000 | different-screen | 32.841 (32.794–34.027) | 36.394 (35.405–38.518) | 31.732 (31.094–32.306) |
| 1000 | different-subtree | 40.974 (37.863–41.734) | 36.364 (36.133–37.473) | 34.050 (33.269–35.361) |
| 1000 | same-subtree-distinct-leaves | 35.415 (34.984–35.858) | 37.053 (36.619–37.346) | 33.065 (32.664–34.433) |
| 1000 | same-property | 25.001 (24.699–25.414) | 25.317 (24.825–25.348) | 24.140 (23.584–24.889) |
| 1000 | same-parent-append | 25.131 (23.989–27.963) | 25.468 (25.385–29.048) | 23.174 (21.012–24.091) |
| 10000 | different-screen | 58.409 (57.238–58.731) | 95.658 (94.731–100.060) | 47.370 (47.029–48.807) |
| 10000 | different-subtree | 70.383 (69.953–73.481) | 98.217 (97.329–98.962) | 46.786 (46.732–47.506) |
| 10000 | same-subtree-distinct-leaves | 71.158 (69.856–71.738) | 96.488 (95.257–97.204) | 55.484 (55.234–56.687) |
| 10000 | same-property | 54.690 (53.494–55.052) | 77.261 (75.531–78.232) | 42.657 (42.419–44.414) |
| 10000 | same-parent-append | 65.167 (64.605–65.540) | 79.153 (79.148–82.850) | 42.561 (41.967–43.147) |

## Failed preparation and validation limits

The initial preparation attempt failed before any candidate measurement: Python-generated fixture bytes differed from the production encoder, and expected-bytes save validation rejected them as an external edit. [Failure record](save-merge-initial-failure.json) preserves the attempt, source/binary/prototype fingerprints and error. The corrected fixture uses [Foundation normalization](normalize-fixture.swift) before a real CLI save. The production expected-bytes check remains enabled and all measured mutations succeeded. This correction changes fixture preparation only; layouts/scenarios/criteria remain the precommitted ones. The failed attempt is not included in successful medians.

At each scale, negative reconstruction probes reject dangling, duplicate, unreachable, unknown-path and identity-mismatched subtree references. Exact round trips and complete decoded-inventory comparisons catch unrelated fields/IDs/references changing. Schema/reference/Scope/Component/Authoring validity is enforced by the existing current-format CLI validator. Real production mutation preconditions are acquired independently in each writer worktree. Conflict markers are never passed to validation or reported as a usable project.

Only these simple Stack/Text edits and tested sizes are covered. Component implementation edits, complex reference changes, large shard counts, different encoder choices, append ordering and 50k/partial-load behavior remain unmeasured. AI total tokens, costs, memory/physical IO and full development-cycle performance are unmeasured. No new indexing/freshness behavior is introduced.

## Conclusion and reproduction

Confirmed for tested cases: all layout transforms round-trip, independent clean merges preserve both edits, intentional conflicting values are detected, and valid input branches remain unchanged. Measured: SUBTREE has a smaller replacement payload/conflict file under these encoders; all candidates have the same conflict counts. Unknown: best production shard granularity, production write cost and large/partial-load scaling. `git-canonical-sharding` remains **Spike Required**.

Build the matching Release CLI, then run (output retains incomplete/failed attempts and exits nonzero on correctness failure):

```sh
swift build -c release --product hamii
python3 adr/git-canonical-sharding/spikes/shard-merge-benchmark/artifacts/measure-save-merge.py --output /tmp/hamii-save-merge.json
```

Require a clean production source/Package/lock state. Run sequentially without competing verification workloads. This prototype is development evidence; it is neither part of production nor a format migration. After the Evidence commit’s full gate and exact-SHA Verify, consult the designated design session before selecting the next phase.
