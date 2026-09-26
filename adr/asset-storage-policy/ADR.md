# Repository Asset の Git / LFS 保存規則

## Context

Repository binary の保存先は clone size と共同作業者の object availability に影響する。

## Decision to Make

Repository Asset を通常 Git と LFS に振り分ける policy と欠落時の preflight を決める。

## Constraints

Logical Asset ID と content hash を分離する。正本 binary は integrity check できる。

## Options

size threshold、type-specific threshold、project policy。

## Current Hypothesis

**未確定:** 小さい asset は通常 Git、大きい asset は LFS とする可能性がある。閾値は未確定。

## Unknowns

閾値、clone/pull cost、LFS 未導入・object 欠落時の UX。

## Required Evidence

- [Git / LFS threshold and availability](spikes/git-lfs-threshold/SPIKE.md)

## Decision Criteria

必要な Evidence から選択肢を比較し、採用理由と残る制約を記録する。判断と結果を先に commit し、必要な実装・検証と Current Architecture への反映を完了する。削除は [ADR workflow](../../docs/adr-workflow.md) の全条件を満たすまで行わない。

## Related Decisions

- [remote-asset-cache](../remote-asset-cache/ADR.md)
- [generated-asset-adoption](../generated-asset-adoption/ADR.md)

## Status

Spike Required
