# Migration worktree safety

## Related Decision

[ADR.md](../../ADR.md) の「migration の repository isolation と review」を判断するための Evidence。

## Hypothesis

temporary worktree/branch は元 tree を守りながら migration diff を review できる。

## Questions

dirty tree をどう扱うか。途中失敗後に元 tree は不変か。edge は再実行可能か。

## Prototype Scope

v1→v2→v3、dirty tree、missing LFS、途中 kill、review commit の fixture を試す。

## Out of Scope

ambiguous token mapping の解決 UI、全 historical migrator の配布。 試作 code を production code として扱わない。

## Measurements

元 tree hash、edge repeatability、migration report、validation、fresh index rebuild、review diff。 実行環境、fixture、command、実装 commit と raw data を記録し、事前に計測 budget を固定する。

## Success Criteria

元 tree が不変で、失敗 rollback と再実行が成立する。

## Failure Criteria

元 tree が無断変更される、rebuild/validation に失敗、または再実行結果が変わる。

## Result

Not yet validated。実測値、観察、失敗、成果物 link を記録する。

## Conclusion

Not yet validated。結果が ADR の判断に与える影響を記録し、削除前に commit する。

## Artifacts

未作成。必要になった場合だけ、この Spike の `artifacts/` に成果物を置く。
