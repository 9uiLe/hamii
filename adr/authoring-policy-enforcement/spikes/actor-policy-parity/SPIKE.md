# Spike: Authoring Harness の共通 policy 実行

## Related Decision

[ADR.md](../../ADR.md) の Decision to Make。[Technical Spikes](../../../../docs/spikes.md) の 07 Authoring Harness に対応。

## Hypothesis

typed rule ID/severity と共通 validator を Mutation Engine に置けば actor に依らず同じ拒否を返せる。

## Questions

Human/AI が同じ rule ID で拒否されるか。policy 自体の変更は監査できるか。waiver は範囲外で効かないか。

## Prototype Scope

tokenOnly、absolutePositioning forbidden、component availability、a11y rule の小さな policy engine を作る。

## Out of Scope

AI prompt の最適化、全 design system policy、production repository の統合規則。 試作 code をそのまま production code に昇格させない。

## Measurements

actor 間の判定一致、rule ID、waiver audit、mutation latency。 対象環境、fixture、command、実装 commit と raw data を記録する。必要な成果物のみ `artifacts/` に保存する。

## Success Criteria

Human/AI command が同じ違反で拒否され、許可済み waiver のみ効く。

## Failure Criteria

prompt 依存の抜け道が残る、または actor ごとに異なる判定が出る。

## Result

未実施。実測値、観察、失敗、成果物 link を記録する。

## Conclusion

未実施。ADR の判断への影響を記録し、削除前に commit する。

## Artifacts

未作成。検証時に必要な成果物だけをこの Spike ディレクトリの `artifacts/` に保存する。
