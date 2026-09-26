# Metadata prototype

## Related Decision

[Swift Macro の責務境界](../../ADR.md)

## Hypothesis

Property/patch metadata の限定生成は Canonical schema を変更せず重複を減らせる。

## Questions

Swift 6.4 の build overhead、error diagnostics、property rename 時の差分は許容できるか。

## Prototype Scope

Text Layer の property metadata と patch path のみを Macro と手動実装で比較する。

## Out of Scope

Production schema、全 IR node、Inspector UI の全面生成。

## Measurements

clean/incremental build 時間、記述行数、diagnostic quality、rename 時の emitted metadata diff。

## Success Criteria

Canonical JSON key を維持し、手動重複と作業時間を減らし、失敗時の原因を診断できる。

## Failure Criteria

schema が Macro output に結合する、build が著しく増える、error location が不明になる。

## Result

未実施。

## Conclusion

未判定。

## Artifacts

必要な測定結果だけこの Spike の `artifacts/` に置く。
