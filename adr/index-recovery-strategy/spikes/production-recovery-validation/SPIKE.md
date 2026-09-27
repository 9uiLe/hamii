# Production full Index recovery validation

## Related Decision

[Local Index recovery strategy](../../ADR.md): verified coordinated Canonical state に限る automatic full rebuild baseline の production 適用。

## Hypothesis

Strict CanonicalSnapshot / Stable generation capture、read-only published Index classification、off-lock full candidate build、Phase 2 の source と expected published state 再検証により、stale rows や partial generation を返さずに同一 Query 呼び出し内で復旧できる。

## Questions

- Missing / obsolete / malformed / corrupt / stale Bound Index を安全に自動復旧できるか。
- External edit、generation missing / pending、Git flag / filter、storage failure を自動対象から除外できるか。
- 2 OS process の復旧が1件 publish / 1件 reuse に収束するか。
- Candidate build / publication 中の SIGKILL が旧または完全な新 Index に収束するか。
- Production の phase 別時間と writer lock wait はどの程度か。

## Prototype Scope

Production `IndexRecoveryService` と `IndexQuerySession` の Query 接続を実 Repository / SQLite / Git で実行する。1 / 1000 / 5000 Component fixture を測定する。

## Out of Scope

Incremental reindex、大規模実製品データ、任意の同一 worktree 非協調 writer への保証、停電耐久性、GUI Component Picker の SQLite 接続、Product SLA。

## Measurements

macOS 27.0、arm64、Swift 6.4 debug build。`swift test --filter IndexQuerySessionTests` を通常回帰に使用。性能試験は `HAMII_PRODUCTION_RECOVERY_BENCHMARK_RESULT=... swift test --filter IndexQuerySessionTests/testMeasuredProductionFullRecoveryCost` で各条件3回。p95 は3標本の最大値であり SLA 推定ではない。Writer lock wait は別 OS process の取得時間を記録する。

## Success Criteria

- 検証済み source の derived-only failure だけが自動復旧し、Query retry は1回以内。
- Candidate は同一 filesystem の別ファイルで完成・検証後に公開する。
- Concurrent recovery は同じ source の1世代へ収束し、途中 rows を返さない。
- Source が Phase 1 と Phase 2 の間に変われば candidate を破棄する。
- SIGKILL 後、公開状態は旧または完全な新 Index であり、次回 Query が安全に収束する。

## Failure Criteria

Stale rows、半更新 rows、不明な Canonical state からの自動復旧、storage failure を corrupt Index と誤分類、2 process による重複公開、失敗候補の公開。

## Result

Production 回帰では missing / obsolete / corrupt / incomplete schema / malformed metadata / stale Bound から完全な Bound generation へ復旧した。External edit、missing generation、pending state、Unbound source change、storage path failure、Git hidden flag / filter は fail closed のまま。2 OS process の競合では publish 1件、reuse 1件で同じ `IndexGenerationID` を観測した。Production service の `sourceCaptured`、`candidateCreated`、`candidateWriting`、`candidateBuilt`、`beforePublish`、`published` で SIGKILL し、restart 後に旧または完全な新 Index へ収束した。Candidate creation / SQLite transaction / before publication の failure injection では公開済み bytes を保持した。`IndexQuerySession` は復旧1回・Query retry1回の構造で、旧 witness を破棄してから再検証する。

Production timing は次のとおり。単位 ms、各条件3 run、各セル p50 / p95。p95 は3 run 中の最大値。`Phase 1` は lock 取得直後から Snapshot parse、Stable/Git/probe 判定まで、`off-lock` は immutable Snapshot からの SQLite build / probe、`Phase 2` は lock 取得直後から再検証・公開確認まで。`Recovered Query` は最初の失敗判定、自動復旧、再 Query を同じ呼び出しに含む。

| Components | Condition | Phase 1 lock | Off-lock build | Phase 2 lock | Recovery service total | Recovered Query |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | missing | 355.31 / 366.31 | 9.61 / 10.91 | 339.75 / 357.47 | 705.35 / 735.89 | 1082.56 / 1088.13 |
| 1 | stale Bound | 346.88 / 361.21 | 9.16 / 10.19 | 356.11 / 358.92 | 712.92 / 731.05 | 1050.54 / 1067.83 |
| 1000 | missing | 610.94 / 621.98 | 22.62 / 25.32 | 344.88 / 347.14 | 981.77 / 992.29 | 1872.54 / 1885.21 |
| 1000 | stale Bound | 613.23 / 628.07 | 23.12 / 24.07 | 349.35 / 353.44 | 985.33 / 999.68 | 1881.70 / 1911.01 |
| 5000 | missing | 1615.34 / 1683.95 | 69.22 / 69.90 | 388.37 / 389.93 | 2067.13 / 2143.44 | 5025.98 / 5051.98 |
| 5000 | stale Bound | 1614.46 / 1628.25 | 63.75 / 86.70 | 392.19 / 396.75 | 2075.49 / 2094.59 | 5003.17 / 5006.30 |

5000 Component の writer lock probe は Phase 1 の開始直後から **1640.62 ms** 待ち、1000 Component の candidate SQLite transaction 中に開始した probe は **0.109 ms** だった。ともに単一 OS process 試行で、後者は投影中の人工 barrier における lock availability の測定である。Phase 1 の Snapshot parse / Git 観測は依然として長い連続 lock を占め、off-lock SQLite build の最適化だけで end-to-end latency は解決しない。Recovery service total に初回失敗 Query と再 Query は含まず、Recovered Query は双方を含む。値は debug fixture / local machine 条件に限り Product SLA ではない。

## Conclusion

検証した coordinated writer domain と process crash の条件では、限定的な production automatic full rebuild は Decision の fail-closed 条件を満たす。Incremental recovery と power-loss durability は独立した ADR で扱う。性能値は今回の fixture と環境に限定する。

## Artifacts

- `artifacts/production-recovery-benchmark.json`: Production service の phase と Query 時間。
- `artifacts/production-writer-wait.json`: 別 OS process の writer lock wait。
- `artifacts/production-phase1-writer-wait.json`: Phase 1 lock に競合した別 OS process の writer wait。
