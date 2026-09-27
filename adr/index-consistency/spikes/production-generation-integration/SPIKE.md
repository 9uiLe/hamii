# Production CanonicalGeneration integration

## Related Decision

[Index consistency](../../ADR.md)。[Writer coverage](../production-writer-coverage/SPIKE.md) と [production-shaped shadow prototype](../production-generation-shadow/SPIKE.md) の後、共通 generation protocol を production writer に接続した状態の correctness と cost を測る。Index ADR の最終方式は決めない。

## Hypothesis

**Tentative:** 既存の `WorktreeCoordinator` lock と operation-specific pending gate の内側で persistent CanonicalGeneration を更新すれば、通常 save、managed switch、validated merge の停止・再起動で既知の old/new Snapshot だけに収束できる。Index に同じ source generation を記録できても、現段階では production Query の許可条件には使わない。

## Questions

- Canonical shard 書込前の Pending と journal 回復後の Snapshot identity を結び付けられるか。
- 別 OS process の save、switch、merge の SIGKILL 後に正しい generation と identity を回復できるか。
- No-op、asset metadata mutation、Index rebuild、A→B→A はそれぞれ正しい世代数になるか。
- Record 欠損・破損、Index metadata 欠損・破損を current と誤認しないか。
- Record read、Snapshot acquisition、Git revision calculation、現行 Query の cost はどう違うか。

## Prototype Scope

Production の `CanonicalGenerationStore` は `.hamii/canonical-generation.json` に Stable / Pending を保存し、自分では lock を取らない。`CanonicalRepository`、`ManagedGit`、`ValidatedMergePublisher` が既存 worktree lock の内側で呼ぶ。SQLite schema 7 は rows、`sourceCanonicalIdentity`、検証できる場合の `sourceCanonicalGeneration`、`indexGenerationID` を同じ transaction に保存する。Query の accept/reject は既存の Git-based `CanonicalRevision` と Snapshot / Index binding が引き続き決める。

## Out of Scope

Production Safe Fast Path の採用、automatic / incremental Index recovery、任意の非協調 writer の安全保証、FSEvents を用いた positive proof、APFS power-loss semantics、一般の worktree relocation protocol。

## Measurements

2026-09-27、arm64 macOS、Swift 6.4。Starter Sample copy と tracked 1000-component fixture をローカル一時 Git worktree で測定した。Steady read 40回、Snapshot / Git revision / Query 20回、verified binding check / rebuild 5回の nearest-rank p50/p95 を [timing.json](artifacts/timing.json) に保存した。`productionOracleQuery` は現行 Query、`coordinatedGenerationRead` は lock と record read のみ。`verifiedBindingCheck` は同一 process 内で Snapshot、Store、SQLite と Git oracle を確認する routine であり、process restart の end-to-end boot 値ではない。`fullRebuildFromPreacquiredSnapshot` は Snapshot 取得を含まず、Git revision 計算を含む。

## Success Criteria

検証した coordinated writer interleaving で、回復後の production generation identity が CanonicalSnapshot に一致し、旧／新の世代数が期待値どおりになる。Pending、欠損・破損 metadata、未知 Snapshot は current witness としない。Index build は CanonicalGeneration を進めず、同一 source の再 build で IndexGenerationID だけ変わる。Production Query は従来の fail-closed oracle を維持する。

## Failure Criteria

Canonical bytes が変わっても古い Stable generation が coordinated operation 内で残る、旧 Snapshot と異なる未知内容を自動確定する、Index rows と source generation の途中状態を公開する、または generation record だけで production Query を許可する。

## Result

**Confirmed in tested production integration:**

