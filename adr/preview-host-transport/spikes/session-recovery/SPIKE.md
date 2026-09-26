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

**Confirmed (build):** Swift 6.4 / Xcode 26.5 / iOS 26.5 SDK で `HamiiNativeRuntime` を `arm64-apple-ios17.0-simulator` 向けに build できた。独立した SwiftUI + Network.framework TCP Host probe も iOS Simulator Mach-O として compile できた。

**Confirmed (boot blocker):** macOS 26.2 の iPhone 17 Pro で `simctl boot` は default device set と新規 isolated device set の両方で `NSPOSIXErrorDomain code 53` となった。iPhone 17 Pro Max でも再現した。Preview Host install、launch、TCP connection はいずれも実行前だった。

**Measured (wait chain):** CoreSimulator log では `GTSimPortVendor` が 2 port を正常生成した後、`SimDeviceIOBundleInterface` の remote invocation が約 30 秒で timeout し、CoreSimulatorService が再起動した。起動中の CoreSimulatorService を `sample` すると、device bootstrap queue は `SimAudioProcessorServices` の bundle loading 中に ROCKit の remote reply を待っていた。相手の `SimAudioProcessorService` を `sample` すると、`AudioObjectAddPropertyListenerBlock` → CoreAudio `HALSystem::InitializeShell` → AVFCapture `CMIOProprietaryDefaultsSource` の同期 XPC reply 待ちで停止していた。

**Inferred:** boot failure は host 環境の Simulator audio/AV capture 初期化経路にある。**Unknown:** CMIO の XPC 相手が応答しない最深部の理由。**Blocked:** Preview Host の transport 測定と目視確認。接続成功率、patch/ack latency、欠番復旧、Host restart、schema mismatch、複数 Surface は未測定。

## Conclusion

Transport validation is currently blocked by an independent Simulator boot failure. Compile 成功は transport 成立の証拠ではない。Simulator が起動し、実際の Host で connect、patch delivery、frame/update latency、disconnect、reconnect、Host restart、session recovery を測るまで ADR を未解決にする。CMIO 側の応答停止は現在環境の Spike blocker として追跡する。現時点では hamii Product Architecture の独立した判断境界がないため、この blocker のためだけに別 ADR は作らない。

## Artifacts

- [SocketHost.swift](artifacts/SocketHost.swift): iOS Simulator TCP session 試作。production code ではない。
- [probe.py](artifacts/probe.py): Swift 6.4 compile、Simulator 起動、snapshot/patch/ack/reconnect を測る script。
- [result.json](artifacts/result.json): build 成功と Simulator 起動失敗の観測。
- [wait-chain.txt](artifacts/wait-chain.txt): CoreSimulatorService と SimAudioProcessorService の boot 中の sample、および CoreSimulator log に基づく待機経路。
