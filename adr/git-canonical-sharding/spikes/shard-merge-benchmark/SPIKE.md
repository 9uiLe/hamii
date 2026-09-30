# Shard and merge benchmark

## Related Decision

[ADR.md](../../ADR.md) の「canonical file の shard 粒度」を判断するための Evidence。

## Hypothesis

意味単位の shard は monolithic JSON より Git conflict を減らせる。

## Questions

entity/page/subtree の diff と merge はどう違うか。50k Layer で file 数と IO は実用的か。

### Observation-shape phase (precommitted plan; results below)

同じ約10k Layer で、一回の Canonical observation が shard shape にどれだけ依存するか、また T2/T3 の四回の observation が shape の差より大きいかを測る。この phase だけでは shard 粒度を決定しない。

- L: 1 selected Screen に 10,000 Layers。baseline の Component root を加え、Document 合計 10,002 Layers。
- S: 100 Screens × 100 Layers。selected Screen はそのうち一つ。Component root を加え、Document 合計 10,002 Layers。
- C: selected Screen に 2 Layers、baseline Component root が 2 Layers、100 additional ComponentDefinitions に 9,998 Layers を分配（98 definitions × 100、2 definitions × 99）。Document 合計 10,002 Layers。

共通 base は同じ Scope hierarchy、selected Screen/Layer、利用可能な Component、Sibling Scope の利用不可 Component、spacing Token、AppSurface/Target、capability declarations を持つ。追加 Layer は単純な Text を主とする。Current Canonical Format の Screen/Component file 規則を維持し、file format や production sharding は変更しない。各 fixture を Canonical validation で確認してから測る。1k control と 50k は今回の必須範囲外。

通常の `CanonicalRepository.observe()` と同じ経路を各 shape 20 回以上測る。DEBUG measurement seam で entity decode を folder ごと、Document/asset validation、ClientPrecondition path discovery・再読込・hash に分ける。path 数、Canonical JSON bytes、最大/中央値 shard bytes、directory enumeration と entity read bytes も記録する。stage が入れ子の場合は合算を total と呼ばない。

現行 CLI の T1/T2/T3 staged workflow を各 shape 5 回測り、response 数と payload bytes を記録する。同時に test-only candidate として、実 `CanonicalRepository.observe()` を一回行い、その `ProjectObservation` を in-memory `ProjectRepository` から同じ production `ProjectContextService` の T1/T2/T3 projection に渡す。candidate は各 response の `ContextObservation` 一致を検査する。これは production batch/session、長寿命 lock、snapshot lease の実装・正しさの証明ではない。AI thinking 中に lock を保持しない。

事前に固定する次作業の routing rule（Product SLA ではない）：

1. **BATCH-FIRST:** 全 shape で T2/T3 の single-observation candidate 中央値が、それぞれ現行 workflow 中央値の 50% 以下で、projection correctness と payload が一致する場合、独立した batch/read-session Decision Boundary の検討を先に行う。
2. **SHARD-FIRST:** 10k equal-layer shapes の通常 `observe()` 中央値の `max/min` が 1.5 以上なら、この既存 sharding Spike の save/diff/merge/50k Evidence を先に進める。
3. 両条件を満たす場合、`batchSaving = current T2 median - candidate T2 median`、`shapeSaving = slowest observe median - fastest observe median` を比較する。`batchSaving >= 2 × shapeSaving` なら batch/read-session investigation を先、それ以外は sharding Spike を先にする。
4. どちらも満たさなければ stage profile を再評価し、新 architecture は選ばない。

T2 10k を主指標、T3 を確認、T1 を二 response control とする。結果を見た後で閾値を変更しない。今回の比較はこの fixture に限定し、cold cache、release build、real project の性能や AI total tokens、LLM task success、model cost を推定しない。full gate scripts/CI workflow は変更しない。

### Save / diff / merge phase (precommitted plan)

This focused phase measures 1k and 10k Layers only. It follows the completed observation-reuse routing work; the current production context session is described in [the CLI contract](../../../../docs/context-session.md). This phase does not decide the production file format.

#### Fixtures and fixed candidate layouts

Use the existing common Scope / Component / Token / AppSurface fixture builder. Each scale contains exactly 1,000 or 10,000 Layers across two Screens and the two existing Component roots. Each Screen has one root Stack, two child Stack subtrees X/Y and 248 or 2,498 Text leaves per subtree respectively (499/4,999 Layers per Screen). Stable IDs, child order, properties, ownership and references are identical across candidates. Validate the current-format fixture before any comparison.

