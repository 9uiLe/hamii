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
