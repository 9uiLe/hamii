# Large Canvas benchmark

## Related Decision

[ADR.md](../../ADR.md) の Decision to Make。

## Hypothesis

viewport culling と LOD で大規模 Canvas の操作 budget を満たせる。

## Questions

可視 node 数と総 node 数で費用はどう変わるか。Metal は必要か。

## Prototype Scope

1k/10k/50k Layer、text/image、複数 Zoom で pan/selection/hit test を測る。

## Out of Scope

Native Host の描画、production UI parity。 試作 code を production code とみなさない。

## Measurements

frame p95、hit-test p95、memory、cache hit、cold/warm load。 対象環境、fixture、command、実装 commit、raw data を記録する。定量 budget は実験前に決める。

## Success Criteria

事前 budget を満たし、不可視 node が描画費用を支配しない。

## Failure Criteria

操作 budget を超え、CG/CA 最適化でも改善しない。

## Result

Not yet validated。実測値・失敗・成果物 link を記録する。

## Conclusion

Not yet validated。ADR への影響を記録し、削除前に commit する。

## Artifacts

未作成。必要になった場合だけこの Spike の `artifacts/` を作る。