- **CURRENT:** unchanged production Screen/Component entity-per-file layout. Use the actual Canonical JSON bytes from the validated current-format fixture and after production CLI mutations. No file split is introduced.
- **MONOLITHIC:** test-only `document.json`, a sorted mapping from the complete Canonical JSON inventory's relative path to its JSON value (manifest, Agent profiles and entity shards). It preserves values and stable IDs; it does not give Page architectural ownership. This is the larger aggregate option.
- **SUBTREE:** test-only layout retaining the current inventory except each Screen root's two children become `prototypeChildrenRefs` in stable child order. The four referenced Stack trees are stored in `subtrees/<stable-layer-id>.json`. Components and other entities retain their current shards. This is the smaller subtree option, not a node-per-file or production schema implementation.

Prototype transforms must losslessly round-trip to the same current-format Canonical inventory. Unknown, dangling, duplicate or unreachable subtree references are errors. Validate every reconstructed result with current hamii parse/schema/semantic validation; Current Core never parses the prototype layouts directly. Use UTF-8, deterministic key order and indentation; stable IDs determine paths. Preserve CURRENT bytes, and use one fixed encoder for both prototype candidates.

#### Edits and independent writers

For each scale, use three fresh repetitions of these fixed A/B scenarios:

1. **different-screen:** A changes the first Text in Screen A/X; B changes the first Text in Screen B/Y.
2. **different-subtree:** A changes the first Text in Screen A/X; B changes the first Text in Screen A/Y.
3. **same-subtree-distinct-leaves:** A changes the first Text in Screen A/X; B changes its last Text.
4. **same-property:** A/B assign different values to the same first Text in Screen A/X. A clean merge silently selecting one value is a correctness failure.
5. **same-parent-append:** A/B each append a distinct Text to Screen A/X. If Git merges cleanly, require both unique IDs/content under the correct parent exactly once and record the resulting child order. Do not decide semantic append ordering or implement semantic merge.

Use equal-length ASCII Text values for A/B, distinct appended names and IDs, and identical logical deltas for all layouts. Obtain each writer's before/after inventory through production CLI mutations in separate current-format branch/worktrees. Each writer observes its own `ClientPrecondition`; no session/cache/Index proof substitutes for mutation validation. Translate the same inventories to prototype layouts afterward. Test Git merge only in disposable candidate repositories; neither valid input branch/worktree is overwritten. No source worktree publication occurs.

Git configuration is isolated for disposable repositories, with fixed author identity and conflict style, no custom attributes/drivers/filters, and recorded Git version. Record base/source/target OIDs. Use the same base and A/B order for all candidates. Sequentially process scenarios to bound resources; no competing full gate during measurements.

#### Measurements and correctness gates

For each writer/candidate record: total JSON paths/bytes, changed paths/count, before/after sizes, sum of serialized bytes that must be replaced, Git numstat added/deleted lines, and intended semantic property/structural changes. CURRENT replacement bytes come from production save output; prototype replacement bytes come from their changed serialized payloads. Exclude `.git`, `.hamii`, repository-external Index/cache and durability/journal IO. Report these as Canonical payload amplification, not full transaction IO or production save latency.

For each candidate merge record: exit status, clean/conflicted/failed, unmerged paths/count, conflict marker blocks, per-conflict-path base/ours/theirs blob bytes, and any clean merged semantic validation. Do not equate Git path/hunk counts with semantic conflict counts. Every clean independent-edit merge must retain both intended edits and all unrelated IDs/properties/references; every clean append must preserve both nodes and record order. Every candidate branch and clean merge must reconstruct valid current-format data. Report validation failures, command failures and interrupted/incomplete attempts; never treat them as clean merges.

Three repetitions are descriptive median/min/max only; no p95, measured throughput, SLA or universal merge guarantee. No performance ratio threshold or winning format is selected here. Success means a complete comparable matrix plus passing round-trip/semantic preservation checks. A conflict in an independent-edit scenario is candidate evidence, not grounds to discard the trial. Loss of either edit, unintended semantic changes, malformed reconstruction, stable-ID/reference violations or a same-property clean merge selecting one value disqualifies the prototype evidence. Never tune layout or scenarios after results; record problems before revising a separate plan.

#### Boundaries and delivery

Out of scope: 50k/open-save scaling, partial reader, production Format migration/v3, production serializer changes, save crash/power-loss recovery, managed merge publisher changes, semantic merge engine, AI token/cost estimates and Native Preview. Existing production stale-index rejection is unchanged.

