# Fast Query Read Boundary

## Related Decision

[Index consistency](../../ADR.md)。Startup で発行した current witness を Query 許可へ使う場合、鮮度判定と実 SQLite row read の間に coordinated writer / Index rebuild が割り込めない境界を検証する。Writer の許可範囲は [External Git Write ADR](../../../git-external-write-coordination/ADR.md) に従う。

## Hypothesis

**Tentative:** Query は一つの `WorktreeCoordinator` lock 内で Ready gate、Stable CanonicalGeneration、published Index descriptor を process-local witness と比較し、同じ lock を保持したまま SQLite rows を読む。これにより coordinated writer と Index rebuild は、判定後から row read 完了までの間に公開状態を変更できない。照合不能なら rows を返さない。

## Questions

- 別 OS process の coordinated save は fast verdict と row read の間に lock を取得できるか。
- 別 OS process の Index rebuild は同じ区間に published generation を置換できるか。
- Save / rebuild 後に旧 witness は失効し、必要な slow verification を経た新 witness だけが rows を読めるか。
- pending、missing / corrupt generation、missing / corrupt / mismatched Index metadata、missing Index で rows を返さないか。
- Test-only candidate の Query rows は同じ Canonical state に対する production oracle Query と一致するか。

## Prototype Scope

`FastQueryReadBoundarySpikeTests` に test-only candidate Query を作り、実 `WorktreeCoordinator`、`CanonicalRepository`、`CanonicalGenerationStore`、`LocalIndex` metadata、および SQLite `components` / `component_availability` rows を使用する。Startup witness は同じ coordinated Snapshot 内の Stable generation、Index descriptor、現行 Git oracle を照合して発行する。Candidate は lock 内で witness と現在の generation / Index descriptor を比較し、その lock を保持したまま SQLite rows を読む。別 xctest OS process の save / rebuild worker は lock 取得の試行・取得・完了を file marker で通知する。Production Query の実装は変更しない。

## Out of Scope

Production Safe Fast Path 採用、automatic recovery、incremental reindex、性能測定、arbitrary external writer の current proof、APFS power-loss durability、Preview transport。

## Measurements

Correctness の deterministic barrier test として、reader が fast verdict の直後に worker の lock 試行を待ち、100 ms の観測窓を置いてから row read する。時間は throughput / latency の benchmark ではない。2026-09-27、arm64 macOS、Swift 6.4 の `swift test --filter FastQueryReadBoundarySpikeTests`: 5 tests、worker entry の2 skips、0 failures、13.83 秒。全 suite 実行とは別に数える。

## Success Criteria

Worker が lock を試みても reader の row read 完了までは取得できず、reader は旧 Snapshot に対応する rows を読む。Reader が lock を解放した後に worker が完了する。Save 後は旧 witness を拒否する。Index rebuild 後は旧 `IndexGenerationID` を拒否し、新たな slow verification で再発行した witness は current rows を読む。照合不能なら row read に達しない。

## Failure Criteria

判定と row read の間に worker が lock を取得する、旧 witness で新 Canonical state / Index generation の rows を返す、pending / missing / corrupt metadata を current と扱う、または production oracle と candidate の初期結果が異なる。

## Result

**Confirmed in tested coordinated interleavings:**

- Candidate の初期 `Alpha` `ComponentHit` 全フィールドは、同じ Snapshot に対する production Git-oracle Query と一致した。
- Reader が lock 内で witness と Stable generation / Index descriptor を照合した後、別 OS process の save worker は同じ lock の取得を試みた。Reader の実 SQLite row read 完了までは取得・save の marker が現れず、reader は旧 `Alpha` rows を返した。Lock 解放後に worker が取得・save し、旧 witness と production oracle Query は stale を拒否した。
- 別 OS process の Index rebuild worker も同様に row read 完了まで lock を取得できなかった。Rebuild は CanonicalGeneration を変えずに `IndexGenerationID` を変え、旧 witness は拒否された。新たな Git-oracle slow verification で発行した witness は `Alpha` rows を返した。
- Missing / malformed Index generation ID、wrong source identity、missing / empty / old / future source generation、missing Index、missing / corrupt / Pending CanonicalGeneration record では candidate は rows を返さなかった。

**Limits:** Candidate は test-only であり、production Query はまだこの witness を使わない。Worker は hamii protocol に参加する save / rebuild の2操作を表し、raw Git / external editor は含まない。100 ms barrier は lock 競合の確認であり、性能値ではない。任意の process scheduling、power loss、production query latency を証明しない。

## Conclusion

検証した coordinated save / Index rebuild では、fast verdict から SQLite row read 完了まで同じ lock を保持すると途中の公開状態を読まない。これは Safe Fast Path の read boundary を定義する Evidence であり、production 採用決定ではない。Index consistency ADR は `Spike Required`、Production Query は現行 Git oracle による fail-closed `staleIndex` 拒否を維持する。

## Artifacts

- [FastQueryReadBoundarySpikeTests.swift](../../../../Tests/HamiiTests/FastQueryReadBoundarySpikeTests.swift): test-only candidate と別 OS process race worker。
