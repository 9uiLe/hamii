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

## Prototype Scope

Observation-shape phase と、上記の固定した 1k/10k save/diff/merge phase。50k、partial load は未検証の後続範囲として残す。

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

## Conclusion

Observation-shape phase は、今回の同数 Layer fixture に限り、shape 間の一回観測差より、四回応答 workflow と一回観測候補の差が大きい Evidence を得た。candidate は production batch の実装・安全性・性能保証ではない。shard 粒度の Decision は未完了であり、この Spike 自体も save/diff/merge/50k/partial-load Evidence を待つ。ADR は `Spike Required` のまま維持する。

## Artifacts

- [Observation-shape analysis](artifacts/observation-shape-analysis.md)
- [Observation-shape raw matrix](artifacts/observation-shape-matrix.json)
