# Startup Current Witness

## Related Decision

[Index consistency](../../ADR.md)。Shared CanonicalGeneration を production writer に接続した後、新しい reader session が published Index を current として再利用できるという **process-local positive witness** を、どの観測から発行できるかを検証する。Writer の許可範囲は [External Git Write ADR](../../../git-external-write-coordination/ADR.md) が決める。

## Hypothesis

**Tentative:** 新 process は必ず `Unknown` で始める。`WorktreeCoordinator` の一つの lock 内で Canonical recovery / Ready gate、coherent Snapshot、Stable CanonicalGeneration、Index descriptor、現行 Git freshness oracle を照合して初めて witness を発行できる。発行後の候補判定は shared generation と Index descriptor の再照合だけで行えるが、production Query の結果には使わない。

## Questions

- Startup の検証途中に別 hamii process が save を挟めるか。
- restart 後に process-local witness を再利用せず、同じ Index へ新しい slow verification を通せるか。
- Index を同じ Snapshot から再構築したとき、旧 witness が `IndexGenerationID` の変化で失効するか。
- missing / corrupt generation、Pending gate、missing / corrupt / old / future Index metadata、Git oracle unverifiable は positive witness を出さないか。
- 検証済み witness の warm shadow check と初回 slow verification の cost はどの程度か。

## Prototype Scope

`ProductionGenerationShadowSpikeTests` に test-only `ProductionWitness` 発行と shadow verdict を追加・拡張した。実 `CanonicalRepository.withCoordinatedSnapshot`、`CanonicalGenerationStore`、`WorktreeCoordinator`、SQLite `LocalIndex`、`GitCanonicalRevisionCalculator` を使用する。`withCoordinatedSnapshot` は journal recovery と Ready gate の後、callback が終わるまで同じ lock を保持する。発行時の `LocalIndex.assertCurrent` が実 Git oracle を通す。発行後の test-only verdict は lock 内で Stable generation と published Index descriptor を確認し、Snapshot full parse / Git oracle を再実行しない。Production Query は既存 oracle を使い続ける。

## Out of Scope

Generation fast path の production 採用、automatic recovery UX、incremental reindex、任意の非協調 writer に対する positive proof、process-local witness の永続化、APFS power-loss durability、Preview transport。

## Measurements

2026-09-27、arm64 macOS、Swift 6.4。Starter copy と tracked 1000-component fixture。coordinated slow witness issuance と production oracle Query は各10回、warm test-only verdict は40回、fresh xctest OS process 起動から witness result 書込まで各5回。nearest-rank p50 / p95、単位 ms。結果の raw categories は [timing.json](artifacts/timing.json)。fresh process の値には xctest 起動と IPC/file output が含まれ、純粋な boot verification latency ではない。

| Fixture | Slow witness p50 / p95 | Warm shadow p50 / p95 | Oracle Query p50 / p95 | Fresh process + witness p50 / p95 |
| --- | ---: | ---: | ---: | ---: |
| Starter copy | 360.094 / 371.097 | 1.146 / 1.903 | 350.380 / 380.036 | 476.709 / 483.261 |
| 1000 tracked components | 623.473 / 640.766 | 1.083 / 1.664 | 621.128 / 633.465 | 613.410 / 666.669 |

Warm shadow は production CanonicalGeneration record / Index metadata を使う **test-only candidate** であり、production Safe Fast Path、Query latency、Product SLA の値ではない。

## Success Criteria

Process startup は `Unknown`。一つの coordinated slow observation の後だけ witness を出す。Snapshot identity、Stable generation、Index source identity / generation / ID と Git oracle が一致する。Index rebuild と coordinated writer transition は旧 witness を失効させる。missing / corrupt / pending は推測で current にしない。検証した coordinated interleaving で shadow `KnownCurrent` と production oracle に矛盾がない。Raw writer による false current は保証境界外の負例として明示する。

## Failure Criteria

Generation equality だけで初回 witness を出す、restart 前の witness を再利用する、Index replacement で旧 witness が残る、verification 中に coordinated writer が入って mixed observation を発行する、pending / corrupt state を自動 current にする、または保証内の coordinated writer 変更で shadow `KnownCurrent` と oracle が矛盾する。

## Result

**Confirmed in tested production-object Spike:**

- 新 OS process の `productionShadow(nil)` は `Unknown`。その process が同じ worktree lock の内側で Snapshot、Stable generation、Index descriptor、Git oracle を検証した後だけ witness を得た。Witness は test process 内の値であり disk へ保存しない。
- 同じ Snapshot の Index rebuild は CanonicalGeneration / Snapshot identity を変えず `IndexGenerationID` を変え、旧 witness は `Unknown`。現行 oracle Query は fresh のままで、新 witness は再度 slow verification を通った。
- Generation record 欠損時の Repository open は検証済み Snapshot から新 lineage を bootstrap したが、旧 Index source generation との不一致で witness は出なかった。新 lineage で Index rebuild した後にのみ発行した。Corrupt record は observation を拒否した。
- Missing Index、missing / malformed Index generation ID、wrong source identity、missing / empty / old / future source generation、および `assume-unchanged` による Git oracle unverifiable は witness 発行を拒否した。既存の pending gate と SIGKILL tests は [production generation integration](../production-generation-integration/SPIKE.md) に保持する。
- 別 xctest writer process が witness slow verification 中に同じ `flock` の取得を試みた。Reader が lock を保持している間、writer の acquired / completed marker は作られず、verification 後に取得・save した。旧 witness は `Stale`、現行 Query oracle は `Stale`。Writer 完了後に開始した reader は旧 Index から witness を得ず、再構築後の新 Snapshot / generation / Index を検証した。
- 通常 save、別 process save、managed switch、validated merge、A→B→A、no-op、SIGKILL recovery、raw file edit / raw Git switch は [production generation integration](../production-generation-integration/SPIKE.md) の実 OS process matrix に残る。検証した coordinated case の shadow / oracle 矛盾はない。Raw writer の場合は shared generation が変わらず candidate shadow が false current、現行 oracle は `staleIndex` となる **contract-bound counterexample** である。

**Unknown / not implemented:** Production Query への witness 接続、witness lifetime / cache policy、automatic slow fallback、unknown / corrupt record の製品 UX、general atomic IndexGeneration publication、large-project scaling beyond 1000 components、non-coordinated writer の観測保証、power-loss durability。今回の test-only helper は production permission boundary ではない。

## Conclusion

一つの coordinated observation による `Unknown → VerifiedCurrentWitness` 発行と、shared generation / IndexGenerationID による失効は、検証した production-object interleaving で成立した。これは writer guarantee が守られる worktree 内の **Safe Fast Path 候補を比較する Evidence** であり、採用決定ではない。Index consistency ADR は `Spike Required`、production Query は Git oracle による `staleIndex` 拒否を維持する。

## Artifacts

- [timing.json](artifacts/timing.json): 上記条件での p50 / p95。再現: `HAMII_STARTUP_WITNESS_BENCHMARK_RESULT=/tmp/hamii-startup-witness-timing.json swift test --filter ProductionGenerationShadowSpikeTests.testMeasuredP4StartupWitnessCost`。
- [ProductionGenerationShadowSpikeTests.swift](../../../../Tests/HamiiTests/ProductionGenerationShadowSpikeTests.swift): `testP4...` と worker / benchmark。候補 witness は test-only。
