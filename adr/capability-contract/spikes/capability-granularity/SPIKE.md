# Spike: Capability の契約粒度

## Related Decision

[ADR.md](../../ADR.md) の node / property / semantic-contract 粒度を比較する。

## Hypothesis

Semantic requirement を IR から抽出し、target と runtime version を含む profile で一度評価すれば、Human / AI / Preview / Generator の loss 判定を一致させられる。粒度ごとの保守費は測定する。

## Questions

- node / property / semantic-contract のどこで silent loss と過剰拒否が起きるか。
- 同一評価結果を四つの consumer が共有できるか。
- 複合 Navigation、binding、asset、runtime version、ordered effects、typed extension を表せるか。
- Button の event support を一 profile で変更した際の変更増幅はどれくらいか。

## Prototype Scope

テスト専用の `IR → SemanticRequirements → CapabilityEvaluator(profile, requirements) → LossReport` を作る。A–J の fixture、oracle、三候補、現行 TargetPlanner baseline を比較する。既存 `LayerPayload`、`Screen.navigation`、`AssetSource`、binding/event を可能な限り使う。未実装の ordered effects と typed target extension は非永続のテスト専用 probe にする。

Profile は実装済み macOS SwiftUI host subset と、明示的に製品 support を意味しない feasibility / approximation probe を分ける。iOS 15/16 の sheet detents 境界は Xcode 27 iOS SDK の SwiftUI interface の `@available(iOS 16.0, ...)` に基づく。[Apple API](https://developer.apple.com/documentation/swiftui/view/presentationdetents%28_%3A%29)。Android Compose の画像表示と Apple system symbol mapping は別 requirement とする。[Android image documentation](https://developer.android.com/develop/ui/compose/graphics/images/loading)。

## Out of Scope

Production Capability.swift / Format / Preview / Generator の変更、framework API 全列挙、iOS/Android Preview Host の動作保証、pixel 一致。Prototype を production code と見なさない。

## Measurements

候補から独立した [oracle.json](artifacts/oracle.json) を実装前に固定する。False positive は oracle が `unsupported` / `externalIntegrationRequired` / 未承認 `approximate` の requirement を候補が通すこと。False negative は oracle が `exact` / `portable` / profile が合う `targetSpecific` / 承認済み `approximate` の requirement を候補が拒否すること。候補は requirement ごとに比較し、scenario 全体では一つでも block があれば block とする。Loss report は承認済み approximate も明示する。

候補ごとに false positive、false negative、四 consumer 間の判定差、silent approximation、registry entry 数、fixture あたり requirement 数、重複宣言数、Button event 一 profile 変更時の宣言変更数を数える。現行 TargetPlanner は同じ fixture に対する baseline として測る。Result の `artifacts/capability-matrix.json` と `artifacts/granularity-comparison.md` に実測条件と結果を残す。

## Success Criteria

採用候補は false positive = 0、consumer divergence = 0、silent approximation = 0。False negative と保守費を測定して比較する。Approximate は承認時も loss report に残す。

## Failure Criteria

Unsupported / external integration / 未承認 approximate が通る、近似が隠れる、同じ requirement に consumer ごとに別判定が出る、または fixture の semantic requirement を抽出できない。

## Result

未実施。実測結果を記入する。

## Conclusion

未実施。Evidence が揃うまで ADR は Spike Required。

## Artifacts

- [oracle.json](artifacts/oracle.json): 候補実装前に固定した期待結果。
