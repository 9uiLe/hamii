# Spike: Capability の契約粒度

## Related Decision

[ADR.md](../../ADR.md) の Decision to Make を検証する。全体の優先順位は [Technical Spikes](../../../../docs/spikes.md) を参照。

## Hypothesis

property と target runtime に結びつく semantic capability は無言の loss を防げる。

## Questions

どの粒度で false positive/negative が少ないか。Canvas/Host/Generator/AI が同じ判定を得るか。複合 capability を説明できるか。

## Prototype Scope

Stack/Button/Navigation/Toolbar/Remote Asset を SwiftUI/UIKit の複数 OS profile へ lowering し、node 単位・property 単位・contract 単位の registry を比較する。

## Out of Scope

全 framework API の列挙、未検証 target の Exact 宣言、UI pixel 一致の保証。

試作 code をそのまま production code に昇格させない。

## Measurements

false-positive/false-negative、diagnostic の理解可能性、registry entry 数と更新工数を記録する。

実行環境、fixture、command、実装 commit、raw data を記録する。必要なときだけ `artifacts/` を作成し、巨大な build output は commit しない。定量 budget は実験前に固定する。

## Success Criteria

Unsupported と Approximate を明確に区別し、Canvas/Host/Generator/AI の結果が一致する。

## Failure Criteria

Unsupported が通る、Approximate の loss が隠れる、または同じ node に consumer ごとに異なる判定が出る。

## Result

未実施。実測値、観察、失敗、成果物への link を記入する。

## Conclusion

未実施。結果が ADR の Options と Current Hypothesis をどう変えたかを記入し、削除前に commit する。

## Artifacts

未作成。検証時に必要な成果物だけをこの Spike ディレクトリの `artifacts/` に保存する。