Commit this plan before prototype execution and verify its exact SHA. Then commit test-only prototype, raw matrix and focused Result/Conclusion under this Spike's `artifacts/`; full gate and exact-SHA CI are required. Keep the ADR `Spike Required`. After Evidence delivery, report and await the next routing decision; do not infer a final shard layout from this phase alone.

### Serializer control and open/save scaling phase (precommitted plan)

This phase keeps the ADR `Spike Required`. It uses the same aggregate boundaries, stable path rules and simple Stack/Text fixture as the save/diff/merge phase; no production Format, serializer, Migration, Index or Preview changes. Existing results remain intact.

#### Serializer control before scaling

Use a test-only Swift/Foundation JSON value serializer (sorted keys, pretty printed, unescaped slashes, UTF-8 and trailing newline) for all normalized layouts. **CURRENT-P** retains actual production bytes; **CURRENT-N** reserializes the current inventory through the common encoder; **MONOLITHIC-N** and **SUBTREE-N** use the same common encoder with the previously fixed layouts. Python may orchestrate but must not serialize the measured candidates.

At 1k and 10k, record CURRENT-P/N inventory and replacement bytes for the same equal-length Text mutation. Check normalized round trips with the actual Current parser and DocumentValidator, preserving complete values, IDs, references and child order. Byte equality is recorded, not required.

Before 50k, repeat the five existing 10k merge scenarios once each for P and all three N layouts (20 trials). Require all three independent Text scenarios to merge cleanly with both deltas and unrelated fields preserved, and same-property to conflict. Record same-parent append classification/order and any difference from the existing Evidence. **Hard stop:** a CURRENT-P/N major clean/conflict classification change, lost edit, invalid reconstruction or validation failure stops scaling; retain failure and consult the design session. Do not rerun 90 trials or change layout/criteria after observing results.

#### Scaling fixture and correctness

Exactly 1k, 10k and 50k Layers: two Screens, two child Stack subtrees per Screen, and two Component roots. Extend the same Text pattern (248/2,498/12,498 leaves per subtree), Scope hierarchy, Components, Token, AppSurface and Target. Same inventory and selected stable Text ID/value across candidates. Fixed four subtree files; no adaptive split threshold.

At each scale/N layout, perform at least three encode/decode/reconstruct/current-parser/semantic-validation round trips. Require repeated encodes of identical input to yield identical bytes. Retain rejection of dangling/duplicate/unreachable/unknown/identity-mismatched subtree references at 50k too. Report all failures, OOM, timeout and interrupted/incomplete trials; do not remove them from the matrix.

#### Open boundaries

- **Production CURRENT:** Release `CanonicalRepository.load()` and `observe()` separately, ten warm-local runs each per scale, after fixture preparation. `observe()` includes ClientPrecondition work. This is actual production API cost, excluding OS process launch, preparation and Git commit.
- **Normalized prototype:** ten warm-local runs per scale/layout using one test-only Swift pipeline: candidate file read → JSON decode → layout reconstruction → same typed current entity decode / Document construction → DocumentValidator. CURRENT-N uses the same pipeline as MONOLITHIC-N/SUBTREE-N. Prototype timing is not production open latency. Record stage times separately; do not sum overlapping timings.

Record canonical/candidate paths, JSON bytes, largest/median shard bytes and exact prototype files/bytes read. Production inventory sizes are metadata, not measured syscall counts; actual production read counts are unmeasured if the public Release API cannot expose them without production changes. Do not infer read counts from file sizes or DEBUG timings. Reconstructed outputs must independently pass actual Current parser validation outside timed prototype measurements.

#### Save boundaries

- **Production CURRENT:** five fresh disposable copies per scale. Observe each copy outside timing, then time `ProjectService.mutate(.setText, expectedState: …)` entry through returned new precondition. This includes its internal validation, observation, journal/transaction, generation coordination and serialization/write. Post-save observation and exact intended-delta checks are outside timing; Git commit is excluded. Use the same selected ID and eight-character Text delta. No repeated mutations of one copy.
- **Normalized prototype:** five fresh copies per scale/layout. Time the same in-memory semantic Text delta → common Swift candidate encode → changed files write. Record encode/write/total separately, changed paths, replacement payload bytes and total candidate bytes. Validate exact intended delta and reconstructed Current result after timing. Do not add fsync or call this production durable save latency/physical write bytes.

