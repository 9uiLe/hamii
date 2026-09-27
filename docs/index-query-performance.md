# Production Query session performance

2026-09-28、arm64、macOS 27.0、Apple Swift 6.4、debug build。`IndexQuerySession` production implementation の test process 内測定。`HAMII_INDEX_QUERY_BENCHMARK_RESULT` を指定した `IndexQuerySessionTests.testMeasuredProductionQuerySessionCost` で、独立した Git worktree fixture と Repository 外 SQLite を使用した。各値は wall time の nearest-rank p50 / p95、単位 ms。1/1000/5000 Component fixture は component JSON shard 数だけが主に異なる。Query は同一 worktree 内の `ComponentHit` を返し、全条件で検証 path を assert した。

| Components | Cold session slow Bound (10) | Warm fast (40) | Full rebuild (5) | First Query after rebuild (5) | ExplicitlyUnbound slow (10) |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 344.856 / 385.189 | 1.360 / 2.038 | 363.909 / 391.336 | 344.802 / 389.456 | 358.483 / 375.595 |
| 1000 | 618.418 / 643.113 | 1.688 / 2.766 | 632.580 / 634.382 | 614.524 / 630.666 | 616.531 / 630.165 |
| 5000 | 1635.170 / 1682.507 | 3.966 / 5.371 | 1693.567 / 1717.051 | 1631.558 / 1641.758 | 1631.519 / 1899.270 |

Cell notation is **p50 / p95**. Cold session creates a new `IndexQuerySession` in the same OS process each time, so it is not CLI startup cost. Warm queries reuse one verified in-memory witness. Full rebuild includes CanonicalSnapshot acquisition, Git revision calculation, projection and SQLite write, not merely SQLite commit. First Query after rebuild takes the slow verification path because the IndexGenerationID changed. `ExplicitlyUnbound` never issues a warm witness. Five-sample rebuild p95 is only the largest observed value, not a stable tail estimate.

Separate one-shot CLI measurement: disposable copy of `Samples/Starter`, 10 JSON files, fresh Index, debug `hamii` executable, 40 independent `hamii --json query components` processes, empty hit set: **p50 361.839 ms / p95 378.192 ms**. The command processes do not share a witness. This environment, fixture, and run differ from the older Starter p95 418.612 ms measurement, so the values are not an improvement ratio. The 250 ms comparison target is not a Product SLA.

Correctness regressions in `IndexQuerySessionTests` verify the selected path, complete row equality with the slow oracle, bounded automatic recovery after a coordinated save, slow re-verification after Index replacement, explicit unbound slow-only behavior, missing/corrupt Canonical generation rejection, worktree isolation, and separate OS process save/rebuild blocking inside the fast verdict-to-row-read lock. These tests establish the checked interleavings, not power-loss durability or safety for noncoordinated writers.

Implementation commit `965ded3` was validated by `bash scripts/check.sh`: 114 Swift tests, 24 expected skips, 0 failures; architecture dependencies, ADR structure, documentation links, CLI contract, merge validation/publication, and sample validation all passed.

Warm same-process timing is not a one-shot CLI value, nor proof that the GUI currently uses this Query session. [Automatic full recovery](index-recovery-performance.md) has separate end-to-end measurements. A genuinely large production project and power-loss durability remain unmeasured. Incremental indexing is tracked in [Incremental Index Recovery ADR](../adr/incremental-index-recovery/ADR.md).

## Coordinated lock contention

同じ環境・1000 Component fixture で、長寿命 `IndexQuerySession` を別 OS process に1・2・4個作成し、各 process が cold verification 後に40回の warm Query を同時開始した。`IndexQuerySession` 内の計測 hook は `withReadyExclusive` 呼び出し直前から lock 取得直後までを測るため、表の lock wait は小さな call / gate overhead も含む。各行は全 process の samples を合わせた nearest-rank p50 / p95 ms。

| Concurrent readers | Query latency | Lock wait |
| ---: | ---: | ---: |
| 1 | 1.547 / 2.855 | 0.077 / 0.140 |
| 2 | 2.756 / 4.216 | 1.383 / 2.046 |
| 4 | 5.154 / 7.685 | 3.879 / 5.862 |

`testMeasuredWriterAndReaderWaiting` は deterministic 120 ms hold を使った単一交錯で、保持中の reader の後に入った writer は 137.371 ms、保持中の writer の後に入った warm reader は lock 取得まで 121.446 ms、Query 完了まで 124.771 ms かかった。両者は lock 解放後に完了した。単一 sample なので p95 として扱わない。

4 reader が各200回 warm Query を繰り返す別の負荷試験では、各 Query の fast verdict 後に **テスト用 5 ms hold** を加え、その間に writer lock contender を10回走らせた。Reader Query p50 / p95 は 40.667 / 50.745 ms、reader lock wait は 30.276 / 38.317 ms、writer lock wait は 30.435 / 34.238 ms。すべての reader と writer が試験内で完了した。この値には人工 hold と排他 lock の直列化が含まれ、通常の production latency と比較しない。有限の検証では starvation を観測しなかったが、全 scheduling 条件の保証ではない。

現 Editor の Component 一覧は `ProjectService.availableComponents` を使い、`IndexQuerySession` をまだ所有しない。Session lifecycle regression は production session を project open lifetime に保持し、coordinated mutation 後は自動復旧で slow→fast、close で破棄、reopen で cold に戻ることを確認する。別 worktree の2 session を A→B→A と使い、A の mutation が B の witness を失効させないことも確認する。将来 Editor の Index-backed search を追加する際は、その project-open lifetime に session を保持する。

Reader contention は現在の排他 `WorktreeCoordinator` に伴う性能上の tradeoff である。これらの測定だけを根拠に lock protocol を変更しない。Automatic full recovery の lock 計測は [Production Index recovery performance](index-recovery-performance.md) にあり、incremental indexing は [Incremental Index Recovery ADR](../adr/incremental-index-recovery/ADR.md) で検証中である。

この lifecycle / contention validation を追加した後の `bash scripts/check.sh` は、Swift 120 tests / 29 expected skips / 0 failures、architecture、ADR、documentation links、CLI、merge、sample checks がすべて成功した。前段の production implementation commit `8c11754` に対する Verify `36329894031` も success。今回の追補 commit の CI 結果は別に確認する。
