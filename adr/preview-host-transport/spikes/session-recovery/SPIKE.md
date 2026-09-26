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

接続成功率、patch/ack p50/p95/p99、欠番 recovery、CPU/メモリ、stale revision。 実行環境、fixture、command、実装 commit と raw data を記録する。最初の iOS Simulator socket prototype の事前 budget は 10 回の接続成功率 100%、100 件の snapshot/patch ack p95 250 ms 以下、欠番後の snapshot 収束 100%、Host restart 後の再接続 100%、schema mismatch の拒否 100% とする。画面描画と multi-Surface 同時処理は別測定し、未測定なら未検証と明記する。

## Success Criteria

欠番後に full snapshot で収束し、古い revision を current と表示しない。

## Failure Criteria

欠番が復旧しない、Ack の revision が曖昧、または通常編集で compile が必要。

## Result

Swift 6.4 / Xcode 26.5 / iOS 26.5 SDK で `HamiiNativeRuntime` を `arm64-apple-ios17.0-simulator` 向けに build できた。独立した SwiftUI + Network.framework TCP Host probe も iOS Simulator Mach-O として compile できた。macOS 26.2 の iPhone 17 Pro に `simctl boot` を実行すると、default device set と新規作成した isolated device set の両方で `NSPOSIXErrorDomain code 53` となり、Simulator を起動できなかった。CoreSimulator log は `GTSimPortVendor createDefaultPortsForDevice` の 30 秒 timeout と CoreSimulatorService の接続断を示した。したがって接続成功率、patch/ack latency、欠番復旧、Host restart、schema mismatch、複数 Surface は未測定。

## Conclusion

Cross-platform Swift package と試作 Host の compile は成立した。Transport の採否を判断する Runtime Evidence は得られていない。Simulator 起動が安定する環境で probe を再実行し、事前 budget に照らして判断する。原因が Host code にあるとは結論しない。

## Artifacts

- [SocketHost.swift](artifacts/SocketHost.swift): iOS Simulator TCP session 試作。production code ではない。
- [probe.py](artifacts/probe.py): Swift 6.4 compile、Simulator 起動、snapshot/patch/ack/reconnect を測る script。
- [result.json](artifacts/result.json): build 成功と Simulator 起動失敗の観測。
