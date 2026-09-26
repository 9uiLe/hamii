# Spike: Component Scope の共通検証境界

## Related Decision

[ADR.md](../../ADR.md) の Decision to Make。[Technical Spikes](../../../../docs/spikes.md) の 05 Scope Validator に対応。

## Hypothesis

同一 evaluator と closure/index projection で Human/AI/Validator の判定を一致させられる。

## Questions

同じ component はすべての入口で同じ理由で可否判定されるか。promotion で transitive reference を検査できるか。

## Prototype Scope

App/Commerce/Product/Checkout/Account tree、nested component、deny/allowOnly、promotion の小さな fixture を実装する。

## Out of Scope

既存 product repo の module 依存解析、リアルタイム共同編集。 試作 code をそのまま production code に昇格させない。

## Measurements

許可/拒否の一致率、diagnostic、promotion の変更影響、lookup latency。 対象環境、fixture、command、実装 commit と raw data を記録する。必要な成果物のみ `artifacts/` に保存する。

## Success Criteria

Human/AI/Validator が同一 rule ID と結果を返し、sibling と transitive 違反を拒否する。

## Failure Criteria

入口ごとに結果が異なる、または promotion が transitive 違反を見落とす。

## Result

未実施。実測値、観察、失敗、成果物 link を記録する。

## Conclusion

未実施。ADR の判断への影響を記録し、削除前に commit する。

## Artifacts

未作成。検証時に必要な成果物だけをこの Spike ディレクトリの `artifacts/` に保存する。