Use Release modules and a test-only Swift executable linked outside Package targets; production does not import ADR artifacts. Record source/dependency/toolchain/prototype/binary fingerprints, commands, sample counts, warm-up, layout order, environment/load and measurement boundaries. Run sequentially without competing full gate. If available, record peak RSS with a fixed macOS process measurement method; otherwise explicitly unmeasured. Report median/min/max and raw samples only; no p95, SLA, throughput or AI token/cost inference.

#### Success, routing and delivery

Correctness/completeness are hard gates; no arbitrary speed threshold or winning format. Success requires serializer gate, all scale/layout deterministic round trips/current validation, all open/save series, metadata, retained failed attempts, full gate and exact-SHA Verify. Production syscall counts or RSS that cannot be acquired remain marked unmeasured.

Routing: serializer-sensitive major classification → stop and normalized merge re-evidence; candidate correctness/nondeterminism/OOM/execution failure → retain failure, consult about partial-load on surviving layouts; all candidates viable → partial-load phase next. Production scale problems are Evidence for partial-load planning, not permission to implement a partial reader. No `Ready for Decision` until partial-load Evidence is complete.

First commit only this plan, Markdown gate, push and exact-SHA Verify. Then test-only common serializer/harness, `artifacts/open-save-scaling-matrix.json`, `artifacts/open-save-scaling-analysis.md` (and separate serializer-control results if needed), plus Result/Conclusion; full gate, push and exact-SHA Verify. Report to the designated design session and stop for routing after that Evidence. No new ADR or production architecture decision in this phase.

### Read-only partial-load phase (precommitted plan)

Keep `Spike Required`; compare CURRENT-N / MONOLITHIC-N / SUBTREE-N with the existing common Swift/Foundation encoder and fixed boundaries at exactly 1k/10k/50k Layers. All code stays in this Spike’s artifacts; no Sources, Package target, Format, migration, Index or Preview changes.

#### Fixture and tasks

Maintain two Screens, two direct child Stack subtrees per Screen, two Component roots, Scope hierarchy and AppSurface/Target. Replace the first three leaves of Screen A/X with one ComponentInstance, a system Asset Image and an accessible Button with Interaction → Motion; use the existing Stack’s spacing Token and a padding effect. Add a spacing alias → existing primitive Token, both owned by Checkout. Make the Commerce-owned primary Component root an instance of the existing secondary Component, now App-owned; the secondary root references the App-owned system Asset, and primary availability denies Account. The alias remains on the Checkout-owned selected Stack; an App-owned Component cannot consume a Checkout-owned Token. Both roots remain single Layers. This fixes nested/transitive closure without changing Layer count. Add an unreferenced system Asset for hidden-read controls. Declare fixture capabilities required by actual current validation. These fixture changes are test-only.

- **A:** request Screen A ID and known X root ID; return document identity/revision context, AuthoringHarness, Screen identity/scope, selected subtree and transitive dependencies.
- **B:** request Screen A ID; return complete Screen including navigation and reachable dependencies. Custom navigation IDs must exist in the loaded Screen tree; Page/Surface/Target/Fixture validity is excluded.
- **C:** request Screen A ID and last Text leaf in its second subtree; no cached locator, fixture path table, Layer-ID map or Index. Search in explicit child order and record all required subtree reads.

Only request IDs, stable entity paths and references from loaded files locate data. No full directory scan, full Document decode or oracle access inside the partial reader. CURRENT reads its Screen shard; MONOLITHIC reads its aggregate; SUBTREE A reads shell + selected subtree, B both, C scans as necessary. A must not read sibling subtree, Screen B or unreferenced resources.

#### Closure and validity boundary

Traverse Layer children and Component slot content, layout spacing and effect Token IDs, Asset IDs, Component definition IDs, Interaction IDs. Tokens follow transitive references and owner Scope ancestors. Components retain API/variants/slots, follow nested definition trees and their references, owner Scope ancestors and availability allow/deny Scope IDs. Interactions follow transition Motion IDs. Start Scope closure at Screen scope; missing/cyclic required ancestors/dependencies and malformed required JSON fail without a semantic payload or fallback.

Use a test-only `PartialSemanticSlice` with `globalValidityProven = false`, `authoringReady = false`. It is never a CanonicalSnapshot, ProjectObservation, ClientPrecondition, validated Document or mutation base. Full-current parse and DocumentValidator establish an independent oracle before measurement. Deterministic semantic projection (task/context/payload and ID-sorted dependency values) encoded by the common Swift encoder must byte-match that oracle; IDs, values and child order must match. Partial code never calls global validation or mutation APIs.

