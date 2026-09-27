# Incremental Index Recovery の適用境界

## Context

一般 Query の復旧 baseline は、検証済みの coordinated CanonicalSnapshot から Index generation 全体を再構築し、完成した generation だけを公開する方式として [Index Recovery Strategy ADR](../index-recovery-strategy/ADR.md) で判断する。Local SQLite は Canonical Data から再生成可能な Derived Data であり、stale rows は返さない。Full rebuild の correctness contract を維持しながら、大規模 Project / 小さな変更集合で再投影コストを削減できるかは独立した最適化 Decision である。

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

- [Incremental Reindex](spikes/incremental-reindex/SPIKE.md): 実 `IndexProjection` の5変更で affected row set と full oracle が一致し、試作 SQLite generation の tested commit / rollback barrier は partial rows を見せなかった。Production targeted projector は未検証。
- [Large Project Rebuild](spikes/large-project-rebuild/SPIKE.md): tracked / mostly-untracked shard の pilot。実 workload 分布、dependency density、memory、incremental crossover は未測定。
- Production に近い Snapshot → changed entity → reverse closure → targeted projection → generation publish → Query を、削除・追加・scope parent change と失敗時 rollback を含めて測る。

## Decision Criteria

Full rebuild oracle と rows / availability / closure が一致し、stale result 0、partial publication 0、source change で fail closed を満たすことを前提に、end-to-end p50 / p95、peak memory、extra storage、実装複雑度を比較する。局所変更で一貫した便益がないなら full rebuild を維持する。

## Status

Spike Required
