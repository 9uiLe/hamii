# Production-shaped Incremental Candidate Construction

## Related Decision

[Incremental Index Recovery の適用境界](../../ADR.md)。既存の targeted projector が、実 CanonicalSnapshot と実 LocalIndex schema から isolated candidate を作る際にも full rebuild より有利かを調べる。親 ADR は `Spike Required` のまま維持する。

## Hypothesis

Production の single-pass Snapshot で取得した exact per-file digests、published Index に結合された old source inventory / optional Screen usage summary、keyed dependency planner を使えば、full projection を作らず candidate SQLite を更新できる。ただし source inventory の検証、v8 SQLite のコピー、candidate の完全性確認まで含めると、局所変更でも full rebuild より高価な可能性がある。

## Questions

- Old published v8 SQLite を isolated file にコピーし、変更した projection rows だけ patch した結果は、同じ Snapshot / CanonicalRevision からの `LocalIndex.rebuild` と一致するか。
- Source inventory と U1 Screen usage summary の generation / source / digest integrity が崩れたときに fail closed にできるか。U2 は summary を必要としないか。
- コピー前後の別 Index publisher、patch transaction rollback、後続 Canonical save を、candidate の誤公開なしに扱えるか。
- Snapshot capture、per-file digest、Git revision、inventory validation、dependency closure、SQLite patch、candidate validation の費用を含むと、どの workload で full rebuild より候補価値があるか。

## Prototype Scope

- `AffectedProjectionDependencySpikeTests` の test-only helper を実 v8 `LocalIndex` file に接続する。Old file に experimental `source_inventory` / `source_screen_usage` tables と version / generation / source / count / digest metadata を追加するが、production schema は変更しない。
- Production の `CanonicalRepository.withStableSinglePassProbe(captureFileDigests: true)` で、単一回読んだ exact canonical bytes から Snapshot と file digests を得る。Current source files を changed-entity detection のために二重読みしない。
- Published old descriptor と revision を確認し、ordinary byte copy で isolated SQLite candidate を作り、コピー後も同じ descriptor を要求する。Old inventory を検証して changed entity を導き、既存の keyed planner / targeted evaluator で affected rows を計算する。
- Candidate SQLite 内の projection / inventory / summary / source binding metadata を単一 SQLite transaction で変更する。`PublishedIndexProbe` と exact inventory を再確認する。Full candidate は同じ Snapshot / CanonicalRevision を `LocalIndex.rebuild` に渡して別 file に作る。
- U1 は old per-Screen usage summary を利用し、U2 は current Screens rescan を利用する。14 transition の両方式と、8 workload の同一 run paired benchmark を実行する。

## Out of Scope

- Production schema、incremental recovery、candidate publication、Query 切替、atomic generation pointer、production source inventory の決定。
- Arbitrary external writer 下の atomic multi-file Snapshot 保証。試験は hamii coordinator の stable Snapshot を使用する。
- Candidate の publication CAS / client session / Preview / power-loss durability。別 publisher の介入を観測するが、candidate を production published path へ置換しない。
- Product SLA。Benchmark は local debug XCTest fixture であり、production end-to-end Query latency ではない。

## Measurements

Raw 5-run paired measurements は [paired-cost.json](artifacts/paired-cost.json)。Swift 6.4 / macOS / debug XCTest、local temporary Git worktree。Snapshot の baseline と exact digest 付き捕捉は各 run で順序を交互にし、candidate と full rebuild は同じ captured Snapshot / Git revision を使う。p50 / p95 は各 fixture の 5 観測だけに適用する。

Candidate total は old published file probe、明示的な 64 KiB 単位の byte copy、copied descriptor probe、inventory 全件の digest 検証、changed entity diff、keyed planner / targeted evaluator、SQLite patch transaction、candidate probe / inventory 再検証を含む。Full build は同じ captured Snapshot からの別 v8 SQLite file 構築と `LocalIndex.rebuild`。双方とも Snapshot capture、Git revision calculation、Index publication、Query を含まない。Candidate は experimental inventory / optional usage metadata を持ち、full file は現行 v8 schema のため、数値は採用候補の追加費用と現行 full baseline の比較である。Candidate 完了後の full oracle 比較時間は benchmark timing から除いた。

| Workload | U1 planned rows | U1 candidate p50 / p95 | Full p50 / p95 | U2 candidate p50 / p95 | U2 full p50 / p95 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1000 independent、1 Component name | 13 | 51.15 / 51.76 ms | 27.10 / 29.13 ms | 44.50 / 48.31 ms | 27.47 / 28.34 ms |
| 5000 independent、1 Component name | 13 | 208.67 / 214.01 ms | 121.21 / 121.95 ms | 200.75 / 207.59 ms | 121.38 / 121.98 ms |
| 5000 independent、10 Component names | 50 | 210.84 / 239.55 ms | 120.90 / 121.07 ms | 203.46 / 209.72 ms | 121.27 / 131.00 ms |
| 100 Components + 120 usage Screens、1 Screen | 1 | 17.02 / 17.63 ms | 9.63 / 10.21 ms | 14.66 / 15.03 ms | 7.97 / 8.06 ms |
| 100 Components + 120 usage Screens、2 Screens | 1 | 17.48 / 17.70 ms | 9.80 / 10.10 ms | 15.04 / 15.51 ms | 8.17 / 8.71 ms |
| 100 Component chain | 397 | 100.08 / 100.57 ms | 80.98 / 84.46 ms | 85.81 / 91.58 ms | 79.10 / 84.03 ms |
| 100 Component fanout | 397 | 20.90 / 22.16 ms | 8.95 / 9.24 ms | 14.76 / 14.83 ms | 7.29 / 7.38 ms |
| 100 Components、Scope parent | 207 | 15.89 / 16.06 ms | 7.57 / 7.71 ms | 10.82 / 11.28 ms | 6.05 / 6.15 ms |

