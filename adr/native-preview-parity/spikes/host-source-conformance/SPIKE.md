# Host/source conformance

## Related Decision

[ADR.md](../../ADR.md) の Decision to Make。

## Hypothesis

同じ IR/fixture/OS の Host と生成アプリを比較する。

## Questions

差の種類と発生箇所を説明できるか。single pixel metric は誤判定するか。

## Prototype Scope

Text/Button/Navigation の fixture で frame、a11y tree、event trace、visual を採取する。

## Out of Scope

全 OS/device の自動認定。 試作 code を production code とみなさない。

## Measurements

bounds、role/label/focus、event/state trace、visual difference。 対象環境、fixture、command、実装 commit、raw data を記録する。定量 budget は実験前に決める。

## Success Criteria

supported field の差を説明でき、silent semantic loss がない。

## Failure Criteria

supported field に説明不能な差があり、loss を診断できない。

## Result

Not yet validated。実測値・失敗・成果物 link を記録する。

## Conclusion

Not yet validated。ADR への影響を記録し、削除前に commit する。

## Artifacts

未作成。必要になった場合だけこの Spike の `artifacts/` を作る。
