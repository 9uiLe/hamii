# Production Index recovery performance

2026-09-28、Apple M1 Pro、arm64 macOS 27.0、Swift 6.4 debug XCTest。分割 JSON の一時 Git Repository と Repository 外 SQLite を使用した local mechanism measurement です。p95 は各条件5標本または3標本の最大値で、Product SLA ではありません。fixture 作成時間は各計測から除外します。

## 観測と復旧の境界

`IndexRecoveryService` の Phase 1 は `WorktreeCoordinator` の lock 内で journal / Ready gate、Stable CanonicalGeneration、coherent CanonicalSnapshot、Git freshness oracle、公開 Index の read-only 分類を確認します。Snapshot は root 基準の Canonical JSON path を列挙・symlink 検査し、各 file の exact bytes を一度だけ取得します。Document と Agent profile の decode / validation と Snapshot identity はその同じ bytes を使います。Phase 2 は別 SQLite file を off-lock で構築・検証した後、lock 内で source を再照合し atomic に公開します。Query は公開後に別の lock を取得し、Stable generation と Index descriptor を確認して rows を読みます。

不能または不確実な Canonical observation、Git hidden flag / clean filter、pending transition、stale Index では rows を返しません。`IndexQuerySession` の warm witness と CLI の one-shot cold Query は別条件です。Snapshot identity、CanonicalGeneration、ClientPrecondition、IndexGeneration は別概念です。

## CanonicalSnapshot と Phase 1

`HAMII_CANONICAL_OBSERVATION_PROFILE_RESULT=<path> swift test --filter IndexQuerySessionTests/testMeasuredCanonicalObservationStages` は、missing Index を `recoverOnce()` で再構築する4 fixtureを各5回測定します。表は **p50 / p95 ms**。Snapshot は path、bytes、decode、validation、hash を包含し、Phase 1 は Snapshot と Git oracle を包含するため列を合算しません。

| Fixture | JSON files / captured bytes | Path discovery | Bytes capture | Entity decode | Snapshot | Git oracle | Phase 1 | Recovery total |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 Component | 4 / 1,476 B | 0.43 / 0.54 | 0.16 / 0.21 | 0.10 / 0.12 | 0.94 / 1.19 | 342.76 / 352.77 | 344.73 / 355.03 | 715.13 / 741.45 |
| 1000 Components | 1003 / 693,459 B | 33.94 / 38.12 | 31.20 / 40.39 | 33.34 / 37.00 | 113.85 / 116.23 | 334.60 / 339.74 | 446.70 / 456.97 | 810.78 / 837.80 |
| 5000 Components | 5003 / 3,477,459 B | 138.11 / 141.07 | 154.90 / 202.67 | 173.21 / 179.55 | 516.87 / 550.42 | 376.13 / 386.42 | 898.26 / 927.76 | 1350.19 / 1368.54 |
| Mixed semantic content | 25 / 15,050 B | 1.99 / 2.03 | 1.60 / 1.62 | 1.53 / 1.64 | 6.08 / 6.26 | 352.15 / 378.78 | 355.88 / 386.24 | 720.05 / 763.93 |

5000 Component では Document / Asset validation が **35.19 / 37.27 ms**、identity hash が **13.99 / 15.01 ms** でした。Captured bytes は `Data` payload の合計であり peak RSS ではありません。Git oracle は Snapshot 外の別 stage です。`canonicalJSONPaths()` は root-based URL と keyed `String <` sort を使用し、symlink を拒否します。Entity array は folder 別 `lastPathComponent` 順です。

## Recovered Query

`HAMII_PRODUCTION_RECOVERY_BENCHMARK_RESULT=<path> swift test --filter IndexQuerySessionTests/testMeasuredProductionFullRecoveryCost` は missing / stale Bound Index の2条件を 1 / 1000 / 5000 Component で各3回測定します。`Recovered Query` は Query が復旧を開始し、full rebuild と再 Query を経て結果を返すまでの end-to-end 時間です。表は **p50 / p95 ms**。

| Components | Condition | Phase 1 lock | Off-lock build | Phase 2 lock | Recovery service total | Recovered Query |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | missing | 358.74 / 367.68 | 6.86 / 10.03 | 350.53 / 357.15 | 708.40 / 727.06 | 710.21 / 744.28 |
| 1 | stale Bound | 327.03 / 339.15 | 6.30 / 8.10 | 334.54 / 360.44 | 680.07 / 696.90 | 697.02 / 720.02 |
| 1000 | missing | 448.95 / 453.41 | 24.92 / 29.78 | 349.91 / 352.21 | 829.64 / 829.95 | 829.80 / 834.76 |
| 1000 | stale Bound | 435.39 / 447.88 | 18.52 / 21.88 | 344.08 / 366.16 | 796.94 / 837.22 | 804.01 / 811.92 |
| 5000 | missing | 935.25 / 958.11 | 68.22 / 68.50 | 379.75 / 390.08 | 1382.80 / 1397.95 | 1329.05 / 1346.35 |
| 5000 | stale Bound | 876.10 / 895.96 | 65.55 / 66.34 | 396.67 / 400.22 | 1338.33 / 1359.68 | 1335.76 / 1337.08 |

`Max contiguous lock` はこの測定では各条件の Phase 1 でした。5000 Component の missing / stale Bound p95 はそれぞれ **958.11 / 895.96 ms** です。別 OS process の writer が Phase 1 中に lock を試みた単発試験では、reader lock 取得から writer attempt **+69.37 ms**、Snapshot 完了 **+655.80 ms**、Phase 1 完了 **+1014.46 ms**、writer wait **945.01 ms** でした。単発値は writer latency の分布を示しません。

Index recovery は initial Query の検証済み観測を利用できる場合、同じ Snapshot から source を引き継ぎます。公開後の retry は新しい lock 下で generation と Index descriptor を再確認します。Candidate build 中または retry 前に source が変われば、古い rows を使いません。初回 Query、full rebuild、retry、CLI process 起動のそれぞれを分けて比較してください。増分再索引と大規模 Project の rebuild cost は [Incremental Index Recovery ADR](../adr/incremental-index-recovery/ADR.md) が扱います。