Immutable disposable fixture only. Sorted exact candidate paths/bytes SHA-256 is `measurementSourceFingerprint`, not Snapshot identity. Check before and after each timing series; mismatch invalidates the series and remains recorded. No concurrent-writer/currentness proof.

#### Measurements and controls

Release test-only Swift process, sequential, no competing full gate. For each scale/layout measure ten full opens on the same dependency-rich fixture and ten runs each for A/B/C, with one recorded excluded warm-up before every series (90 full + 270 partial measured). Record actual read paths/bytes/count, largest read, fraction of candidate paths/bytes, semantic/oracle hashes, dependency IDs, source fingerprint, total time, read/decode/traversal/projection-encode stages and median/min/max. Nested stages are labeled and never summed as independent totals. Preserve raw attempts including timeout/OOM/incomplete/failed runs; never replace failed samples silently. AI tokens/cost/RSS remain unmeasured unless actual usage is available. No p95, SLA, speed gate or production partial latency claim.

At 10k, each layout must reject missing selected payload/path mismatch, missing required Token/Component/Scope ancestor/Interaction/Motion and malformed required JSON. SUBTREE selected-path dangling/duplicate/unknown/identity-mismatched refs must reject; full reconstruction retains unreachable-ref rejection. Inject unrelated invalid reference in Screen B: A may remain byte-identical while actual full-current validation must reject. This explicitly demonstrates slice correctness does not imply project validity. Repeat deterministic partial bytes/IDs/read paths across all measured runs.

#### Routing and delivery

Hard gates are closure correctness, exact oracle agreement, source integrity, no hidden reads and complete matrix. Locator-required in C is tradeoff evidence; do not implement a locator. All gates complete → report for ADR Decision Review / possible Ready for Decision; do not automatically add performance Spikes or write a Decision. Missing closure/oracle mismatch/fallback → retain and report failure. Any need to infer Snapshot/currentness/mutation authority from a slice → stop for separate validity decision.

Commit this plan first, Markdown gate, push and exact-SHA Verify. Then artifacts `measure-partial-load.swift`, `measure-partial-load.py`, `partial-load-matrix.json`, `partial-load-analysis.md` and failure data if any; update Result/Conclusion, full gate, push and exact-SHA Verify. Report to the designated design session and await routing.

## Prototype Scope

Observation-shape phase と、上記の固定した 1k/10k save/diff/merge phase と serializer control / 1k/10k/50k open-save phase。上記 read-only partial-load phase。

## Out of Scope

save transaction の crash recovery、semantic merge engine。 試作 code を production code として扱わない。

## Measurements

各 phase の事前計画に従い、実行環境、fixture、command、source commit と raw data を記録する。save/diff/merge は payload bytes / paths / Git conflicts と descriptive median/min/max を扱い、3 回から p95 を算出しない。open/save latency、50k、partial load はこの phase の測定値に含めない。

## Success Criteria

Observation-shape は上記 routing rule を適用する。save/diff/merge は全比較行の round-trip / semantic preservation と試行の完全性を検証する。独立編集の Git conflict は比較結果であり、試行を除外しない。

## Failure Criteria

save/diff/merge で edit loss、意図しない semantic change、不正な参照 / stable ID、malformed reconstruction、または同一 property の競合値を clean merge で片方だけ選択した場合は correctness failure とする。未完了 / 失敗試行を成功扱いしない。

## Result

Observation-shape phase: [analysis and conditions](artifacts/observation-shape-analysis.md)、[raw matrix](artifacts/observation-shape-matrix.json)。L/S/C 各10,002 Layers、12/111/112 Canonical JSON paths。通常 observe 中央値は 109.364/120.840/122.001 ms (`max/min = 1.116`)。T2 current CLI 中央値は 490.257/534.794/551.290 ms、test-only single-observation candidate は 108.783/120.423/134.195 ms。全 shape の T2/T3 candidate は current の50%以下で、production ContextService の response payload と一致した。事前 routing rule により **batch investigation first**。この phase は save、diff、merge、50k、partial load を測っていない。

