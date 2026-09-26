# Compose IR validation

## Related Decision

[ADR.md](../../ADR.md) の Decision to Make。

## Hypothesis

早期の小 lowering で IR の Apple 偏重を検出できる。

## Questions

core node を Compose に説明可能に写せるか。CMP iOS は Android と同じ Host を使えるか。

## Prototype Scope

Text/Button/Stack/Navigation の Target Plan→Compose Android を小さく試作し、CMP 差を調査する。

## Out of Scope

CMP Host の production 実装、全 Compose API。 試作 code を production code とみなさない。

## Measurements

target-specific override 数、loss report、recomposition、implementation effort。 対象環境、fixture、command、実装 commit、raw data を記録する。定量 budget は実験前に決める。

## Success Criteria

IR 修正点が明確になり、Android/CMP の別 target 境界を説明できる。

## Failure Criteria

基本 node が大量の framework 特例を要する、または差を capability で表せない。

## Result

Not yet validated。実測値・失敗・成果物 link を記録する。

## Conclusion

Not yet validated。ADR への影響を記録し、削除前に commit する。

## Artifacts

未作成。必要になった場合だけこの Spike の `artifacts/` を作る。
