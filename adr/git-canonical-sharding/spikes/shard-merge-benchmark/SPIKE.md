# Shard and merge benchmark

## Related Decision

[ADR.md](../../ADR.md) の「canonical file の shard 粒度」を判断するための Evidence。

## Hypothesis

意味単位の shard は monolithic JSON より Git conflict を減らせる。

## Questions

entity/page/subtree の diff と merge はどう違うか。50k Layer で file 数と IO は実用的か。

### Observation-shape phase (measurement plan; no result yet)

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

## Prototype Scope

1k/50k Layer fixture を各粒度で保存し、二人の branch edit/pull/merge と外部 edit を再現する。

## Out of Scope

save transaction の crash recovery、semantic merge engine。 試作 code を production code として扱わない。

## Measurements

changed file 数、diff 行数、open/save p50/p95、conflict 件数、partial load 時間。 実行環境、fixture、command、実装 commit と raw data を記録し、事前に計測 budget を固定する。

## Success Criteria

無関係 entity に diff が出ず、事前 budget の性能と conflict 水準を満たす。

## Failure Criteria

monolithic と同程度の conflict、または file 数/IO が budget を超える。

## Result

Not yet validated。実測値、観察、失敗、成果物 link を記録する。

## Conclusion

Not yet validated。結果が ADR の判断に与える影響を記録し、削除前に commit する。

## Artifacts

未作成。必要になった場合だけ、この Spike の `artifacts/` に成果物を置く。
