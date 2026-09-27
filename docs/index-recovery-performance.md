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

## Canonical observation stage profile

`HAMII_CANONICAL_OBSERVATION_PROFILE_RESULT=<path> swift test --filter IndexQuerySessionTests/testMeasuredCanonicalObservationStages` で、1 / 1000 / 5000 Component と mixed semantic fixture を各5回計測した。同じ arm64 macOS 27.0 / Swift 6.4 debug 環境で、missing Index の `IndexRecoveryService.recoverOnce()` を使用。Fixture 作成は計測外、`Total recovery` は Phase 2 と別 SQLite candidate build を含み、Query 開始と再試行は含まない。各セルは **p50 / p95 ms**、p95 は5標本の最大値であり Product SLA ではない。計測フックは operation 完了時に単調時計を読む。`Phase 1` と `Snapshot` は内側の stage を包含するため、列を合算しない。

| Fixture | Phase 1 | Snapshot | Canonical path 列挙・symlink 確認 | Entity folder 列挙 | Entity bytes 読込 | Entity decode | Identity bytes 再読込 | Git oracle | Total recovery |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 364.57 / 377.34 | 2.47 / 2.92 | 0.65 / 0.86 | 0.44 / 0.50 | 0.11 / 0.14 | 0.09 / 0.10 | 0.27 / 0.35 | 361.23 / 373.00 | 726.03 / 752.17 |
| 1000 | 619.65 / 633.60 | 280.68 / 289.70 | 140.84 / 150.69 | 49.65 / 50.88 | 24.24 / 26.20 | 17.88 / 18.82 | 30.03 / 32.08 | 340.84 / 347.66 | 988.66 / 1000.02 |
| 5000 | 1650.05 / 1685.43 | 1287.71 / 1321.87 | 639.02 / 653.22 | 166.09 / 171.96 | 134.81 / 140.64 | 90.16 / 90.86 | 160.35 / 189.58 | 362.99 / 371.74 | 2083.58 / 2119.78 |
| Mixed | 333.14 / 343.50 | 4.86 / 4.92 | 1.93 / 1.96 | 0.48 / 0.50 | 0.56 / 0.57 | 0.41 / 0.42 | 0.73 / 0.73 | 327.74 / 337.02 | 663.19 / 688.66 |

5000 Component では path 列挙・symlink 確認の p50 が **639.02 ms**、Snapshot 全体の約半分だった。Git oracle は **362.99 ms**。Entity decode の **90.16 ms** と Document validation の **36.44 ms** は主因ではない。Entity decode 入力は **3,476,771 bytes**、identity 用の再読込は **3,477,459 bytes**。後者は manifest と Agent profiles も含む。二重読込の事実は確認したが、現条件では metadata/path 観測の費用がさらに大きい。次の最適化方式はこの計測だけで決めない。Git oracle、CanonicalSnapshot identity、symlink rejection、writer lock、fail-closed 判定は維持する。

`testCanonicalObservationProfilingPreservesSnapshotAndQueryResults` はフック ON/OFF で Snapshot identity、Document、Stable generation、validation diagnostics、Git revision、recovery eligibility、`ComponentHit` 全フィールドが一致することと、Canonical manifest が変化しないことを確認した。`HAMII_CANONICAL_OBSERVATION_WRITER_TIMELINE_RESULT=<path> swift test --filter IndexQuerySessionTests/testMeasuredCanonicalObservationWriterTimeline` は5000 Component の Phase 1 中に別 OS process の writer lock probe を投入した。reader lock 取得を基点に、writer lock attempt **+70 ms**、component folder 列挙完了 **+256 ms**、entity bytes 読込完了 **+513 ms**、Canonical path/symlink 確認完了 **+1171 ms**、identity bytes 読込完了 **+1330 ms**、Snapshot 完了 **+1344 ms**、Git oracle 完了 **+1721 ms**、writer lock 取得 **+1722 ms**。writer 待機は **1651.62 ms**。これは単一の lock 競合試行であり writer latency の分布や power-loss durability を示さない。フックは lock を解放せず、production の観測・判定経路を変更しない。

### Canonical path observation の内訳

`HAMII_CANONICAL_PATH_PROFILE_RESULT=<path> swift test --filter IndexQuerySessionTests/testMeasuredCanonicalPathBreakdown` は同じ fixture 4種をそれぞれ5回測定する。各セルは **p50 / p95 ms**、p95 は5標本の最大値。`canonicalJSONPaths()` の実行順、取得する file metadata、sort comparator、symlink 拒否条件は変えていない。Stage callback は各処理の後に時刻と path/folder 件数を記録する。上位 `Path total` は callback overhead を含むため、内訳の単純和とは一致しない。

