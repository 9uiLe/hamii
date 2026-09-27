# Local Index の復旧方式

## Context

Git Repository の Canonical Data と一致しない Local SQLite は検索結果を返さない。Local Index は Repository 外の使い捨て Derived Data であり、Canonical Data から完全に再構築できる。現行の安全な baseline は stale detection → `staleIndex` → 手動 `hamii index rebuild` である。自動復旧と incremental reindex は UX / performance 改善であり、fail-closed rule を弱める理由にならない。

[Current Architecture](../../docs/final-architecture.md) の `IndexQuerySession` は Published Index が current であると証明する。この ADR は **stale / missing と判明した後の recovery** だけを決める。

## Decision to Make

Stale / missing Index を検出した後、どの Canonical / Index state に automatic full rebuild を許可し、どの状態では手動復旧または fail-closed error を維持するか。Candidate generation の publication と bounded retry も含める。Incremental reindex の適用条件は [独立した ADR](../incremental-index-recovery/ADR.md) が扱う。

## Constraints

- Canonical Data が正本。Index にしかない重要データを作らず、Index schema は compatibility chain ではなく再生成で更新できる。
- Recovery 中の partial rows を Query に見せない。新 generation が source CanonicalSnapshot と一致しないなら公開しない。
- Canonical state が rebuild 中に変化したら、旧 Index を current として返さず fail closed にする。
- Recovery eligibility は Canonical / coordination / Git source の検証後に判定する。SQLite の storage failure を corrupt Derived Index と誤分類しない。
- Writer contract は [External Git Write ADR](../git-external-write-coordination/ADR.md) に従う。Git / worktree mutation と Index recovery の race は同じ coordination boundary を考慮する。
- Canonical Format migration と disposable Local Index rebuild は別責務。Git ref / Canonical files / SQLite を単一 atomic transaction とみなさない。

## Options

1. 現行どおり、stale / missing を machine-readable error で返し、明示的な手動 full rebuild を求める。
2. Stale detection 後に自動 full rebuild し、validated Index generation を公開する。
3. Coordinated で検証可能な Canonical state と derived-only failure に限定して自動 full rebuild し、その他は明示的な手動 path または error とする。

Background rebuild、retry、manual repair UX は各 option の運用条件として比較する。

## Current Hypothesis

**Decision 前の tentative hypothesis:** Coordinated で検証可能な Canonical state と derived-only failure に限定した optimized two-phase automatic full rebuild を baseline とする。Source が変われば candidate を破棄し、復旧試行と Query retry は各1回に制限する。Canonical / Git / storage が不明または失敗なら fail closed / manual path を残す。以下の Decision はこの仮説を、検証した保証範囲内で採用した。

## Unknowns

Production eligibility classifier と error category、storage failure / candidate cleanup UX、同時 Git mutation 時の retry message、導入後の end-to-end recovery performance。250 ms の CLI Query 値は比較基準であり Product SLA ではない。Incremental projector と large-project crossover は [別 ADR](../incremental-index-recovery/ADR.md) に記録する。

## Required Evidence

- [Recovery Eligibility](spikes/recovery-eligibility/SPIKE.md): read-only SQLite classification、Canonical / Git / storage blocker、3地点の test-only failure injection、mixed semantic fixture を検証した。Focused 3 tests と全体 141 tests は失敗 0。Production classifier は未実装。
- [Automatic Full Rebuild](spikes/automatic-full-rebuild/SPIKE.md): coordinated Stable state に限定した test-only prototype。別 OS process の concurrent recovery は expected published Index check により1件 publish / 1件 reuse し、reader は stale または完全な新 rows だけを観測した。6地点の SIGKILL は old / new known generation に収束。Test-only bounded retry、read-only obsolete / corrupt SQLite 分類、1 / 1000 / 5000 component shard の lock-held / full-reobserve / optimized Phase 2 比較、単一 writer contention を記録した。この Spike 時点では Production recovery の採否は未決定だった。
- Git history の `672a5ea` に記録した End-to-end Index Generation / Low-cost Freshness は、当時の full pipeline stage timing、Starter copy の fresh CLI p95 418.612 ms、stale detection p95 424.174 ms、manual full rebuild p95 1316.333 ms と、double byte scan / size+mtime shortcut の反例を含む。これらは現在の自動復旧性能ではない。
- Git history の `41f92fe` は 1k/10k/50k Layer pilot、`b595bce` は branch switch と Git flags / filter の反例を含む。当時は Rebuild 中の同時変更への production recovery policy が未検証だった。
- [Validated Merge Publication](../validated-merge-publication/ADR.md): Published Canonical state から full LocalIndex rebuild し、gate を解放する前に freshness を検証する production safety baseline。一般 Query の自動 recovery policy は決めない。

