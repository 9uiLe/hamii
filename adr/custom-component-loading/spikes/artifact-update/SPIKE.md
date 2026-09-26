# Custom Component artifact update

## Related Decision

[ADR.md](../../ADR.md) の Decision to Make。

## Hypothesis

custom component 更新の必要 build 範囲を計測できる。

## Questions

source 変更後に relink/install/restart は必要か。状態は失われるか。

## Prototype Scope

SwiftUI custom View と UIKit custom UIView を変更し、Host 更新を試す。

## Out of Scope

任意 source の visual edit、全 platform の artifact 配布。 試作 code を production code とみなさない。

## Measurements

build/relink/install/launch 時間、署名 error、state loss。 対象環境、fixture、command、実装 commit、raw data を記録する。定量 budget は実験前に決める。

## Success Criteria

必要 step が再現可能で、UI が事前に build class を正しく表示できる。

## Failure Criteria

部分 build と表示したのに full install が必要、または安全な読み込みができない。

## Result

Not yet validated。実測値・失敗・成果物 link を記録する。

## Conclusion

Not yet validated。ADR への影響を記録し、削除前に commit する。

## Artifacts

未作成。必要になった場合だけこの Spike の `artifacts/` を作る。
