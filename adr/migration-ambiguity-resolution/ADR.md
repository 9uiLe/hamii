# Ambiguous / lossy Migration の解決

## Context

旧値から新 Token などへの一意な対応がない場合、勝手な変換は意味を壊す。

## Decision to Make

ambiguous/lossy/manual migration をいつ止め、候補・影響・Human resolution をどう表すか。

## Constraints

旧値を勝手に推測しない。Unsupported legacy component を隠さない。元 commit は保持する。

## Options

Requires Resolution report + editor、blocking migration、ユーザー指定 mapping file。

## Current Hypothesis

**未確定:** Requires Resolution と Human review を使う可能性があるが UX は未検証。

## Unknowns

候補生成の範囲、選択の記録、unsupported component、partial resolution の再開。

## Required Evidence

- [Ambiguous value review](spikes/ambiguous-value-review/SPIKE.md)

## Decision Criteria

必要な Evidence から選択肢を比較し、採用理由と残る制約を記録する。判断と結果を先に commit し、必要な実装・検証と Current Architecture への反映を完了する。削除は [ADR workflow](../../docs/adr-workflow.md) の全条件を満たすまで行わない。

## Related Decisions

- [migration-core-boundary](../migration-core-boundary/ADR.md)
- [migration-review-protocol](../migration-review-protocol/ADR.md)

## Status

Spike Required