Verify CI [36334624567](https://github.com/9uiLe/hamii/actions/runs/36334624567) は success。追加の大規模 benchmark、SIGKILL 地点、incremental production 実装、power-loss 検証は automatic full baseline の Decision blocker としない。既存 Index Spike の Evidence は消さず、この ADR から参照する。

## Decision Criteria

各 option の stale-result false negative、partial publication、concurrent Git / writer mutation、failure / retry、max contiguous coordination hold、writer wait、implementation complexity、user recovery experience を比較する。`cannot prove current → no rows` を守れる候補だけを採用する。Test-only 1 / 1000 / 5000 component の値は mechanism comparison に限り、Product SLA ではない。

## Decision

2026-09-28: **検証可能な coordinated Canonical state の derived-only Index failure には automatic full rebuild を recovery baseline とする。** 現行 production は実装完了まで `staleIndex` を返し、明示的 `hamii index rebuild` を利用する。

Auto eligibility は、Ready gate、Stable `CanonicalGeneration`、coherent `CanonicalSnapshot`、`generation.snapshotIdentity == snapshot.identity`、検証可能な Git oracle が揃うことを前提とする。そのうえで missing Index、obsolete disposable schema、malformed Index descriptor / metadata、corrupt SQLite、旧 `Bound(G)` source generation または検証済み Canonical state と異なる bound source identity だけを Derived Index failure として自動対象にする。Published SQLite は分類前に read-only で調べ、`LocalIndex.init` の destructive schema recreation を classifier に使わない。

候補 generation は Phase 1 の coordinated lock 下で `S/G/R/I0` を捕捉し、lock 外で immutable `S` から別 SQLite file に full `IndexProjection` を build / validate する。Phase 2 の lock 下で Ready、Stable `G/S` identity、Git `R`、expected published Index `I0` を再確認し、一致すれば atomic に publish する。別 recovery が同じ `S/G` の valid generation を先に公開した場合はその generation を再利用する。Source が変わった candidate は破棄し、復旧試行は最大1回、Query retry は最大1回とする。失敗や不明な状態で rows は返さない。

Production orchestration は独立した Index recovery service の責務とし、`IndexQuerySession` は stale 判定後に service を一度呼んで Query を一度再試行する境界に留める。Candidate cleanup と storage error の分類も service が扱う。

Canonical / generation / managed Git / merge publication の pending・missing・corrupt・unverifiable state、Git hidden flag / filter、非協調 external edit / raw branch switch、storage permission / create / write / rename failure は automatic recovery の対象外とする。`ExplicitlyUnbound` current Index は slow-only Query に使い、自動 rebuild や coordinated generation への adoption は行わない。Manual recovery は保証外・復旧不能状態の明示的な経路として残す。Index は Derived Data なので、その failure のために Canonical Data を rollback しない。

Incremental reindex の導入と適用 threshold は [Incremental Index Recovery ADR](../incremental-index-recovery/ADR.md) の独立 Decision とする。この Decision の保証は coordinated logical correctness と process crash までであり、power-cut durability は [Canonical Power Loss ADR](../canonical-power-loss-durability/ADR.md) に残す。

## Status

Implementation Required
