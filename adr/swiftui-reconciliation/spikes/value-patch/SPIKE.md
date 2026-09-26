# Value patch without compilation

## Related Decision

[ADR.md](../../ADR.md) の SwiftUI reconciliation strategy に対し、値更新の経路を検証する。

## Hypothesis

事前 compile 済み node renderer と observable snapshot で、text/padding/fixture/state の変更を source build なしに反映できる。

## Questions

値更新は compile なしに frame へ反映されるか。focus/scroll/@State は保持されるか。更新範囲は局所的か。

## Prototype Scope

Text/Button/Stack の固定構造で text、padding、token、fixture、local state を連続更新する。

## Out of Scope

子の追加・移動、kind/root 変更、任意 SwiftUI source の実行。試作 code を production code とみなさない。

## Measurements

patch→frame p50/p95、body reevaluation、focus/scroll/@State、CPU/メモリ、build invocation の有無を記録する。対象 OS/SDK と fixture を固定する。

## Success Criteria

値更新が compile なしで native frame に反映され、state retention と revision 対応が記録できる。

## Failure Criteria

値更新で source build が必要、または frame と revision が一致せず原因を診断できない。

## Result

Not yet validated。実測値と成果物 link を記録する。

## Conclusion

Not yet validated。ADR の判断への影響を記録し、削除前に commit する。

## Artifacts

未作成。必要になった場合だけこの Spike の `artifacts/` を作る。
