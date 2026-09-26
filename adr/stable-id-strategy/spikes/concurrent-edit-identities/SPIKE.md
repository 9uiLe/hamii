# Concurrent edit identities

## Related Decision

[Stable ID strategy](../../ADR.md)

## Hypothesis

Random ID と stable property path は二 branch の独立編集を曖昧さなく識別できる。

## Questions

Copy、rename、move、simultaneous insertion で semantic diff と merge がどう見えるか。

## Prototype Scope

同じ Screen の二 branch 編集 fixture と ID/path generator の比較。

## Out of Scope

Production semantic merge engine。

## Measurements

ID collision、conflict 数、rename/move の不要 diff、index lookup cost。

## Success Criteria

異なる entity を取り違えず、rename/move が同じ identity を維持する。

## Failure Criteria

同時編集の entity が誤って同一視されるか、大量の不要 diff が出る。

## Result

未実施。

## Conclusion

未判定。

## Artifacts

fixture と測定結果だけこの Spike の `artifacts/` に置く。
