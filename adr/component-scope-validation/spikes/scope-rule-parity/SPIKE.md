# Spike: Component Scope の共通検証境界

## Related Decision

[ADR.md](../../ADR.md) の Decision to Make。[Technical Spikes](../../../../docs/spikes.md) の 05 Scope Validator に対応。

## Hypothesis

同一 evaluator と closure/index projection で Human/AI/Validator の判定を一致させられる。

## Questions

同じ component はすべての入口で同じ理由で可否判定されるか。promotion で transitive reference を検査できるか。

## Prototype Scope

App/Commerce/Product/Checkout/Account tree、nested component、deny/allowOnly、promotion の小さな fixture を実装する。最初の検証は App/Checkout の nested Definition と deny policy に限定する。

## Out of Scope

既存 product repo の module 依存解析、リアルタイム共同編集。 試作 code をそのまま production code に昇格させない。

## Measurements

許可/拒否の一致率、diagnostic、promotion の変更影響、lookup latency。 対象環境、fixture、command、実装 commit と raw data を記録する。必要な成果物のみ `artifacts/` に保存する。

## Success Criteria

Human/AI/Validator が同一 rule ID と結果を返し、sibling と transitive 違反を拒否する。

## Failure Criteria

入口ごとに結果が異なる、または promotion が transitive 違反を見落とす。

## Result

`testNestedComponentAvailabilityMatchesPickerIndexAndMutation` で、App 所有の Outer → Inner の参照を作り、Inner の Checkout deny を設定した。Checkout に対し Picker、SQLite projection、Human mutation、Agent mutation が全て Outer を拒否し、mutation diagnostic は `component.denied` となった。`bash scripts/check.sh` で 19 tests 通過。Promotion 後の影響、allowOnly と複数 Scope、lookup latency は未計測。

## Conclusion

共通 `ComponentAvailability.reason` の再帰判定で nested deny の不一致は解消できた。全ての必要 fixture と promotion 影響を調べるまで evaluator / materialized projection の最終判断は保留する。

## Artifacts

未作成。検証時に必要な成果物だけをこの Spike ディレクトリの `artifacts/` に保存する。
