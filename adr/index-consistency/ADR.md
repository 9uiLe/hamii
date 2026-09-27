# Published Index の鮮度証明

## Context

Git Repository の分割 JSON が共有 Canonical Data であり、Repository 外の Local SQLite は再構築可能な Query Index である。Published Index が現在の Canonical state に対応していると証明できないとき、production Query は `staleIndex` で検索結果を拒否する。この fail-closed rule は確定している。

Safe Fast Path 実装前の Query は coordinated CanonicalSnapshot と Git-based `CanonicalRevision` guard を毎回照合した。Starter copy の CLI fresh query p95 418.612 ms、stale detection p95 424.174 ms は比較条件付きの Evidence であり Product SLA ではない。Startup witness の test-only warm verdict は Starter p95 1.903 ms、1000 tracked components p95 1.664 ms であった。Production `IndexQuerySession` は初回に slow verification を行い、同一 process の後続 Query にだけ witness を使う。CLI は command ごとに新 process を起動するため、one-shot CLI query は毎回 cold slow verification を要する。

Writer guarantee は [External Git Write ADR](../git-external-write-coordination/ADR.md) が定める。1 worktree の正式な hamii GUI / CLI / managed Git writer は同じ coordination protocol に参加する。Raw Git、外部 editor / script / AI による同一 worktree の直接変更は正式な safe collaboration path ではない。Index は writer の許可範囲を決めない。

## Decision to Make

Published Index が現在の Canonical state に対応していることを、どの Evidence と coordinated read boundary で証明するか。Startup `Unknown`、slow positive verification、process-local witness、shared CanonicalGeneration、IndexGeneration binding、steady-state fast verdict、および verdict から SQLite row read 完了までの境界を一つの Decision として扱う。

Stale / missing Index を手動 full rebuild、自動 full rebuild、incremental reindex のどれで復旧するかは [Index Recovery Strategy ADR](../index-recovery-strategy/ADR.md) の独立した Decision である。

## Constraints

- `CanonicalSnapshot → CanonicalRevision` の依存方向を保つ。Revision calculation だけで複数 Canonical file の coherent snapshot を作ったことにしない。
- `CanonicalSnapshotIdentity`、`CanonicalGeneration`、`IndexGenerationID`、`ClientPrecondition` は別概念として扱う。Document manifest `revision` や Git commit OID を Canonical state identity の十分条件にしない。
- Safe Fast Path は **coordinated writer-domain guarantee の内側だけ**で有効。非協調 writer に対する absolute filesystem freshness proof として扱わない。
- Process restart は `Unknown` から始める。Positive witness を disk に永続化しない。
- Fast verdict と、その verdict に基づいて返す実 SQLite rows の read は同じ `WorktreeCoordinator` boundary に入れる。
- Pending、missing / corrupt generation、missing / corrupt Index binding、unverifiable slow oracle は `KnownCurrent` にしない。判断できなければ rows を返さない。
- Atomic Index publication と Canonical freshness は別保証。古い SQLite handle を新しい published generation と誤認しない。
- FSEvents 等は受信時の witness invalidation hint にできても、無通知を current の positive proof にしない。

## Options

1. 現行の Query ごとの coordinated Snapshot / Git oracle verification を続ける。
2. Startup の一つの coordinated slow verification で process-local witness を発行し、同じ lock 内で shared generation / published Index descriptor と照合して rows を読む。`Unknown` は slow verification、`Stale` は拒否する。
3. Git status、file metadata、複数回の digest 等を fast positive proof にする。既存反例があるため、そのまま採用できない。

## Current Hypothesis

**Decision 前の仮説は採用済み。** Option 2 の coordinated writer domain 内の Safe Fast Path を採用する。具体的な contract は次の Decision に記録する。Production 実装で `IndexQuerySession` 相当の process-local owner を設けることは実装仮説であり、型名を仕様として固定しない。

**Confirmed within tested conditions:** Process-local generation 単独は外部編集・実 branch switch・別 Repository instance save を見落とす。Raw external writer は shared generation を迂回する。P4 の production-object startup witness と P5 の別 OS process save / Index rebuild race では、検証した coordinated interleaving に false current や verdict→row-read TOCTOU は生じなかった。これらは production fast Query の完成証明ではない。

## Decision

