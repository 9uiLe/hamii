# Isolated format upgrade

## Related Decision

[ADR.md](../../ADR.md) の historical parser と Current Core の依存境界。

## Hypothesis

旧 schema と edge migrator を別 target に置けば、Core に legacy type を import せず Current Format を生成できる。

## Questions

v1→v2→v3 の path 解決と検証は独立 target で成立するか。旧 type が Core/通常開発 target の依存 graph に漏れないか。

## Prototype Scope

小さな v1/v2/v3 fixture、edge migrator、registry、Current Format parser、fresh index rebuild を試作し、dependency graph を検査する。

## Out of Scope

全 historical version の配布、曖昧値の Human 解決 UI、worktree isolation。試作 code を production code とみなさない。

## Measurements

変換 entity/reference 数、edge repeatability、validation error、Core dependency graph、fresh index rebuild の成否を記録する。

## Success Criteria

同じ入力が同じ Current Format になり、各 edge 後の validation が通り、Core が historical type に依存しない。

## Failure Criteria

Core に legacy import/version branch が必要、結果が非決定的、または fresh index rebuild に失敗する。

## Result

Not yet validated。実測値と成果物 link を記録する。

## Conclusion

Not yet validated。ADR の判断への影響を記録し、削除前に commit する。

## Artifacts

未作成。必要になった場合だけこの Spike の `artifacts/` を作る。
