# Canonical multi-file save transaction

## Context

分割 canonical files の途中停止は entity 間参照を壊し得る。

## Decision to Make

一つの document revision として multi-file save を commit/recover する protocol を決める。

## Constraints

Git files が正本で SQLite は派生。途中書込を complete revision と扱わない。

## Options

temporary staging + manifest revision + journal、page atomic replace、別の recovery protocol。

## Current Hypothesis

**未確定:** staging と manifest revision を使える可能性があるが、fsync/recovery は未実証。

## Unknowns

kill timing、filesystem durability、外部編集との衝突、recovery の再実行性。

## Required Evidence

- [Crash recovery transaction](spikes/crash-recovery/SPIKE.md)

## Decision Criteria

必要な Evidence から選択肢を比較し、採用理由と残る制約を記録する。判断と結果を先に commit し、必要な実装・検証と Current Architecture への反映を完了する。削除は [ADR workflow](../../docs/adr-workflow.md) の全条件を満たすまで行わない。

## Related Decisions

- [git-canonical-sharding](../git-canonical-sharding/ADR.md)
- [index-consistency](../index-consistency/ADR.md)

## Status

Spike Required
