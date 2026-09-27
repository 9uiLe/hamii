# Production-shaped CanonicalGeneration shadow

## Related Decision

[Index consistency](../../ADR.md)。この Spike は、coordinated writer domain 内の shared CanonicalGeneration が安全な Query fast path の条件になり得るかを検証する。既存の [Shared Worktree Generation](../shared-worktree-generation/SPIKE.md) は独立した prototype Evidence として維持する。

## Hypothesis

**Tentative:** 同じ `.hamii/write.lock` を使う全 writer が Canonical shard に触る前に shared generation を Pending にし、recovery が old/new CanonicalSnapshot identity を照合して Stable を確立するなら、起動時の full verification 後は shared generation と Index source generation の照合を shadow freshness witness に利用できる。

## Questions

- 通常 save の journal 準備、Canonical commit、generation finalize の各停止点で false `KnownCurrent` を防げるか。
- 別 OS process の save、managed switch、validated merge publication、rebuild、restart で同じ generation semantics が成立するか。
- Candidate verdict と現行 Git freshness oracle は coordinated writer domain 内で一致するか。
- どの条件で `KnownCurrent`、`Stale`、`Unknown` とすべきか。外部 writer が protocol を迂回した場合の限界は何か。

## Prototype Scope

実 `CanonicalRepository` / `CanonicalTransaction` / `WorktreeCoordinator` / `LocalIndex` を用い、test-only shared generation record と test-only SQLite source generation metadata を重ねる。Production Query の返す結果は現行 `GitCanonicalRevisionCalculator` / `staleIndex` のままとし、candidate は shadow verdict のみ記録する。通常 save の transaction hook、別 OS process の SIGKILL、boot recovery と Query 比較を優先する。

## Out of Scope

Production Query の fast path 採用、production Index schema の source generation 追加、非協調 writer の安全保証、FSEvents による positive proof、power-loss durability、一般的な Index incremental recovery。

## Measurements

通常 save の pending 前後、Canonical shard apply、commit 後 / generation finalize 前後、別 process writer / reader、起動時 Unknown と old/new recovery、Index rebuild、shadow vs Git oracle の判定を記録する。Steady-state の lock、generation record、SQLite metadata、Git oracle の時間を分けて記録し、値は test-only 条件として示す。定量値は [timing.json](artifacts/timing.json) に条件とともに保存する。

## Success Criteria

検証した coordinated scenario で `shadow KnownCurrent` かつ oracle stale/unknown が 0 件。Journal と Snapshot の old/new identity によって停止後に既知状態だけへ収束し、pending / 欠損 / 破損 / future Index は current としない。別 process save が shared generation で観測できる。Restart は Unknown から開始し、full verification 後だけ witness を確立する。

## Failure Criteria

Canonical bytes が変わった後も shared generation が Stable old のまま current を許可する、別 process の save を見落とす、pending や破損 metadata を current にする、restart で equality だけを信頼する、または coordinated domain 内で shadow current と Git oracle が矛盾する。

## Result

**Confirmed in this test-only protocol:** 実 `CanonicalRepository`、journal、`.hamii/write.lock`、`ManagedGit`、`ValidatedMergePublisher`、`LocalIndex` に shadow generation record と SQLite shadow metadata を重ねた。Production Query は変更せず、`GitCanonicalRevisionCalculator` と `staleIndex` 拒否を oracle にした。

| Case | Shadow / recovery result | Production oracle |
| --- | --- | --- |
| 通常 save、別 process | 旧 witness は `Stale`、boot/rebuild 後は generation 2 で `KnownCurrent` | save 後 `staleIndex`、rebuild 後 current |
| 通常 save SIGKILL 5地点 | pending 前、pending 後 / ready journal 前、shard apply 中は旧 Snapshot / generation 1。Canonical commit 後 / generation finalize 前後は新 Snapshot / generation 2。起動時 witness なしはすべて `Unknown` | journal 回復後の旧・新 Index 判定と一致 |
| managed switch A→B→A | contents identity が A に戻っても generation は 1→2→3。旧 witness は復活しない | branch 変更後 `staleIndex`、rebuild 後 current |
| managed switch SIGKILL 3地点 | pending gate 中は boot 拒否。`ManagedGit.recover()` 後に旧または新 Snapshot と照合して再確立 | 回復・rebuild 後 current |
| validated merge SIGKILL 5地点 | CAS 前は旧状態、CAS 後は candidate に roll forward。pending gate 中は boot 拒否、回復後に新 generation と Index binding を確認 | 回復後 current |
| 同一 Snapshot の Index rebuild | CanonicalGeneration は不変、IndexGenerationID は更新。旧 witness は `Unknown` | 新 Index は current |
| 同一 text への semantic no-op mutation | Canonical write がなく generation、Snapshot identity、旧 witness は不変 | current |
| generation record / Index metadata 欠損・破損、future source generation、Index file 欠損 | `Unknown`、boot で安全な状態が確認できるまで witness 不発行 | Index generation metadata の破損は `staleIndex` |
| Pending 中に old / proposed のどちらとも異なる Snapshot | boot は `Unknown` のまま record を確定しない | 外部変更を `staleIndex` として拒否 |
| 新 reader process と2つの長寿命 reader process | restart は `Unknown` から開始。別 process save 後、両 reader の旧 witness は `Stale` | 両 reader とも `staleIndex` |

