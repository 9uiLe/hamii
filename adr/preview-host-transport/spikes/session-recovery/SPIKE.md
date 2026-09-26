# Host session and recovery

## Related Decision

[ADR.md](../../ADR.md) の「Preview Host の IPC / session protocol」を判断するための Evidence。

## Hypothesis

常駐 Host に ordered patch を送り、欠番後は snapshot で収束できる。

## Questions

どの transport が安定するか。Ack と revision は一致するか。Host restart 後に復旧するか。

## Prototype Scope

macOS coordinator と iOS Host で snapshot、連続 patch、欠番、切断・再接続、schema mismatch、複数 Surface を試す。

## Out of Scope

native frame capture、input event forwarding、production app の network layer。 試作 code を production code として扱わない。

## Measurements

接続成功率、patch/ack p50/p95/p99、欠番 recovery、CPU/メモリ、stale revision。 実行環境、fixture、command、実装 commit と raw data を記録し、事前に計測 budget を固定する。

## Success Criteria

欠番後に full snapshot で収束し、古い revision を current と表示しない。

## Failure Criteria

欠番が復旧しない、Ack の revision が曖昧、または通常編集で compile が必要。

## Result

Not yet validated。実測値、観察、失敗、成果物 link を記録する。

## Conclusion

Not yet validated。結果が ADR の判断に与える影響を記録し、削除前に commit する。

## Artifacts

未作成。必要になった場合だけ、この Spike の `artifacts/` に成果物を置く。
