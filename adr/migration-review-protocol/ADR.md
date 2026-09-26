# Migration の repository isolation / review workflow

## Context

Format migration は repository 全体を変更し、dirty tree や途中失敗で元の作業を失う可能性がある。

## Decision to Make

migration をどの作業領域・branch/commit/review 手順で実行するか。

## Constraints

Core は Current Format のみ。元 tree を review 前に無断変更しない。異なる format version を直接 semantic merge しない。

## Options

temporary worktree + branch、snapshot/commit choice、別の isolated staging。

## Current Hypothesis

**未確定:** isolated worktree + review commit が安全そうだが、具体 UX と recovery は未実証。

## Unknowns

dirty tree、LFS 欠落、途中 kill、worktree cleanup、review diff の分かりやすさ。

## Required Evidence

- [Migration worktree safety](spikes/worktree-safety/SPIKE.md)

## Decision Criteria

必要な Evidence から選択肢を比較し、採用理由と残る制約を記録する。判断と結果を先に commit し、必要な実装・検証と Current Architecture への反映を完了する。削除は [ADR workflow](../../docs/adr-workflow.md) の全条件を満たすまで行わない。

## Related Decisions

- [migration-core-boundary](../migration-core-boundary/ADR.md)
- [migration-ambiguity-resolution](../migration-ambiguity-resolution/ADR.md)

## Status

Spike Required
