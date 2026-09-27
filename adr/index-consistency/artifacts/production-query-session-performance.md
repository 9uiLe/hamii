# Production Query session performance

2026-09-28、arm64、macOS 27.0、Apple Swift 6.4、debug build。`IndexQuerySession` production implementation の test process 内測定。`HAMII_INDEX_QUERY_BENCHMARK_RESULT` を指定した `IndexQuerySessionTests.testMeasuredProductionQuerySessionCost` で、独立した Git worktree fixture と Repository 外 SQLite を使用した。各値は wall time の nearest-rank p50 / p95、単位 ms。1/1000/5000 Component fixture は component JSON shard 数だけが主に異なる。Query は同一 worktree 内の `ComponentHit` を返し、全条件で検証 path を assert した。

| Components | Cold session slow Bound (10) | Warm fast (40) | Full rebuild (5) | First Query after rebuild (5) | ExplicitlyUnbound slow (10) |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 344.856 / 385.189 | 1.360 / 2.038 | 363.909 / 391.336 | 344.802 / 389.456 | 358.483 / 375.595 |
| 1000 | 618.418 / 643.113 | 1.688 / 2.766 | 632.580 / 634.382 | 614.524 / 630.666 | 616.531 / 630.165 |
| 5000 | 1635.170 / 1682.507 | 3.966 / 5.371 | 1693.567 / 1717.051 | 1631.558 / 1641.758 | 1631.519 / 1899.270 |

Cell notation is **p50 / p95**. Cold session creates a new `IndexQuerySession` in the same OS process each time, so it is not CLI startup cost. Warm queries reuse one verified in-memory witness. Full rebuild includes CanonicalSnapshot acquisition, Git revision calculation, projection and SQLite write, not merely SQLite commit. First Query after rebuild takes the slow verification path because the IndexGenerationID changed. `ExplicitlyUnbound` never issues a warm witness. Five-sample rebuild p95 is only the largest observed value, not a stable tail estimate.

Separate one-shot CLI measurement: disposable copy of `Samples/Starter`, 10 JSON files, fresh Index, debug `hamii` executable, 40 independent `hamii --json query components` processes, empty hit set: **p50 361.839 ms / p95 378.192 ms**. The command processes do not share a witness. This environment, fixture, and run differ from the older Starter p95 418.612 ms measurement, so the values are not an improvement ratio. The 250 ms comparison target is not a Product SLA.

Correctness regressions in `IndexQuerySessionTests` verify the selected path, complete row equality with the slow oracle, stale after coordinated save, slow re-verification after rebuild and atomic file replacement, explicit unbound slow-only behavior, missing/corrupt metadata and generation rejection, worktree isolation, and separate OS process save/rebuild blocking inside the fast verdict-to-row-read lock. These tests establish the checked interleavings, not power-loss durability or safety for noncoordinated writers.

Implementation commit `965ded3` was validated by `bash scripts/check.sh`: 114 Swift tests, 24 expected skips, 0 failures; architecture dependencies, ADR structure, documentation links, CLI contract, merge validation/publication, and sample validation all passed.

Reader-reader contention latency, reader-writer tail latency, GUI lifetime behavior, and a genuinely large production project remain unmeasured. Warm same-process timing is not a one-shot CLI value, nor proof that the GUI currently uses this Query session. Recovery policy and incremental indexing remain in `index-recovery-strategy`.
