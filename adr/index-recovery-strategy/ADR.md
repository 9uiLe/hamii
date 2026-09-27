# Local Index の復旧方式

## Context

Git Repository の Canonical Data と一致しない Local SQLite は検索結果を返さない。Local Index は Repository 外の使い捨て Derived Data であり、Canonical Data から完全に再構築できる。現行の安全な baseline は stale detection → `staleIndex` → 手動 `hamii index rebuild` である。自動復旧と incremental reindex は UX / performance 改善であり、fail-closed rule を弱める理由にならない。

[Current Architecture](../../docs/final-architecture.md) の `IndexQuerySession` は Published Index が current であると証明する。この ADR は **stale / missing と判明した後の recovery** だけを決める。

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

- [Automatic Full Rebuild](spikes/automatic-full-rebuild/SPIKE.md): coordinated Stable state に限定した test-only prototype。Missing Index、build 中の coordinated writer、2 candidate の順次 publication、放置された candidate、external edit / pending gate の拒否を確認した。1 / 1000 / 5000 component shard の各5回測定では、二段階方式の publish 時 full re-observation が lock 占有を増やした。Concurrent recovery、SIGKILL、bounded retry と failure UX は未検証であり、採否は未決定。
- [Incremental Reindex](spikes/incremental-reindex/SPIKE.md): 実 `IndexProjection` の tested changed/affected rows は full projection と一致し、試作 SQLite generation の tested commit / rollback barrier は partial rows を見せなかった。Production incremental recovery の証明ではない。
- [Large Project Rebuild](spikes/large-project-rebuild/SPIKE.md): tracked / mostly-untracked shard の pilot。一般的な巨大 Project の rebuild cost と incremental crossover は未確定。
- Git history の `672a5ea` に記録した End-to-end Index Generation / Low-cost Freshness は、当時の full pipeline stage timing、Starter copy の fresh CLI p95 418.612 ms、stale detection p95 424.174 ms、manual full rebuild p95 1316.333 ms と、double byte scan / size+mtime shortcut の反例を含む。これらは現在の自動復旧性能ではない。
- Git history の `41f92fe` は 1k/10k/50k Layer pilot、`b595bce` は branch switch と Git flags / filter の反例を含む。Rebuild 中の同時変更への production recovery policy は未検証。
- [Validated Merge Publication](../validated-merge-publication/ADR.md): Published Canonical state から full LocalIndex rebuild し、gate を解放する前に freshness を検証する production safety baseline。一般 Query の自動 recovery policy は決めない。

必要な追加 Spike は、自動 full rebuild の end-to-end UX / correctness、production incremental dependency invalidation と generation publish、large-project cost に絞る。既存 Index Spike の Evidence は消さず、この ADR から参照する。

## Decision Criteria

各 option の stale-result false negative、partial publication、concurrent Git / writer mutation、failure / retry、fresh / stale Query latency、full / incremental rebuild latency、large-project scaling、implementation complexity、user recovery experience を比較する。`cannot prove current → no rows` を守れる候補だけを採用する。結果を Evidence / Decision commit に記録し、実装・検証完了まで ADR を維持する。

## Status

Spike Required
