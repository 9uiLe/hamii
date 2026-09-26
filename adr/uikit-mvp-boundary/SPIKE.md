# Spike: UIKit Preview の MVP inclusion

- **Status:** 未実施
- **Related plan:** [Technical Spikes](../../docs/spikes.md) — 03 UIKit Runtime
- **Decision:** [ADR.md](ADR.md)

## Hypothesis

UIKit factory は supported UI と navigation を runtime に組み立てられるが、MVP inclusion は lifecycle/工数次第である。

## Method

UIView/UIViewController、UIStackView、UINavigationController/toolbar の create、patch、reconcile を実装し SwiftUI Host との工数と coverage を比較する。

## Evidence to collect

Auto Layout warnings、main-thread violations、controller lifecycle、patch→frame、残る unsupported node、実装工数を記録する。 対象 OS/SDK/Xcode、fixture、実装 commit、実行 command、raw trace、screenshot を同じディレクトリ内の `artifacts/` に保存する。大きな動画や binary は repository の asset policy に従い、ここから参照する。

## Pass / fail gate

基本 node と system navigation が frame hack なしに動けば inclusion を検討。lifecycle 破綻なら Phase 5 へ送る。 失敗した場合は Supported Domain または実装順序を変更し、その理由を ADR と現行設計に反映する。

## Result

未実施。計測値、失敗、判断、反映先を記入する。
