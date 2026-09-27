# Production Index recovery performance

2026-09-28、arm64 macOS 27.0、Swift 6.4 debug、Repository 外 SQLite。`IndexQuerySessionTests.testMeasuredProductionFullRecoveryCost` は 1 / 1000 / 5000 Component の分割 JSON fixture を使い、missing Index と stale Bound Index を各3回測定する。`Recovered Query` は最初の失敗判定、自動 full rebuild、再 Query を含む。p95 は各3標本の最大値であり Product SLA ではない。

| Components | Condition | Phase 1 lock p95 | Off-lock build p95 | Phase 2 lock p95 | Recovery service total p95 | Recovered Query p95 |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | missing | 366.31 ms | 10.91 ms | 357.47 ms | 735.89 ms | 1088.13 ms |
| 1 | stale Bound | 361.21 ms | 10.19 ms | 358.92 ms | 731.05 ms | 1067.83 ms |
| 1000 | missing | 621.98 ms | 25.32 ms | 347.14 ms | 992.29 ms | 1885.21 ms |
| 1000 | stale Bound | 628.07 ms | 24.07 ms | 353.44 ms | 999.68 ms | 1911.01 ms |
| 5000 | missing | 1683.95 ms | 69.90 ms | 389.93 ms | 2143.44 ms | 5051.98 ms |
| 5000 | stale Bound | 1628.25 ms | 86.70 ms | 396.75 ms | 2094.59 ms | 5006.30 ms |

Phase 1 lock は coherent CanonicalSnapshot の parse、Stable generation、Git oracle、公開 Index の read-only 分類を含む。Off-lock は immutable Snapshot からの full `IndexProjection`、別 SQLite file への書き込みと検証を含む。Phase 2 lock は Stable generation、Git oracle、expected published state の再検証と atomic replace を含む。Recovery service total は最初の Query 失敗判定と再 Query を含まない。

別 OS process の writer lock probe は、5000 Component の Phase 1 開始時に単一試行で **1640.62 ms**、1000 Component の candidate SQLite transaction 中に単一試行で **0.109 ms** 待った。後者は off-lock build の人工 barrier であり、通常の writer latency 分布ではない。測定条件では Phase 1 の Canonical 観測が主な連続 lock 時間を占める。実 Product の大規模 project、任意の非協調 writer、停電耐久性はこの測定からは評価できない。

## Recovered Query の観測回数

`IndexQuerySessionTests.testRecoveredQueryObservationBaselineCounts` は、1 Component fixture の missing Index と coordinated save 後の stale Bound Index を別々に実行した。両条件とも1回の recovered Query で、Query の full CanonicalSnapshot 取得2回、Recovery Phase 1 の取得1回、Git revision 計算3回、worktree lock 取得6回、slow Query 2回、Query retry 1回だった。Retry は full Snapshot と Git oracle を再実行しており、fast rows read は0回だった。この実測回数は観測引き継ぎ候補を比較する baseline であり、観測回数の削減を安全性の代替証明にはしない。

## Observation handoff の検証

`HAMII_OBSERVATION_HANDOFF_BENCHMARK_RESULT=<path> swift test --filter IndexQuerySessionTests/testMeasuredObservationHandoffCandidate` は同じ macOS / Swift debug 環境で baseline と候補を各条件3回測定した。セルは p50 / p95 ms、p95 は3標本の最大値。`Initial observation` は Query 開始から recovery source 捕捉まで、`Retry` は公開後の Query 再試行全体。Fixture 作成時間は含まない。

| Components | Condition | Path | Recovered Query | Initial observation | Off-lock build | Phase 2 lock | Retry | Max measured lock |
| ---: | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | missing | baseline | 1055.61 / 1080.34 | 338.68 / 347.14 | 7.57 / 9.25 | 350.22 / 373.06 | 356.51 / 365.79 | 365.17 / 373.06 |
| 1 | missing | handoff | 712.16 / 729.18 | 356.11 / 360.63 | 10.03 / 10.17 | 343.51 / 360.05 | 1.45 / 1.56 | 360.05 / 360.20 |
| 1 | stale Bound | baseline | 1060.73 / 1074.05 | 353.65 / 362.62 | 7.51 / 9.99 | 350.57 / 354.21 | 357.48 / 361.39 | 360.05 / 360.48 |
| 1 | stale Bound | handoff | 705.34 / 717.81 | 343.66 / 366.80 | 8.30 / 8.61 | 345.29 / 360.85 | 1.56 / 1.62 | 360.85 / 366.51 |
| 1000 | missing | baseline | 1879.73 / 1888.00 | 880.04 / 886.00 | 25.04 / 25.70 | 347.94 / 351.48 | 628.19 / 633.72 | 627.34 / 632.89 |
| 1000 | missing | handoff | 975.85 / 1017.86 | 605.15 / 642.49 | 24.23 / 24.72 | 344.77 / 348.92 | 2.44 / 2.49 | 604.85 / 642.20 |
| 1000 | stale Bound | baseline | 1909.67 / 1921.85 | 885.99 / 902.39 | 22.34 / 23.64 | 351.73 / 357.55 | 631.88 / 653.50 | 638.88 / 652.59 |
| 1000 | stale Bound | handoff | 970.06 / 990.43 | 603.02 / 630.62 | 22.60 / 23.59 | 341.67 / 347.59 | 2.18 / 2.42 | 602.80 / 630.34 |
| 5000 | missing | baseline | 5011.23 / 5160.34 | 2893.92 / 2928.26 | 66.18 / 68.41 | 378.31 / 393.66 | 1669.12 / 1772.88 | 1667.66 / 1771.51 |
| 5000 | missing | handoff | 2083.47 / 2100.57 | 1632.87 / 1647.36 | 68.23 / 68.71 | 376.37 / 378.08 | 5.79 / 5.92 | 1632.62 / 1647.11 |
| 5000 | stale Bound | baseline | 5031.64 / 5038.09 | 2875.98 / 2893.52 | 65.45 / 66.18 | 397.30 / 405.02 | 1689.60 / 1718.99 | 1688.14 / 1717.58 |
| 5000 | stale Bound | handoff | 2088.39 / 2092.53 | 1624.23 / 1626.53 | 66.36 / 69.22 | 392.74 / 393.50 | 5.33 / 5.46 | 1623.95 / 1626.26 |

Production Query は、検証済みの初回観測から復旧 source を作れる場合に handoff を使用する。比較試験では Query Snapshot 2回 + Recovery Phase 1 Snapshot 1回が Query Snapshot 1回になり、Git oracle 3回が2回、lock 取得6回が4回になった。公開後の retry は process-local proof から既存 fast path を開始し、**別の lock を再取得して** Stable generation と公開 Index descriptor を確認してから同じ lock 下で rows を読む。Candidate build 中の coordinated writer、公開後から retry 前の writer、Index generation 置換を注入した回帰テストは、古い rows の拒否または新世代の slow 再検証に収束した。Missing / stale Bound / obsolete / malformed / corrupt の `ComponentHit` 全フィールドは baseline と一致した。External edit、ExplicitlyUnbound、Git hidden flag、pending gate は handoff 対象外だった。

別 OS writer が5000 Component の候補初回 slow observation に競合した3標本の待機時間は p50 **1632.31 ms**、p95 **1694.47 ms**。Handoff は一回の recovered Query の重複観測を減らすが、残る一回の Snapshot parse による連続 lock 時間は短縮しない。`Max measured lock` は test hook 間の時間であり、lock 解放の数命令分を含まない。値は local debug fixture の mechanism comparison に限り、Product SLA ではない。