Save/diff/merge phase: [analysis and conditions](artifacts/save-merge-analysis.md)、[raw matrix](artifacts/save-merge-matrix.json)。1k/10k 各3 repetitions × 5 scenarios × 3 layouts、90 merges。独立 Text edits は全候補で各18 clean、同一 property / same-parent append は各12 conflicts。54 clean merges は双方の変更と無関係な Canonical fields を保持し、current validation が成功した。270 base/A/B round-trip validations が成功。1k の Text replacement payload median は CURRENT 201,642 / MONOLITHIC 366,431 / SUBTREE 66,809 bytes、10k は 2,015,142 / 3,624,431 / 665,309 bytes。production save latency / durable IO ではなく、encoder/indentation を含む payload 比較である。初回 fixture preparation の expected-bytes 拒否も Failure Evidence として保存した。

Serializer control / open-save scaling phase: [analysis and conditions](artifacts/open-save-scaling-analysis.md)、[raw matrix](artifacts/open-save-scaling-matrix.json)。10k の5 scenarios × 4 layouts × 1 repetition (20 merges) は CURRENT-P/N の分類が一致し、共通 Foundation serializer gate が成功。1k/10k の CURRENT-P/N bytes は今回の fixture で一致。1k/10k/50k 各 layout の3 deterministic actual-current-parser round trips と negative ref rejection が成功。Release warm-local production 50k load/observe/mutation save の median は 381.717/394.700/2,134.925 ms (n=10/10/5)。normalized prototype 50k open median は 678–684 ms、encode/write は516–526 msだが、追加 JSON-value pipeline と durability 差があるため production latency と直接比較しない。prototypeの全 inventory encode と changed-file write を分離した。production syscall counts / peak RSS / AI tokens / cost は未計測。事前 routing は **50k viable → partial-load phase**。

Read-only partial-load phase: [analysis and conditions](artifacts/partial-load-analysis.md)、[raw matrix](artifacts/partial-load-matrix.json)。1k/10k/50k × 3 layouts × A/B/C × n=10 (270 partial runs)、90 paired full-open controls、36 recorded warm-ups。全 output / dependency closure / path-order は full validated oracle と一致し、全36 series の source fingerprint が安定。10k の38 corruption/control results は required missing/cyclic/malformed inputs の拒否、未参照不正 shard が partial output に現れず全体 validation では拒否される境界を確認。50k SUBTREE A は candidate bytes の約25%を読むが median 535.184 ms、CURRENT A は460.099 ms。SUBTREE B/C の再構成コストも記録し、bytes から速度改善を推定しない。C は locator なしで両 subtree を読む。2回の orchestration failure と完成済み sample を保持した。事前 route は **Decision Review**、ADR は判断まで `Spike Required`。

## Conclusion

Observation-shape phase は、今回の同数 Layer fixture に限り、shape 間の一回観測差より、四回応答 workflow と一回観測候補の差が大きい Evidence を得た。candidate は production batch の実装・安全性・性能保証ではない。shard 粒度の Decision は未完了であり、save/diff/merge phase は、今回の fixture で全候補の conflict count が同一である Evidence を得た。SUBTREE の replacement payload / conflict file は小さいが、これだけで production granularity を採用しない。共通 serializer control と50k/open-save scaling は今回の fixture で完了した。read-only partial-load は上記範囲で検証した。many-shard scaling、複雑な reference edits、partial authoring validity は未検証。common full-inventory prototype encode と production durability の境界を維持し、payload差だけで速度改善を主張しない。ADR は `Spike Required` のまま維持する。

## Artifacts

- [Observation-shape analysis](artifacts/observation-shape-analysis.md)
- [Observation-shape raw matrix](artifacts/observation-shape-matrix.json)

- [Save/diff/merge analysis](artifacts/save-merge-analysis.md)
- [Save/diff/merge raw matrix](artifacts/save-merge-matrix.json)
- [Initial preparation failure](artifacts/save-merge-initial-failure.json)
- [Test-only measurement prototype](artifacts/measure-save-merge.py)
- [Fixture normalization](artifacts/normalize-fixture.swift)

- [Open/save scaling analysis](artifacts/open-save-scaling-analysis.md)
- [Open/save scaling raw matrix](artifacts/open-save-scaling-matrix.json)
- [Common Swift serializer / measurement harness](artifacts/measure-open-save-scaling.swift)
- [Scaling orchestration](artifacts/measure-open-save-scaling.py)
- [Compile preparation failure](artifacts/open-save-preparation-failures.json)

- [Partial-load analysis](artifacts/partial-load-analysis.md)
- [Partial-load raw matrix](artifacts/partial-load-matrix.json)
- [Retained incomplete attempts](artifacts/partial-load-failures.json)
- [Read-only partial Swift prototype](artifacts/measure-partial-load.swift)
- [Partial-load orchestration](artifacts/measure-partial-load.py)
