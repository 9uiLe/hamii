# Incremental Index Recovery の適用境界

## Context

一般 Query の復旧は、検証済みの coordinated CanonicalSnapshot から Index generation 全体を構築し、完成した generation だけを公開する。Local SQLite は Canonical Data から再生成可能な Derived Data であり、stale rows を返さない。Incremental reindex はこの安全契約を維持した上で復旧費用を下げる場合に限って製品へ導入する。

## Decision to Make

現行 v1 `IndexProjection` と Repository 外の standalone SQLite generation に対し、どの Canonical change set / Project scale で incremental recovery を製品に適用するか。

## Constraints

- CanonicalSnapshot identity、source generation、IndexGenerationID の結合と、Query の fail-closed 判定を保つ。
- Changed entity だけでなく reverse dependency closure と affected derived rows を扱う。Partial rows を公開しない。
- Candidate 構築中の Canonical transition、別 publisher、破損した追加 metadata を current と誤認しない。
- Full rebuild recovery policy と coordinated writer guarantee はこの判断で再決定しない。

## Options

1. 全変更を full rebuild し、production incremental path を導入しない。
2. 安全に閉包を計算できる entity / projection だけ targeted reindex し、残りは full rebuild する。
3. 全 projection に汎用 incremental dependency graph と generation publisher を導入する。

## Current Hypothesis

Decision 前の暫定評価は、現行 v1 / standalone SQLite architecture では option 1 が製品費用と単純性の両面で適切、というものだった。Source capture、affected closure、targeted replacement は tested cases で成立したが、実 Index file を使った isolated copy-and-patch candidate に full rebuild を上回る性能便益は確認できなかった。採用結果は下記 Decision に記録する。

## Unknowns

実 Project の長期的な変更分布、現行 fixture を超える shard 数 / dependency density、将来の Token / Asset projection、異なる storage / generation 再利用方式の費用は未測定である。これらは現行 production path の選択を保留する理由ではなく、下記 re-open criteria が成立した場合の新しい判断材料である。

## Required Evidence

- [Changed-entity source capture](spikes/changed-entity-source-capture/SPIKE.md): production single-pass Snapshot の exact captured bytes から test-only per-file inventory を作り、追加・変更・削除、2 save、restart、stable-ID rename の tested cases で changed entity を識別した。未知 source や破損 inventory は fail closed。
- [Affected Projection Dependency Capture](spikes/affected-projection-dependency-capture/SPIKE.md): current valid Document、changed Component IDs、old per-Screen usage、old scope closure から、27 hand-built transitions と 384 acyclic graph pairs の affected-key complete superset を得た。
- [Targeted Projection Recompute](spikes/targeted-projection-recompute/SPIKE.md): U1/U2 の planned replacement rows は tested v1 cases で full `IndexProjection` と一致した。Targeted 部分だけの局所的な速さは、Source detection / candidate materialization を含む回復性能を証明しない。
- [Production-shaped Incremental Candidate Construction](spikes/production-shaped-incremental-candidate/SPIKE.md): 14 transitions × U1/U2 で copied v8 SQLite candidate の全 rows / source metadata / representative hits が同一 Snapshot の full rebuild と一致した。Copy/publisher/source races、rollback、inventory / summary corruption の tested cases でも fail closed。8 workload × 5 paired runs の全てで U1/U2 copy-and-patch candidate が full rebuild より遅く、5000 independent Components / 1 change の p95 は U1 214.01 ms、full 121.95 ms。Test-only inventory / summary に追加 write / storage 費用があった。Candidate publication は実装していない。
- [Incremental Reindex](spikes/incremental-reindex/SPIKE.md): 実 `IndexProjection` の5変更で affected rows が full oracle と一致し、試作 SQLite generation の tested commit / rollback barrier は partial rows を見せなかった。
- [Large Project Rebuild](spikes/large-project-rebuild/SPIKE.md): tracked / mostly-untracked shard の pilot。今回の製品判断に用いる実 workload 分布や将来の crossover を保証しない。
- [Current production recovery measurement](../../docs/index-recovery-performance.md): Apple M1 Pro / macOS 27.0 / Swift 6.4 debug、5000 Component、各3 run の p95 は recovered Query が missing 1346.35 ms / stale Bound 1337.08 ms、Phase 1 lock が 958.11 / 895.96 ms、off-lock full candidate build が 68.50 / 66.34 ms。Full candidate build はこの条件で recovery の支配的 stage ではない。異なる benchmark run の値を厳密な割合として足し引きしない。Product SLA ではない。

## Decision Criteria

Full rebuild と同じ source binding、stale result 0、partial publication 0、failure 時の fail closed を満たすことを前提に、同じ Snapshot からの candidate 構築 p50 / p95、persistent metadata write / storage、recovery / publication 複雑度を比較する。局所変更でも一貫した製品上の便益がなければ full rebuild を維持する。

## Decision

**Option 1 を採用する。** 現行 v1 `IndexProjection` と standalone disposable SQLite generation の自動復旧には、検証済み CanonicalSnapshot からの full rebuild を維持する。Production source inventory、historical per-Screen usage summary、targeted projection patch、incremental generation publication を導入しない。

Option 2 は tested v1 cases で技術的に成立したが、production-shaped copy-and-patch candidate は sparse 1/5000 change を含む全測定条件で full rebuild より遅かった。Persistent metadata、schema、corruption fallback、追加 recovery branch、publication protocol の費用を正当化する便益がない。U1 は Screen の targeted recompute を減らしたが、その durable metadata / read / write を含む candidate 全体では優位にならなかった。Option 3 はさらに広い dependency graph と generation architecture を要する一方、現時点で option 1 を上回る製品価値の Evidence がない。

これは incremental indexing 一般の不可能性や、将来の別 storage architecture の性能を断定しない。Production full candidate build が実 recovery の支配的 stage になった、実 Project の sparse-change 分布で production-shaped candidate の安定した優位が測定された、新 projection / dependency semantics が full rebuild cost を大きく増やした、独立した storage 変更で generation reuse が安くなった、または Snapshot / Git / recovery の主要費用を改善しても製品 latency 目標に届かない場合に、新しい Evidence で再検討する。固定 ms threshold は設けない。

## Status

Ready for Decision

判断は記録済み。既存 production full rebuild が決定を実装している。Decision commit の検証と Git history への保存を経て、この作業 queue から削除する。
