# Spike: SwiftUI Host reconciliation and state identity

## Related Decision

[ADR.md](../../ADR.md) の Decision to Make を検証する。全体の優先順位は [Technical Spikes](../../../../docs/spikes.md) を参照。

## Hypothesis

構造更新の種類ごとに再構築範囲と state reset を明示できる。

## Questions

どの更新で state が維持されるか。どの境界で subtree refresh が要るか。fresh load と同じ結果になるか。

## Prototype Scope

Text/Button/Stack/Navigation の小 tree で子追加・移動、kind/root 変更を繰り返し、stable ID、renderer 分割、root replacement を比較する。

## Out of Scope

任意 SwiftUI source の runtime 解釈、production app の DI/business state の再現。

試作 code をそのまま production code に昇格させない。

## Measurements

patch→frame p50/p95、focus/scroll/@State、再評価範囲、a11y tree、generated app の event trace を記録する。

実行環境、fixture、command、実装 commit、raw data を記録する。必要なときだけ `artifacts/` を作成し、巨大な build output は commit しない。定量 budget は実験前に固定する。

## Success Criteria

構造更新で保持できない state を診断し、fresh load と UI 結果が一致する。

## Failure Criteria

基本構造変更で結果が fresh load と異なる、または state loss を検出・表示できない。

## Result

未実施。実測値、観察、失敗、成果物への link を記入する。

## Conclusion

未実施。結果が ADR の Options と Current Hypothesis をどう変えたかを記入し、削除前に commit する。

## Artifacts

未作成。検証時に必要な成果物だけをこの Spike ディレクトリの `artifacts/` に保存する。
