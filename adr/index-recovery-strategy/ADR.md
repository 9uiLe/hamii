# Local Index の復旧方式

## Context

Git Repository の Canonical Data と一致しない Local SQLite は検索結果を返さない。Local Index は Repository 外の使い捨て Derived Data であり、Canonical Data から完全に再構築できる。現行の安全な baseline は stale detection → `staleIndex` → 手動 `hamii index rebuild` である。自動復旧と incremental reindex は UX / performance 改善であり、fail-closed rule を弱める理由にならない。

[Index Consistency ADR](../index-consistency/ADR.md) は Published Index が current であると証明する条件を決める。この ADR は **stale / missing と判明した後の recovery** だけを決める。

## Decision to Make

Stale / missing Index を検出した後、手動 full rebuild、自動 full rebuild、incremental reindex のどの recovery policy を採るか。Failure / retry UX、changed entity と reverse dependency の invalidation、Index generation の atomic publication、大規模 Project の cost を含める。

## Constraints

- Canonical Data が正本。Index にしかない重要データを作らず、Index schema は compatibility chain ではなく再生成で更新できる。
- Recovery 中の partial rows を Query に見せない。新 generation が source CanonicalSnapshot と一致しないなら公開しない。
- Canonical state が rebuild 中に変化したら、旧 Index を current として返さず fail closed にする。
- Changed file だけの再索引では不足しうる。Changed entity → direct projection → reverse dependencies → affected derived rows → validated generation を検証する。
- Writer contract は [External Git Write ADR](../git-external-write-coordination/ADR.md) に従う。Git / worktree mutation と Index recovery の race は同じ coordination boundary を考慮する。
- Canonical Format migration と disposable Local Index rebuild は別責務。Git ref / Canonical files / SQLite を単一 atomic transaction とみなさない。

## Options

1. 現行どおり、stale / missing を machine-readable error で返し、明示的な手動 full rebuild を求める。
2. Stale detection 後に自動 full rebuild し、validated Index generation を公開する。
3. Changed entity / reverse dependency を計算する incremental reindex と atomic generation publication を行い、必要に応じ full rebuild へ戻す。

Background rebuild、retry、branch ごとの namespace、manual repair UX は各 option の運用条件として比較する。

## Current Hypothesis

**未確定:** 最初の production recovery は明示的な full rebuild の安全な baseline を維持する。自動 full rebuild または incremental reindex は、同一 CanonicalSnapshot から生成した Index generation の validation と atomic publication、同時 Git / writer mutation 下の失敗処理、Project size ごとの end-to-end cost が揃った場合にのみ採用する。P1〜P5 の freshness Evidence は recovery policy の採用証明ではない。

## Unknowns

自動 full rebuild の開始条件と待機 UX、手動復旧の message / command UX、changed entity detection、reverse dependency を含む targeted projection、failure / retry policy、同時 Git mutation 時の generation 破棄・再試行、large-project rebuild cost、shard 数が非常に多いときの scaling、incremental と full の切替条件。250 ms の CLI Query 値は比較基準であり Product SLA ではない。

## Required Evidence

- [Incremental Reindex](../index-consistency/spikes/incremental-reindex/SPIKE.md): 実 `IndexProjection` の tested changed/affected rows は full projection と一致し、試作 SQLite generation の tested commit / rollback barrier は partial rows を見せなかった。Production incremental recovery の証明ではない。
- [End-to-end Index Generation](../index-consistency/spikes/end-to-end-index-generation/SPIKE.md): full pipeline の stage timing。Coherent source acquisition と production incremental generation を接続した end-to-end cost は未測定。
- [Large Project Rebuild](../index-consistency/spikes/large-project-rebuild/SPIKE.md) と [Index Drift and Scale](../index-consistency/spikes/index-drift/SPIKE.md): tracked / mostly-untracked shard の pilot、1k/10k/50k scale。一般的な巨大 Project の rebuild cost は未確定。
- [Low-cost Freshness](../index-consistency/spikes/low-cost-freshness/SPIKE.md): Starter copy で fresh CLI p95 418.612 ms、stale detection p95 424.174 ms、manual full rebuild p95 1316.333 ms。Double byte scan と size/mtime shortcut に false negative がある。
- [Concurrent Git Mutation](../index-consistency/spikes/concurrent-git-mutation/SPIKE.md): branch switch と Git flags / filter の反例。Rebuild 中の同時変更への production recovery policy は未検証。
- [Validated Merge Publication](../validated-merge-publication/ADR.md): Published Canonical state から full LocalIndex rebuild し、gate を解放する前に freshness を検証する production safety baseline。一般 Query の自動 recovery policy は決めない。

必要な追加 Spike は、自動 full rebuild の end-to-end UX / correctness、production incremental dependency invalidation と generation publish、large-project cost に絞る。既存 Index Spike の Evidence は消さず、この ADR から参照する。

## Decision Criteria

各 option の stale-result false negative、partial publication、concurrent Git / writer mutation、failure / retry、fresh / stale Query latency、full / incremental rebuild latency、large-project scaling、implementation complexity、user recovery experience を比較する。`cannot prove current → no rows` を守れる候補だけを採用する。結果を Evidence / Decision commit に記録し、実装・検証完了まで ADR を維持する。

## Status

Spike Required
