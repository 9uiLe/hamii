# Shard and merge benchmark

## Related Decision

[ADR.md](../../ADR.md) の「canonical file の shard 粒度」を判断するための Evidence。

## Hypothesis

意味単位の shard は monolithic JSON より Git conflict を減らせる。

## Questions

entity/page/subtree の diff と merge はどう違うか。50k Layer で file 数と IO は実用的か。

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