**Safe Fast Path は coordinated writer-domain guarantee の内側だけで有効とする。** これは raw Git、外部 editor / script / AI による非協調書込に対する鮮度証明ではない。外部変更 signal は witness を `Unknown` へ失効させることはできるが、signal が無いことを current の証拠にしない。

各 process / Query session は `Unknown` から始まる。Positive witness は disk に保存しない。Process restart 後に旧 witness を再利用しない。Witness は worktree、Document、published Index namespace に scope し、CanonicalGeneration、CanonicalSnapshotIdentity、IndexGenerationID を別 field として保持する。TTL は correctness mechanism としない。

`Unknown` から Query の current を証明する経路は、一つの `WorktreeCoordinator` lock 内での slow verification とする。Canonical transaction recovery、Ready gate、coherent CanonicalSnapshot、published Index descriptor の source identity / generation ID、および現行 Git freshness oracle を照合する。Source generation binding は **`Bound(G)` / `ExplicitlyUnbound` / `Invalid`** の3状態として扱う。`Bound(G)` で `G` が Snapshot と一致する Stable CanonicalGeneration に等しいときだけ、rows を返して process-local witness を発行する。`ExplicitlyUnbound` は exact Snapshot / Git source に結び付いた有効な Index として、slow verification 成功時に **その Query の rows だけ**返し、witness は発行しない。次の Query も slow verification を行う。Slow verification 失敗または `Invalid` なら rows を返さない。

`ExplicitlyUnbound` は、外部編集後の明示的 `hamii index rebuild` 等により、検証できる Snapshot から作られたが coordinated CanonicalGeneration へ正当に binding できない Index を表す。これは key 欠損・空文字列・unknown marker・malformed `Bound` value ではない。Local Index metadata では意図的 unbound を必須の明示 marker で表し、欠損・破損と区別する。Index schema は disposable なので旧 schema は再生成する。`index rebuild` を外部 Canonical state の generation adoption operation へ暗黙に変えない。

Warm Query は同じ worktree lock 内で Ready gate、Stable CanonicalGeneration、現在公開された `Bound(G)` Index descriptor を witness と照合する。Generation、Snapshot identity、IndexGenerationID、Index source generation / identity、Document / namespace がすべて一致した場合のみ `KnownCurrent` とし、**その lock を保持したまま同じ公開 SQLite generation の rows を読み終える**。Verdict と row read の間に unlock しない。Atomic rename 前に開いた長寿命 SQLite connection を新しい公開世代として再利用しない。`ExplicitlyUnbound` は fast verdict の候補にしない。

CanonicalGeneration が変わり、旧 `Bound(G)` Index の source generation が current と一致しなければ `Stale → staleIndex`。CanonicalGeneration が同じでも IndexGenerationID が変われば `Unknown → slow verification` とする。Slow verification が新 Index を `BoundCurrent` として確認した場合だけ新 witness を発行する。Pending、missing / corrupt generation、missing / corrupt / mismatched Index descriptor、future source generation、unverifiable Git oracle は `KnownCurrent` にしない。意図的 unbound 以外の source binding metadata 欠損・破損は rows を返さない。Missing generation の verified bootstrap だけでは旧 Index を current にしない。Corrupt generation を推測で repair しない。

Stale / missing Index を自動で再構築するか、manual full rebuild を求めるか、incremental reindex を行うかは [Index Recovery Strategy ADR](../index-recovery-strategy/ADR.md) が決める。Power-cut durability は [Canonical Power Loss ADR](../canonical-power-loss-durability/ADR.md) が決める。Current one-shot CLI は毎回 `Unknown` から slow path を通るため、この Decision は CLI の単発 Query latency を改善するという主張ではない。

## Unknowns

残る内容は implementation validation と CI acceptance である。Production Query session、witness scope、atomic rename 後の stale SQLite handle 回帰、実 Query の cold / warm cost、複数 project/session の隔離、close / reopen、reader-reader / reader-writer contention を検証した。現 Editor はまだ Index-backed Component 一覧を持たず、`IndexQuerySession` を consumer として使わない。Editor の将来の Index-backed search は project-open lifetime に session を保持する。CanonicalRevision の具体的計算 algorithm を architecture requirement として固定しない。非協調 writer の許可境界は External Git Write ADR、power-cut durability は Canonical Power Loss ADR が所有する。

## Required Evidence