- `CanonicalRepository.create` は検証済み初回 Snapshot から世代1を作る。通常 save は shard 書込前に Pending と old / expected new identity を保存する。`transaction.prepare` で止まれば旧 Snapshot / 旧世代、Canonical commit 後で止まれば新 Snapshot / 次世代に復旧した。
- 実 OS process の writer / reader と SIGKILL を重ねた通常 save 5地点、managed switch 3地点、validated merge 5地点で、回復後の production generation value と Snapshot identity は期待する old / new に一致した。既存の merge publication regression は ref CAS、materialization、validation、Index build / publish、gate release の内部停止と idempotent recovery を通過した。SIGKILL は電源断耐久性の証明ではない。
- 別 process save を2つの長寿命 reader が観測し、production shared generation の変化、test-only shadow の stale、現行 Query oracle の stale が一致した。Production record と SQLite source metadata から作る test-only witness も、検証した coordinated save / switch / merge 停止点では oracle と矛盾しなかった。A→B→A は Snapshot contents identity が A に戻っても世代が2回進み、no-op mutation と同 branch switch は進まなかった。
- Asset metadata import 1回につき世代が1回進み、blob 保存後に別 client が mutation して import が conflict になった場合、asset metadata 由来の追加世代は進まなかった。未参照 blob は残り得る。
- 同一 Snapshot からの Index rebuild は CanonicalGeneration を進めず、IndexGenerationID を更新した。`sourceCanonicalGeneration` metadata の欠損・破損は現行 LocalIndex read を `staleIndex` にする。Index の行と binding metadata は同一 SQLite transaction に保存する。
- Record 欠損時は既存 generation を推測せず、coordinated full parse / validation の後に新 lineage で bootstrap した。破損 record は observation を拒否した。Production record / Index source metadata の欠損・破損・future source generation・Pending は test-only witness を current にしなかった。raw Git switch と raw file edit は generation protocol を迂回し、この witness は false current、現行 Query oracle は stale となる負例を維持した。`/var` / `/private/var` alias からは同じ record と Snapshot identity を観測した。

**Measured, not a Safe Fast Path value:**

| Fixture | Generation read p50 / p95 | Test-only shadow verdict p50 / p95 | Snapshot acquisition p50 / p95 | Git revision p50 / p95 | Production oracle Query p50 / p95 | Verified binding check p50 / p95 |
| --- | --- | --- | --- | --- | --- | --- |
| Starter copy | 0.239 / 0.257 ms | 1.024 / 1.421 ms | 2.275 / 2.447 ms | 347.211 / 371.196 ms | 355.220 / 370.960 ms | 348.879 / 358.645 ms |
| 1000 tracked components | 0.243 / 0.294 ms | 1.092 / 1.518 ms | 271.456 / 290.799 ms | 358.892 / 381.521 ms | 627.957 / 647.495 ms | 640.954 / 693.278 ms |

`fullRebuildFromPreacquiredSnapshot` は Starter p50/p95 368.995/383.367 ms、1000-component fixture 365.236/383.290 ms。ここでは Git revision 計算が値を支配する。`productionShadowVerdict` は実 production record / SQLite metadata を使う test-only candidate で、raw Git の負例では false current になる。これらの局所測定を Product SLA、production startup time、または安全な generation-only Query latency として扱わない。

外部 edit 後の手動 full rebuild は現行 Git oracle で実行でき、source generation は空にする。この Index から shared-generation witness は発行できない。

**Unknown / not implemented:** Process startup の positive witness 発行条件、外部 writer による observation gap、Missing / corrupt record の製品 UX、slow verification と recovery policy、shared generation の Query fast path 採否、incremental reindex、dependency invalidation、power-loss durability。Production `readStable` は record の状態を読むだけであり、Query 時に Canonical contents が current と証明されたことにはならない。現行 Query は oracle を維持する。

## Conclusion

Production writer 統合は、検証した coordinated transition の停止・再起動で Snapshot と generation を正しく結び付けた。SQLite に source generation を保持できるようになったが、record equality はまだ Query 許可の十分条件ではない。Index consistency ADR は `Spike Required`、production Query は `staleIndex` 拒否を維持する。

## Artifacts

- [timing.json](artifacts/timing.json): 測定値。再現 command: `HAMII_PRODUCTION_GENERATION_BENCHMARK_RESULT=adr/index-consistency/spikes/production-generation-integration/artifacts/timing.json swift test --filter ProductionGenerationShadowSpikeTests.testMeasuredProductionGenerationShadowCost`。
- [CanonicalGenerationIntegrationTests.swift](../../../../Tests/HamiiTests/CanonicalGenerationIntegrationTests.swift): 初回 create、save / journal recovery、record 欠損・破損、Index binding、asset conflict、path alias。
- [ProductionGenerationShadowSpikeTests.swift](../../../../Tests/HamiiTests/ProductionGenerationShadowSpikeTests.swift): 実 process SIGKILL と cross-process reader の production record assertion。
