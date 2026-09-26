# Spike: SwiftUI Host reconciliation and state identity

- **Status:** 未実施
- **Related plan:** [Technical Spikes](../../docs/spikes.md) — 02 SwiftUI Runtime / 04 Patch Runtime
- **Decision:** [ADR.md](ADR.md)

## Hypothesis

値更新と構造更新を区別すれば、SwiftUI Host は compile なし更新と state reset の明示を両立できる。

## Method

Text/Button/Stack/Navigation の小 tree で text/padding、子追加・移動、kind/root 変更を繰り返し、stable ID、renderer 分割、root replacement を比較する。

## Evidence to collect

patch→frame p50/p95、focus/scroll/@State、再評価範囲、a11y tree、generated app の event trace を記録する。 対象 OS/SDK/Xcode、fixture、実装 commit、実行 command、raw trace、screenshot を同じディレクトリ内の `artifacts/` に保存する。大きな動画や binary は repository の asset policy に従い、ここから参照する。

## Pass / fail gate

値更新は compile 不要。保持できない state をすべて診断し、fresh load と UI 結果が一致する。 失敗した場合は Supported Domain または実装順序を変更し、その理由を ADR と現行設計に反映する。

## Result

未実施。計測値、失敗、判断、反映先を記入する。
