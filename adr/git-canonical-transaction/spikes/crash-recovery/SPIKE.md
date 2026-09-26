# Crash recovery transaction

## Related Decision

[ADR.md](../../ADR.md) の「multi-file save の commit/recover protocol」を判断するための Evidence。

## Hypothesis

staging + manifest/journal で torn canonical graph を防げる。

## Questions

各保存段階で kill しても complete revision に戻るか。外部 edit と競合時に誤上書きしないか。

## Prototype Scope

複数 entity/asset 参照を持つ save を各 stage で kill し、reopen/recovery を試す。

## Out of Scope

shard 粒度の最適化、semantic merge engine、SQLite 正本化。 試作 code を production code として扱わない。

## Measurements

recovered revision、欠落参照、fsync/write count、save/reopen p95。 実行環境、fixture、command、実装 commit と raw data を記録し、事前に計測 budget を固定する。

## Success Criteria

complete old/new revision に復旧し、reference validation が通る。

## Failure Criteria

torn graph が正本として開かれる、または再実行で異なる結果になる。

## Result

Not yet validated。実測値、観察、失敗、成果物 link を記録する。

## Conclusion

Not yet validated。結果が ADR の判断に与える影響を記録し、削除前に commit する。

## Artifacts

未作成。必要になった場合だけ、この Spike の `artifacts/` に成果物を置く。
