# Spike: Native-semantic IR の最小 taxonomy

## Related Decision

[ADR.md](../../ADR.md) の Decision to Make。[Technical Spikes](../../../../docs/spikes.md) の 01 IR に対応。

## Hypothesis

typed node + separate domain graph + target extension で主要 screen を loss-aware に記述できる。

## Questions

主要画面を opaque field に逃げず記述できるか。SwiftUI/UIKit/Compose で loss が説明できるか。stable ID と round-trip は成立するか。

## Prototype Scope

7種程度の core node、refs、target override、validator と serializer を試作し代表 screen を encoding する。

## Out of Scope

全 framework API、native source import、production-ready editor。 試作 code をそのまま production code に昇格させない。

## Measurements

schema round-trip、opaque field 数、loss report、target lowering の差分。 対象環境、fixture、command、実装 commit と raw data を記録する。必要な成果物のみ `artifacts/` に保存する。

## Success Criteria

代表 screen の主要 UI intent を typed field で表せ、unsupported/loss を明示できる。

## Failure Criteria

主要画面が opaque field だらけ、または target-specific 分岐が core field を支配する。

## Result

未実施。実測値、観察、失敗、成果物 link を記録する。

## Conclusion

未実施。ADR の判断への影響を記録し、削除前に commit する。

## Artifacts

未作成。検証時に必要な成果物だけをこの Spike ディレクトリの `artifacts/` に保存する。
