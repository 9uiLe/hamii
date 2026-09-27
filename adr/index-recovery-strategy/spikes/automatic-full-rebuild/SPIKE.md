# Coordinated state からの Automatic Full Rebuild

## Related Decision

[Local Index の復旧方式](../../ADR.md)。Stale / missing Index を検出した Query が、どの条件で full rebuild と一回の retry を自動実行できるかを調べる。Recovery policy の採否はこの Spike だけでは決めない。

## Hypothesis

Valid な Stable CanonicalGeneration と coherent CanonicalSnapshot が同じ coordinated writer domain 内で得られる場合、Snapshot から別 SQLite candidate を build し、公開直前に source identity / generation / Git oracle を再確認すれば、誤った rows や partial generation を Query に見せずに自動 full rebuild できる。二段階 build は lock-held build より reader / writer 待ちを減らせる可能性がある。

## Questions

- Stale / missing のうち、どの状態なら hamii-managed Canonical state として自動復旧できるか。
- Lock を build 中ずっと保持する方式と、lock 下で Snapshot を取得し lock 外で build する方式では、correctness と待ち時間がどう異なるか。
- Build 中の writer、複数 recovery、停止、publication 失敗の後に、Index は旧 generation または検証済み新 generation に限られるか。
- Query は自動 rebuild を最大一回に制限し、失敗時に `staleIndex` へ戻れるか。
- Full rebuild の end-to-end cost と lock 占有時間は component / shard 数に応じてどう変わるか。

## Prototype Scope

Production `CanonicalRepository`、`WorktreeCoordinator`、`CanonicalGenerationStore`、`IndexProjection`、`LocalIndex`、`IndexQuerySession` を使う **test-only recovery coordinator** を作る。Production Query の stale rejection は変更しない。

候補 A は lock 下で Snapshot → source revision → candidate full build → validate → atomic publish → Query retry を行う。候補 B は lock 下で immutable Snapshot `S`、Stable generation `G`、Git oracle `R` を取得し、lock 外で別 SQLite candidate を build する。再取得した lock 下で `S/G/R` と公開済み Index descriptor を検査してから publish し、一回だけ Query を retry する。Source が変われば candidate を破棄する。両候補とも publication は別 file / generation を利用し、既存 SQLite rows を途中更新しない。

Initial eligible states は missing Index、obsolete disposable schema、valid Stable `G` より古い Bound Index、および source metadata は valid だが coordinated source が stale の Index とする。`ExplicitlyUnbound` current は recovery 不要。Pending managed Git / merge、Canonical journal conflict、破損 generation、Unknown Canonical state、unverifiable Git source、hidden Git flag / filter、外部 edit 後の unbound adoption は自動復旧しない。

## Out of Scope

Production auto recovery 実装、raw external edit の自動 adoption、非協調 writer の同一 worktree 保証、incremental reindex、background retry UX、停電時 fsync durability。Power-cut は [Canonical Power Loss ADR](../../../canonical-power-loss-durability/ADR.md) が扱う。

## Measurements

同じ fixture / machine / Swift build で、fresh query、stale detection、Snapshot acquisition、Git revision calculation、projection、SQLite build、publication、最初の Query、lock hold、reader / writer wait を分けて p50 / p95 を記録する。Small / medium / large の component と shard 数、recovery concurrent 数、失敗時の pending / index descriptor / rows を併記する。既存の one-shot CLI 値や test-only candidate の部分測定を Product SLA にしない。

## Success Criteria

- Candidate は取得元 `CanonicalSnapshot` と Stable `CanonicalGeneration` に `Bound(G)` で結合され、publication 直前に current と確認される。
- Writer が build 中に `G1/S1 → G2/S2` と変更した場合、`G1/S1` candidate を current として publish しない。
- 複数 recovery が同時に走っても、Query が partial rows または旧/new rows の混在を見ない。
- Build / validation / publication が失敗しても、Query は stale を返し、Canonical Data を rollback しない。
- Candidate build 中または publish 前の停止で temporary file が残っても current Index として見えない。Publish 付近の停止では old/new known generation に限り、曖昧な状態なら fail closed。
- 一回の自動 rebuild + 一回の Query retry を超えず、writer churn で無限再試行しない。
- Manual external-edit → explicit rebuild → `ExplicitlyUnbound` slow Query の既存 contract を保持する。

## Failure Criteria

古い source candidate の公開、partial rows の露出、`Unknown` を current とする positive verdict、非協調 writer を安全な対象へ含めること、Index failure のために Canonical state を巻き戻すこと、無制限 retry。

