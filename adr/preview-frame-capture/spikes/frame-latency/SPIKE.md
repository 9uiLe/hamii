# Frame capture and revision fidelity

## Related Decision

[ADR.md](../../ADR.md) の「Native Preview frame の取得・表示方式」を判断するための Evidence。

## Hypothesis

Host から frame を転送しても編集用 AppSurface に十分な応答性を保てる。

## Questions

どの capture API が使えるか。frame は revision と対応するか。連続更新の latency/帯域は許容できるか。

## Prototype Scope

SwiftUI Host の値 patch 後に frame を取得し、Canvas へ表示。resize/scale、切断、連続 drag を比較する。

## Out of Scope

input forwarding、IPC session protocol の詳細、production app の pixel parity。 試作 code を production code として扱わない。

## Measurements

patch→frame p50/p95/p99、drop、CPU/メモリ、解像度、stale frame 表示。 実行環境、fixture、command、実装 commit と raw data を記録し、事前に計測 budget を固定する。

## Success Criteria

frame と revision が一致し、事前 budget 内で表示できる。

## Failure Criteria

古い frame を current と表示する、または capture latency が budget を超える。

## Result

Not yet validated。実測値、観察、失敗、成果物 link を記録する。

## Conclusion

Not yet validated。結果が ADR の判断に与える影響を記録し、削除前に commit する。

## Artifacts

未作成。必要になった場合だけ、この Spike の `artifacts/` に成果物を置く。