| Fixture | Paths | Path total | Root checks | Folder existence | Directory listing | JSON filter | URL 再構築 | Symlink metadata | Path sort |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 4 | 0.50 / 0.51 | 0.06 / 0.07 | 0.10 / 0.10 | 0.14 / 0.14 | 0.01 / 0.01 | 0.07 / 0.07 | 0.02 / 0.02 | 0.06 / 0.06 |
| 1000 | 1003 | 139.74 / 142.31 | 0.05 / 0.05 | 0.06 / 0.06 | 1.90 / 1.97 | 0.87 / 0.87 | 14.01 / 14.04 | 1.72 / 1.76 | 121.07 / 123.57 |
| 5000 | 5003 | 617.01 / 654.77 | 0.05 / 0.06 | 0.07 / 0.08 | 11.01 / 11.28 | 4.37 / 4.53 | 73.06 / 77.79 | 8.56 / 9.16 | 519.43 / 551.83 |
| Mixed | 25 | 1.96 / 2.21 | 0.04 / 0.04 | 0.06 / 0.07 | 0.16 / 0.18 | 0.03 / 0.03 | 0.35 / 0.40 | 0.05 / 0.06 | 1.24 / 1.42 |

5000 Component fixture は10 folders を確認し、5003 Canonical JSON paths を sort した。この測定時の URL comparator では path sort が p50 **519.43 ms** と最も大きかった。Directory listing は **11.01 ms**、symlink metadata は **8.56 ms**。現行実装では同じ `URL.path` の文字列を各 URL から一度だけ取得して同じ順序で sort する。この表は変更前の比較条件として保持する。

### Path key precomputation の test-only candidate

Evidence commit `1943f46` では、同じ構築済み `[URL]` を入力とし、従来の `paths.sorted { $0.path < $1.path }` と各 URL の **同じ `.path` String を一度だけ抽出**してから sort する候補を交互に測定した。microbenchmark は filesystem I/O を含まず、各 fixture 20 run（warmup 済み）。Snapshot は同じ `WorktreeCoordinator` lock 内で両方式を交互に5 runずつ取得した。各セルは **p50 / p95 ms**、p95 は各条件の最大値で Product SLA ではない。`Candidate total` は key 抽出、keyed sort、URL mapping を含む。

| Fixture | Current URL comparator sort | Key 抽出 | Keyed sort | Candidate total | Current Snapshot | Candidate Snapshot |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 0.04 / 0.06 | 0.02 / 0.03 | 0.00 / 0.01 | 0.02 / 0.04 | 1.20 / 1.54 | 1.22 / 1.43 |
| 1000 | 123.61 / 126.31 | 3.02 / 3.17 | 2.46 / 2.63 | 5.64 / 5.97 | 269.06 / 273.96 | 152.67 / 179.19 |
| 5000 | 521.47 / 555.09 | 15.04 / 16.12 | 9.45 / 10.45 | 25.29 / 27.26 | 1225.57 / 1371.42 | 732.21 / 755.25 |
| Mixed | 1.17 / 1.30 | 0.07 / 0.08 | 0.03 / 0.03 | 0.11 / 0.12 | 4.45 / 4.81 | 3.36 / 3.54 |

5000 paths では、反復 `URL.path` 評価を避けると sort 自体は p50 **約496 ms**、Snapshot 全体は **約493 ms** 短くなった。これは test-only candidate の比較であり、production 採用や recovery Query 全体の性能保証ではない。Candidate は current と **URL sequence の各位置**および `.path` が一致し、CanonicalSnapshot identity と Document も1/1000/5000/mixed fixtureで一致した。`/var` と `/private/var` の alias は同じ identity/relative path sequence を返した。安全な ASCII ID の自然順・大小文字・記号・prefix の ordering edge cases、3種の Canonical JSON symlink、filename/ID mismatch は current と同じ結果だった。5000 fixtureで別 OS writer は candidate Snapshot 中に worktree lock を取得できず、Snapshot 完了後に取得した。Duplicate path key は test/debug assertion とし、production validation rule は追加していない。

この測定は sort の局所変更だけを比較し、Canonical bytes の二重読込、Git oracle、generation/freshness 判定を含む性能保証ではない。production sort の Phase 1 と writer wait は実際の recovery 経路で測定する。

## Production keyed path sort の再計測

Canonical path の並びは各 root-based `URL.path` を一度だけ取得し、従来と同じ Swift `String <` で sort する。探索、symlink 検査、bytes 読込、Snapshot identity、Git oracle、WorktreeCoordinator の境界は同じ。`testProductionCanonicalPathSortPreservesLegacyOrderAndSnapshot` と `testProductionCanonicalPathSortPreservesClientPreconditionAndMutation` は 1 / 1000 / 5000 / mixed fixture で URL sequence、Snapshot identity、Document、`ClientPrecondition.rawValue` の対応を検証する。`/var` alias、Agent profile、mutation、symlink、filename/ID mismatch、別 OS writer の lock 待機も回帰テストに含む。

