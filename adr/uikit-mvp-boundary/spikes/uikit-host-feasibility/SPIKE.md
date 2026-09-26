# Spike: UIKit Preview の MVP inclusion

## Related Decision

[ADR.md](../../ADR.md) の Decision to Make を検証する。全体の優先順位は [Technical Spikes](../../../../docs/spikes.md) を参照。

## Hypothesis

UIKit factory は supported UI と navigation を runtime に組み立てられるが、MVP inclusion は lifecycle/工数次第である。

## Questions

system navigation を frame hack なしで構築できるか。patch/reconcile は lifecycle を守れるか。MVP gate に含める工数は妥当か。

## Prototype Scope

UIView/UIViewController、UIStackView、UINavigationController/toolbar の create、patch、reconcile を実装し SwiftUI Host との工数と coverage を比較する。

## Out of Scope

UIKit 全 API の対応、SwiftUI/UIkit の pixel 完全一致、production source generator の全機能。

試作 code をそのまま production code に昇格させない。

## Measurements

Auto Layout warnings、main-thread violations、controller lifecycle、patch→frame、残る unsupported node、実装工数を記録する。

実行環境、fixture、command、実装 commit、raw data を記録する。必要なときだけ `artifacts/` を作成し、巨大な build output は commit しない。定量 budget は実験前に固定する。

## Success Criteria

基本 node と system navigation が frame hack なしに動けば inclusion を検討。lifecycle 破綻なら Phase 5 へ送る。

## Failure Criteria

基本 control または navigation lifecycle が破綻する、Auto Layout warning が残る、または MVP の検証を著しく遅らせる。

## Result

未実施。実測値、観察、失敗、成果物への link を記入する。

## Conclusion

未実施。結果が ADR の Options と Current Hypothesis をどう変えたかを記入し、削除前に commit する。

## Artifacts

未作成。検証時に必要な成果物だけをこの Spike ディレクトリの `artifacts/` に保存する。
