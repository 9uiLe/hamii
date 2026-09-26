# Canonical multi-file process-crash recovery

## Context

分割 canonical files の途中停止は entity 間参照を壊し得る。

## Decision to Make

プロセス停止で中断された multi-file save を、次の hamii 操作時に complete revision へ復旧する protocol を決める。

## Constraints

Git files が正本で SQLite は派生。途中書込を complete revision と扱わない。

## Options

temporary staging + manifest revision + journal、page atomic replace、別の recovery protocol。

## Current Hypothesis

**決定済み:** changed shard の旧新 bytes と plan を project-local journal に同期・準備し、ready journal への rename 後に shard、最後に manifest revision を更新する。次回 open は journal と manifest により旧版へ rollback または新版へ roll forward し、旧新 bytes 以外の外部変更では fail closed とする。

## Unknowns

この decision boundary には残論点なし。停電後の durability は [Power-loss ADR](../canonical-power-loss-durability/ADR.md)、hamii 外の Git 書込との調整は [External Git Write ADR](../git-external-write-coordination/ADR.md) で独立に扱う。

## Required Evidence

- [Crash recovery transaction](spikes/crash-recovery/SPIKE.md): 8 停止位置 × 5 回の復旧と、異なる bytes の外部編集時の fail-closed を確認。

## Decision Criteria

`hamii` による保存の全変更点で process stop しても、次回 open が完全な旧/新版を返し、外部 bytes を上書きしないこと。判断と結果を先に commit し、実装・検証と Current Architecture への反映を完了する。削除は [ADR workflow](../../docs/adr-workflow.md) の全条件を満たすまで行わない。

## Decision

上記 staged journal protocol を採用する。manifest を commit marker とし、manifest より前の停止は旧版、以後の停止は新版へ復旧する。`.hamii/` 内の journal は派生作業状態であり Git に保存しない。通常の load/save は pending journal を先に処理する。停電保証と外部 Git 書込の原子性をこの判断に含めない。

## Related Decisions

- [git-canonical-sharding](../git-canonical-sharding/ADR.md)
- [index-consistency](../index-consistency/ADR.md)
- [canonical-power-loss-durability](../canonical-power-loss-durability/ADR.md)
- [git-external-write-coordination](../git-external-write-coordination/ADR.md)

## Status

Implementation Required
