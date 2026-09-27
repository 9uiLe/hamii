# Published Index の鮮度証明

## Context

Git Repository の分割 JSON が共有 Canonical Data であり、Repository 外の Local SQLite は再構築可能な Query Index である。Published Index が現在の Canonical state に対応していると証明できないとき、production Query は `staleIndex` で検索結果を拒否する。この fail-closed rule は確定している。

現在の Query は coordinated CanonicalSnapshot と Git-based `CanonicalRevision` guard を毎回照合する。Starter copy の CLI fresh query p95 418.612 ms、stale detection p95 424.174 ms は比較条件付きの Evidence であり Product SLA ではない。Startup witness の test-only warm verdict は Starter p95 1.903 ms、1000 tracked components p95 1.664 ms だが、production Query の性能ではない。現行 CLI は command ごとに新 process を起動するため、process-local witness を採用しても one-shot CLI query は毎回 cold slow verification を要する。

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

**未確定:** Option 2 が coordinated writer domain 内の long-lived process では有力。Startup は `Unknown`、slow verification は Canonical recovery / Ready gate / coherent Snapshot / Stable generation / Index descriptor / Git oracle を一つの lock 内で照合する。Witness は worktree・Document・Index namespace に scope した process-local value とする。Warm Query は同じ lock で generation と descriptor を比較し、rows を読み終えてから unlock する。Generation 変更は `Stale`、同じ Canonical state の Index rebuild は `Unknown` として再検証する。

**Confirmed within tested conditions:** Process-local generation 単独は外部編集・実 branch switch・別 Repository instance save を見落とす。Raw external writer は shared generation を迂回する。P4 の production-object startup witness と P5 の別 OS process save / Index rebuild race では、検証した coordinated interleaving に false current や verdict→row-read TOCTOU は生じなかった。これらは production fast Query の完成証明ではない。

## Unknowns

P5 Verify の結果、production `IndexQuerySession` の設計と lifecycle、同一 worktree / Document / Index namespace への witness scope、published DB の atomic rename 後に古い SQLite connection を再利用しない方法、reader-reader / reader-writer contention、実 production Query の cold / warm cost。CanonicalRevision の具体的計算 algorithm を architecture requirement として固定しない。非協調 writer の許可境界は External Git Write ADR、power-cut durability は [Canonical Power Loss ADR](../canonical-power-loss-durability/ADR.md) が所有する。

## Required Evidence

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

P4 GitHub Actions Verify と P5 Verify が成功し、startup positive witness、coordinated writer / Index rebuild の失効、fast verdict から SQLite row read 完了までの同一 lock、missing / corrupt / pending での拒否が Evidence で成立したら判断する。Decision commit は Spike Evidence commit と分ける。Production 実装では stale SQLite handle、multiple worktrees / Documents、cold / warm performance を regression / benchmark として検証し、完了まで ADR を削除しない。

## Status

Spike Required