- [Production Query session performance](../../docs/index-query-performance.md): 同一 process の Bound warm Query は 1/1000/5000 Components で p95 2.038 / 2.766 / 5.371 ms、cold slow は p95 385.189 / 643.113 / 1682.507 ms。Starter の one-shot CLI p95 は 378.192 ms。条件の異なる値を混同しない。Production regression は stale SQLite handle、別 OS process save/rebuild race、metadata rejection、Unbound slow-only を検査する。
- [Production contention and lifecycle](../../docs/index-query-performance.md): 別 OS process の 1/2/4 reader Query と lock wait、writer が reader の後ろで待つ交錯と reader が writer の後ろで待つ交錯、人工 5 ms hold を伴う継続 reader 負荷下の writer 待ちを測った。有限の測定では starvation を観測しなかった。Project close/reopen は新 session の cold verification を要求し、2つの project の witness は交差しない。
- [Explicitly Unbound Index の Slow Query](spikes/explicit-unbound-query/SPIKE.md): 既存 CLI contract は外部編集後の stale → 明示的 rebuild → Git-oracle slow Query を許可する。Bound generation を slow Query に一律要求した未コミット候補はこの contract を壊した。意図的 unbound と metadata 欠損・破損の区別が必要。
- [Fast Query Read Boundary](spikes/fast-query-read-boundary/SPIKE.md): test-only candidate は実 SQLite `ComponentHit` rows と production oracle の全 field を照合した。別 OS process の save / rebuild は verdict 後の row read 完了まで lock を取得できず、旧 witness はその後に失効した。Missing / corrupt / mismatched metadata は rows を返さない。Production Query は変更していない。
- [Startup Current Witness](spikes/startup-current-witness/SPIKE.md): 一つの coordinated slow observation で Snapshot / Stable generation / Index descriptor / Git oracle を検証した後だけ process-local witness を発行した。Restart、Index rebuild、別 OS process writer、metadata failure と test-only warm cost を確認した。
- [Production CanonicalGeneration Integration](spikes/production-generation-integration/SPIKE.md) と [Production Writer Coverage](spikes/production-writer-coverage/SPIKE.md): 正式 writer の Stable / Pending record、SIGKILL recovery、source binding、entry point coverage。
- [Production Generation Shadow](spikes/production-generation-shadow/SPIKE.md): 通常 save、managed switch、validated merge、A→B→A、長寿命 reader、raw writer negative control の test-only verdict と production oracle を比較した。
- [Shared Worktree Generation](spikes/shared-worktree-generation/SPIKE.md)、[Known-current Generation](spikes/known-current-generation-fast-path/SPIKE.md): process 間の coordinated generation と process-local marker 単独の反例。
- [Consistent CanonicalSnapshot](spikes/consistent-canonical-snapshot/SPIKE.md)、[Low-cost Freshness](spikes/low-cost-freshness/SPIKE.md)、[Safe Freshness Fast Path](spikes/safe-freshness-fast-path/SPIKE.md): lock 下の観測境界、digest 安定化と size/mtime shortcut の false negative。
- [Production Index Source Binding](spikes/production-source-binding/SPIKE.md): rows・source identity・IndexGenerationID を同一 SQLite transaction に保存し、一般 Query が metadata 不整合を拒否する。
- [Concurrent Git Mutation](spikes/concurrent-git-mutation/SPIKE.md) と [Git Working Tree Fingerprint](spikes/git-working-tree-fingerprint/SPIKE.md): branch switch、hidden Git flags、clean filter の反例と現行 guard。

Recovery の Evidence は [Index Recovery Strategy ADR](../index-recovery-strategy/ADR.md) からも参照する。既存 Spike の実験結果を freshness Decision に必要な範囲を超えて一般化しない。

## Decision Criteria

P4 Verify `36323844003` と P5 Verify `36325567176` は成功した。Startup positive witness、coordinated writer / Index rebuild の失効、fast verdict から SQLite row read 完了までの同一 lock、missing / corrupt / pending での拒否は、P4 Evidence `8bd8381` と P5 Evidence `067934e` の tested conditions で成立した。明示的 rebuild 後の unbound slow Query contract と一律 Bound 要求の regression は Evidence `b402e35` に記録した。Production `IndexQuerySession` は stale SQLite handle、Bound / ExplicitlyUnbound / Invalid、複数 worktree、cold / warm cost、close / reopen、reader contention を regression / benchmark で検証した。最終 `scripts/check.sh` と Verify、Current Docs の整合を確認してから ADR 削除を判断する。

## Status

Implementation Required