`HAMII_CANONICAL_OBSERVATION_PROFILE_RESULT=<path> swift test --filter IndexQuerySessionTests/testMeasuredCanonicalObservationStages` を同じ arm64 macOS 27.0 / Swift 6.4 debug 環境で各 fixture 5回実行した。missing Index の `IndexRecoveryService.recoverOnce()` を計測し、fixture 作成は計測外。下表は **p50 / p95 ms**。p95 は5標本の最大値で Product SLA ではない。Snapshot は各内訳を包含し、Phase 1 は Snapshot と Git oracle を包含する。

| Fixture | Path sort | Path 列挙・symlink | Snapshot | Identity bytes 再読込 | Git oracle | Phase 1 | Total recovery |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 0.03 / 0.04 | 0.52 / 0.70 | 1.88 / 2.46 | 0.23 / 0.30 | 358.22 / 364.69 | 360.88 / 368.36 | 704.36 / 741.97 |
| 1000 | 5.75 / 6.08 | 24.69 / 26.84 | 164.68 / 171.01 | 29.22 / 31.11 | 339.78 / 349.47 | 505.36 / 514.82 | 875.44 / 885.87 |
| 5000 | 27.29 / 28.29 | 131.03 / 135.86 | 795.03 / 844.74 | 177.05 / 195.07 | 375.82 / 382.52 | 1170.86 / 1225.52 | 1626.88 / 1682.85 |
| Mixed | 0.20 / 0.24 | 1.52 / 1.76 | 7.32 / 7.77 | 1.29 / 1.38 | 357.77 / 371.68 | 366.32 / 379.25 | 729.54 / 747.86 |

同じ fixture の変更前測定と比べ、5000 Component の path sort p50 は **519.43 → 27.29 ms**、Snapshot は **1287.71 → 795.03 ms**、Phase 1 は **1650.05 → 1170.86 ms**。同一マシン上の別実行なので、差はこの環境・fixture に限る。`HAMII_CANONICAL_PATH_PROFILE_RESULT=<path> swift test --filter IndexQuerySessionTests/testMeasuredCanonicalPathBreakdown` では、5000 paths の path total p50/p95 **123.82 / 125.15 ms**、sort **25.76 / 26.01 ms**、root-based URL 再構築 **73.19 / 74.56 ms**、symlink metadata **8.90 / 9.29 ms** だった。

`HAMII_PRODUCTION_RECOVERY_BENCHMARK_RESULT=<path> swift test --filter IndexQuerySessionTests/testMeasuredProductionFullRecoveryCost` は missing / stale Bound の各条件を 1 / 1000 / 5000 Component で各3回測定した。fixture 作成時間は除外し、p95 は3標本の最大値。`Recovered Query` は Index を再度 missing / stale にしてから Query が recovery する end-to-end 時間である。

| Components | Condition | Recovered Query p50 / p95 ms | Max contiguous lock p50 / p95 ms |
| ---: | --- | ---: | ---: |
| 1 | missing | 692.67 / 702.93 | 359.47 / 371.25 |
| 1 | stale Bound | 713.60 / 717.22 | 358.52 / 362.32 |
| 1000 | missing | 876.73 / 886.43 | 496.97 / 516.29 |
| 1000 | stale Bound | 885.65 / 888.91 | 489.50 / 491.77 |
| 5000 | missing | 1620.40 / 1699.38 | 1219.25 / 1239.47 |
| 5000 | stale Bound | 1613.66 / 1658.56 | 1115.34 / 1122.11 |

`HAMII_CANONICAL_OBSERVATION_WRITER_TIMELINE_RESULT=<path> swift test --filter IndexQuerySessionTests/testMeasuredCanonicalObservationWriterTimeline` の5000 Component 単発試験では、Phase 1 lock 取得から writer attempt は **+69.16 ms**、Snapshot 完了 **+888.83 ms**、Git oracle を含む lock 解放付近 **+1271.02 ms**、writer lock 取得 **+1271.05 ms** だった。writer wait は **1201.90 ms**。変更前の単発 **1651.62 ms** と比較できるが、待機時間の分布や保証値ではない。

現条件で Snapshot p50 **795.03 ms** は Git oracle **375.82 ms** より大きい。Entity bytes 初回読込 **129.90 ms** と identity bytes 再読込 **177.05 ms** が残るため、次の focused experiment は同じ bytes を parse と identity に再利用する single-pass CanonicalSnapshot acquisition の安全性比較が候補となる。Index freshness、production incremental recovery、ADR の Decision はこの計測で確定しない。