Shared acquisition の例として、1000 / 5000 Component で Snapshot with digests p95 は 140.67 / 555.69 ms、baseline Snapshot p95 は 100.82 / 552.71 ms。Snapshot capture 内の per-file digest CPU p95 は 9.16 / 29.77 ms。Git revision calculation p95 は 323.19 / 554.27 ms。Snapshot baseline と digest 付き捕捉の差は別 acquisition の wall-clock 差であり、per-file digest の純粋な overhead と同一視しない。これらを candidate だけの費用として扱わない。5000 Component・1 変更 U1 の candidate stages p95 は published probe 21 ms、copied probe 19 ms、inventory read/integrity 47 ms、targeted compute 20 ms、SQLite patch 37 ms、candidate validation 16 ms。明示 byte copy p95 は約 3 ms。同じ fixture の experimental U1 metadata install p95 は 51.09 ms、old plain v8 file 1,921,024 bytes に対して inventory/summary 付き file は 2,678,784 bytes。これは per-generation storage / write overhead の pilot であり、production lifecycle 費用をすべて含まない。

## Success Criteria

- 追加・削除・Component / Scope / Screen / dependency 変更の U1/U2 candidate rows と重要 metadata、代表 Query hits が full candidate と一致する。
- Published old descriptor、copied descriptor、inventory / U1 summary の integrity が candidate 前に確認される。破損または source mismatch は部分適用しない。
- SQLite patch 失敗は rollback し、old published bytes は変わらない。別 publisher の file は候補に上書きされない。後続 Canonical state と candidate source binding の差を検出できる。
- Snapshot、revision、metadata install / read、candidate stages、full rebuild、file size を別々に測る。
- 費用の証拠が不利なら publication Spike へ進まず、production full rebuild baseline を維持する。

## Failure Criteria

- Candidate construction が full current `IndexProjection` または全 old projection value を入力に使う。
- Candidate が full rebuild と異なる projection / source metadata / representative Query hit を含む。
- Copy/replacement race、summary corruption、transaction failure を current candidate として通す。
- Local cost だけを production performance と主張する、または publication が未実装なのに atomic publication を証明したと主張する。

## Result

**Confirmed in tested cases:** 14 canonical transition（Component local / native-only / availability / owner / add / delete、Screen add / remove / delete / multiple / usage-heavy、chain、fanout、Scope parent）に対し U1/U2 の copied stale v8 candidate を構築した。全 projection rows、source / revision / generation binding metadata、3 Scope × 4 query strings の representative hits が、同じ captured Snapshot と Git revision からの full `LocalIndex.rebuild` と一致した。Current canonical files は source capture 中に各1回だけ読まれた。

**Confirmed in deterministic race tests:** Old descriptor observation 後に published file が別 generation へ置換されれば copied descriptor mismatch で candidate を拒否した。コピー中に source pathname が別 generation へ rename されても、開いていた old inode から完成した単一 generation をコピーでき、full oracle と一致した。SQLite patch 内で失敗すると transaction は rollback し、old published file bytes は変わらなかった。Candidate build 中に別 publisher が old pathname を置換しても candidate は published file を上書きしない。後続 Canonical save では candidate source Snapshot / generation が current と異なる。**これらは publication CAS の production 実装や任意タイミングの外部 writer 保証ではない。**

**Confirmed for metadata fallback:** Inventory digest corruption と U1 usage summary digest corruption は candidate を開始しない。U2 は破損した optional usage summary を使わず Screen rescan で full oracle と一致した。Old file の `PublishedIndexProbe` は experimental metadata を知らないため、inventory / summary の独立 integrity check が必要だった。

**Measured:** 8 workload × 5 paired runs のいずれでも candidate は full rebuild より遅かった。局所 5000 Component 変更でも U1 candidate p95 214.01 ms、full p95 121.95 ms。Inventory read/integrity、複数回の descriptor / candidate validation、SQLite row patch と metadata 更新が主な追加費用だった。U1 は usage row を1件しか計画しない Screen workload でも U2/full より高価だった。Full new projection を省くことだけでは、この pipeline の総費用を下げなかった。測定は warm in-process XCTest / local filesystem に限る。

## Conclusion

**Economic stop gate:** 今回の production-shaped copy-and-patch candidate は、正しさの tested cases を満たすが、測定した全 workload で full rebuild より遅く、source inventory の追加 write / storage 費用もある。この形の candidate をそのまま production publication Spike / implementation へ進める根拠はない。Current full rebuild / fail-closed Query baseline を維持する。Incremental recovery 全般を不可能と断定しないが、再検討するなら old-state integrity validation や candidate build の追加費用を含む別構成について、full rebuild に勝る具体的 workload と測定条件を先に示す。親 ADR は `Spike Required` のまま維持し、適用境界も production schema も決めない。

## Artifacts

- [Paired raw benchmark](artifacts/paired-cost.json)
- Executable correctness: `swift test --filter AffectedProjectionDependencySpikeTests/testProductionShapedCandidate`
- Opt-in benchmark: `HAMII_PRODUCTION_CANDIDATE_BENCHMARK_RESULT=<path> swift test --filter AffectedProjectionDependencySpikeTests/testMeasuredProductionShapedCandidateCost`