## Result

**Confirmed in test-only prototype:** `AutomaticFullRebuildSpikeTests` は production `CanonicalRepository` / `CanonicalGenerationStore` / `IndexProjection` / `LocalIndex` / `IndexQuerySession` を使用した。Missing Index に対し lock-held と二段階 candidate の双方が `Bound(G)` generation を公開し、初回 Query は slow verification、次回 Query は fast path を通った。二段階 build 中に hamii writer が Snapshot `S1/G1` から `S2/G2` へ save したケースは、旧 candidate publication を拒否し、Query も stale とした。別々に build した同一 source の2 candidate を順次公開したケースは、各 generation ID が異なり、長寿命 reader は置換後に slow verification へ戻った。Abandoned temporary candidate は published path へ現れなかった。外部 editor の直接変更と pending merge gate では、test-only auto candidate の取得と Query を拒否した。5件の focused test が成功した。これらは限定した逐次交錯であり、実 OS process crash / concurrent publication の証明ではない。

**Measured:** 2026-09-28、arm64 macOS 27.0、Apple Swift 6.4 debug、Local Git worktree fixture、Repository 外 SQLite。1 / 1000 / 5000 component shard、各方式5回を逐次測定した。表は `p50 / p95` ms、nearest-rank であり、5 samples の p95 は最大値に等しい。`lockHeld` は Snapshot / Git revision / build / rename を一つの lock 内で行う。`twoPhase` は lock 下で Snapshot / revision を捕捉し、lock 外で build、再取得した lock 下で再度 full Snapshot / Git oracle を検証して rename する。`twoPhase` の lock 合計は2回の占有時間の和で、待機と再試行は含まない。

| Components | Candidate | Snapshot + revision | Candidate build + source validation | Publish / reverify | Lock held sum | First cold Query |
|---:|---|---:|---:|---:|---:|---:|
| 1 | lockHeld | 347.06 / 376.70 | 364.78 / 375.37 | 0.38 / 0.44 | 715.81 / 743.41 | 363.85 / 367.32 |
| 1 | twoPhase | 353.29 / 377.98 | 358.74 / 366.99 | 698.12 / 743.64 | 1054.33 / 1104.86 | 355.37 / 371.04 |
| 1000 | lockHeld | 638.33 / 643.94 | 366.82 / 388.43 | 0.29 / 0.33 | 1001.94 / 1032.67 | 624.39 / 644.89 |
| 1000 | twoPhase | 635.91 / 643.48 | 362.43 / 376.15 | 974.48 / 997.82 | 1615.32 / 1633.73 | 628.72 / 640.80 |
| 5000 | lockHeld | 1728.24 / 1885.24 | 419.70 / 442.59 | 0.22 / 0.24 | 2171.07 / 2298.23 | 1764.04 / 1815.58 |
| 5000 | twoPhase | 1696.81 / 1713.67 | 434.63 / 442.16 | 2050.44 / 2117.09 | 3752.58 / 3797.65 | 1680.25 / 1743.47 |

`Candidate build + source validation` には SQLite projection / write に加えて `LocalIndex.assertCurrent` の Git oracle 照合が含まれるため、SQLite 単体の値ではない。この fixture では二段階方式の publish 時 full re-observation が lock 占有と end-to-end cost を増やした。測定は contention 下の reader / writer wait、retry、actual process crash、power cut を含まない。`first cold Query` は公開後に新しい process-local session が Git oracle をもう一度照合する費用である。CLI startup cost は含まない。Raw samples は [benchmark-20260928.json](artifacts/benchmark-20260928.json)。

## Conclusion

未決定。Coordinated Stable source から別 SQLite candidate を作り、source を再確認して公開する経路は tested sequential cases で成立した。現行 fixture では lock 外で build / validate する利点より publish 時の再観測 cost が大きく、二段階方式を性能上有利とは判断できない。Reader / writer contention、同時 recovery、bounded retry、SIGKILL 中断、schema obsolete / corrupted Index の分類、larger mixed workload の Evidence が残る。Production `staleIndex` 拒否と manual full rebuild を維持し、Index Recovery Strategy ADR は `Spike Required` とする。

## Artifacts

[Raw benchmark samples](artifacts/benchmark-20260928.json)。Prototype は `Tests/HamiiTests/AutomaticFullRebuildSpikeTests.swift` にあり、production auto recovery は未実装。