通常 save の実 process 停止試験は writer 停止 marker、別 reader の lock 取得試行 marker、生存中の取得可否、SIGKILL 後の取得、journal recovery、Index freshness を検証した。通常 save の `.prepared` hook は `transaction.prepare` の内容を disk に書いた後、`transaction.ready` 作成と Canonical shard 変更より前に Pending を記録する。停止地点はこの実際の順序を指す。`shadow KnownCurrent / oracle stale-or-unknown` は検証した coordinated case では **0 件**だった。

**Negative control / product guarantee 外:** raw file edit と raw `git switch` は shared generation を進めず、shadow は false `KnownCurrent` を返し、production oracle は `staleIndex` を返した。これは非協調 writer を許容できる証明ではない。External Git Write ADR の writer contract が Safe Fast Path の前提であり、FSEvents を current の positive proof として用いない。

**Measured:** `timing.json` は 2026-09-27、arm64 macOS、Swift 6.4、Starter copy と tracked 1000-component fixture の in-process xctest。Starter の shadow verdict p50/p95 は 1.092/1.394 ms、production oracle は 358.212/370.949 ms、boot verification は 724.844/733.401 ms。1000 components では shadow 1.136/1.326 ms、oracle 625.111/637.307 ms、boot 985.906/995.970 ms。40回の steady-state、20回の Git / Snapshot、5回の boot / rebuild から nearest-rank p50/p95 を計算した。shadow 値は **production の安全な Query 性能値ではない**。`fullRebuild` は事前取得した Snapshot からの revision 計算と Index build を含み、Snapshot acquisition を含まない。これらを Product SLA としない。

**Additional finding:** macOS の `/var` / `/private/var` alias で、`contentsOfDirectory` が返す resolved shard URL と repository root の文字列表現が異なり、Snapshot identity の相対パスに `/private` が混入していた。Canonical path を root URL から再構築し、同じ Project の別 spelling で identity が一致する回帰テストを追加した。この修正は Snapshot identity の path correctness であり、generation fast path の採用ではない。

**Unknown / not implemented:** Test-only hook と shadow SQLite metadata は production save / Query protocol ではない。全 writer operation の共通 durable generation transaction、power-loss durability、外部 writer の原子的 snapshot、安全な process bootstrap の実装、slow-path policy、production IndexGeneration の source generation 連結、Index incremental recovery は未実装・未決定。Agent profile のみの変更は Index 依存外でも Snapshot identity を変え得るため、安全側の過剰失効候補として残す。No-op test は同じ text への `ProjectService` mutation 1ケースであり、全 intent を網羅しない。

## Conclusion

Coordinated writer domain に限定すれば、shared generation + boot verification + Index source binding は検証した停止・再起動 case で production oracle と矛盾しなかった。Safe Fast Path の有力候補だが、この Spike は production protocol 完成証明でも採用判断でもない。Index consistency ADR は `Spike Required` のまま維持し、現行 `staleIndex` 拒否を維持する。

## Artifacts

- [timing.json](artifacts/timing.json): fixture、run 数、stage 別 p50/p95。再現 command: `HAMII_SHADOW_BENCHMARK_RESULT=adr/index-consistency/spikes/production-generation-shadow/artifacts/timing.json swift test --filter ProductionGenerationShadowSpikeTests.testMeasuredSteadyStateAndBootCost`。
- [ProductionGenerationShadowSpikeTests.swift](../../../../Tests/HamiiTests/ProductionGenerationShadowSpikeTests.swift): 実 process SIGKILL、recovery、shadow/oracle 比較、計測 code。
