# Incremental Index Recovery の適用境界

## Context

一般 Query の復旧 baseline は、検証済みの coordinated CanonicalSnapshot から Index generation 全体を再構築し、完成した generation だけを公開する方式である。[Current Architecture](../../docs/final-architecture.md) がその保証を説明する。Local SQLite は Canonical Data から再生成可能な Derived Data であり、stale rows は返さない。Full rebuild の correctness contract を維持しながら、大規模 Project / 小さな変更集合で再投影コストを削減できるかは独立した最適化 Decision である。

## Decision to Make

Full rebuild と同じ source Snapshot binding、fail-closed Query、atomic publication、bounded retry を維持したまま、どの Canonical change set と Project scale に incremental reindex を適用するか。

## Constraints

- Changed file の再読込だけでは依存 row の invalidation を保証できない。Changed entity、reverse dependencies、affected derived rows を追跡する。
- Source Snapshot と published Index generation の identity を明示し、build 中に Canonical state が変わった candidate を公開しない。
- Partial rows を Query に見せない。失敗または不明な依存関係では full rebuild / stale rejection に戻れること。
- Full rebuild の recovery policy と writer guarantee は再決定しない。

## Options

1. 全変更を full rebuild し、incremental path を導入しない。
2. 安全に閉包を計算できる entity / projection だけ targeted reindex し、残りは full rebuild する。
3. 全 projection に汎用 incremental dependency graph と generation publisher を導入する。

## Current Hypothesis

**未確定:** 現在の `IndexProjection` で変更影響が明確な一部 row に限定して option 2 を検証する。Production projector が全 new projection を構築してから一部 row を置換するだけでは、実用的な incremental cost 削減を証明しない。Full rebuild が安全で十分速い workload では導入しない可能性がある。

## Unknowns

Production changed-entity detection、reverse dependency store、deletion / scope subtree / slot content の閉包、将来の Token / Asset projection、source Snapshot の ownership、generation staging の storage cost、full / incremental crossover、shard 数と dependency 密度に対する end-to-end latency と peak memory。

## Required Evidence

- [Changed-entity source capture](spikes/changed-entity-source-capture/SPIKE.md): test-only Index-bound inventory from exact single-pass Snapshot bytes matched a ten-case added/modified/deleted byte oracle, including two saves, process restart, and stable-ID rename. Corrupt/unbound/unknown source fell back to full rebuild; full-projection row diffs expose historical dependency evidence needed by the next Spike. Five-run source-capture timings are fixture-local and do not prove production incremental recovery.
- [Affected Projection Dependency Capture](spikes/affected-projection-dependency-capture/SPIKE.md): current valid Document graph + exact changed Component IDs, per-Screen old usage contribution, and existing old scope-closure rows formed a complete affected-key superset in 27 hand-built transitions and 384 acyclic graph pairs. Current-only and old/new union Component closure were equal in those pairs; old direct-edge metadata has not been shown necessary for v1 correctness. Test-only SQLite summary generation binding, restart, corruption fallback, and five-run local cost were measured. Targeted projection, marginal metadata cost, and end-to-end incremental benefit remain unresolved.
- [Incremental Reindex](spikes/incremental-reindex/SPIKE.md): 実 `IndexProjection` の5変更で affected row set と full oracle が一致し、試作 SQLite generation の tested commit / rollback barrier は partial rows を見せなかった。Production targeted projector は未検証。
- [Large Project Rebuild](spikes/large-project-rebuild/SPIKE.md): tracked / mostly-untracked shard の pilot。実 workload 分布、dependency density、memory、incremental crossover は未測定。
- [Production full recovery performance](../../docs/index-recovery-performance.md): 1 / 1000 / 5000 Component、各3 run の full recovery を測定。5000 Component の recovered Query p95 は missing 5051.98 ms / stale Bound 5006.30 ms、Phase 1 lock p95 は最大 1683.95 ms。Off-lock build p95 は最大 86.70 ms。この fixture と環境に限定し、incremental path の便益や Product SLA はまだ示さない。
- [Canonical observation stage / path breakdown](../../docs/index-recovery-performance.md): 5000 Component、各5 run の profile では Canonical path 列挙・symlink 確認 p50 617.01 ms のうち path sort p50 519.43 ms、URL 再構築 73.06 ms、directory listing 11.01 ms、symlink metadata 8.56 ms。Current source acquisition cost が projection/build より大きい条件の Evidence であり、incremental recovery の適用条件はまだ決めない。
- [Path key precomputation candidate](../../docs/index-recovery-performance.md): test-only の paired 20 run では 5000 paths の sort p50 が従来 521.47 ms / keyed candidate 25.29 ms、5 run の Snapshot p50 が 1225.57 ms / 732.21 ms。URL sequence と Snapshot identity は tested fixtures で一致した。この段階の測定に production Query 全体の費用は含まれない。
- [Production keyed path sort](../../docs/index-recovery-performance.md): exact `URL.path` key を各 URL から1度抽出する局所変更を採用。5000 Component の production recovery stage profile 5 run では sort p50 27.29 ms、Snapshot 795.03 ms、Phase 1 1170.86 ms。Recovered Query 3 run の p50 は missing 1620.40 ms / stale Bound 1613.66 ms。索引一貫性と incremental recovery 方式の Decision はこの性能改善から導かない。
- Production に近い Snapshot → changed entity → reverse closure → targeted projection → generation publish → Query を、削除・追加・scope parent change と失敗時 rollback を含めて測る。

## Decision Criteria

Full rebuild oracle と rows / availability / closure が一致し、stale result 0、partial publication 0、source change で fail closed を満たすことを前提に、end-to-end p50 / p95、peak memory、extra storage、実装複雑度を比較する。局所変更で一貫した便益がないなら full rebuild を維持する。

## Status

Spike Required
