# Frame and input feasibility

## Related Decision

[Android Native Preview transport](../../ADR.md)

## Hypothesis

公開 Emulator/ADB interface で Compose Host の frame と input を revision 付きで扱える。

## Questions

capture latency、frame ID、input mapping、headless lifecycle、複数 Emulator の資源消費はどうなるか。

## Prototype Scope

Text/Button の Compose Host と単一 IR patch、tap event の往復。

## Out of Scope

Production Host、Android Studio private API、全 capability coverage。

## Measurements

patch-to-frame p50/p95、input-to-event p50/p95、frame drop、CPU/memory、2 Emulator 実行時の変化。

## Success Criteria

revision を誤認せず、input が正しい UI event に届く。headless 起動・再接続が再現可能。

## Failure Criteria

frame と revision の対応が取れない、input routing が不安定、資源消費で通常編集が止まる。

## Result

未実施。

## Conclusion

未判定。

## Artifacts

測定結果と最小 prototype のみこの Spike の `artifacts/` に置く。
