# Canonical file の分割粒度

## Context

file 分割は Git diff、merge conflict、large Page の保存と load に影響する。

## Decision to Make

Layer/entity/page のどの単位を canonical file の shard とするか。

## Constraints

Stable ID と deterministic serialization を使い、path/name 変更で大量 rename を起こさない。

## Options

entity-per-file、subtree shard、page shard。

## Current Hypothesis

**未確定:** entity 単位は conflict を減らせる可能性があるが file 数と IO が増える。

## Unknowns

50k Layer の open/save、merge conflict 件数、file count、partial load。

## Required Evidence

- [Shard and merge benchmark](spikes/shard-merge-benchmark/SPIKE.md)

## Decision Criteria

必要な Evidence から選択肢を比較し、採用理由と残る制約を記録する。判断と結果を先に commit し、必要な実装・検証と Current Architecture への反映を完了する。削除は [ADR workflow](../../docs/adr-workflow.md) の全条件を満たすまで行わない。

## Related Decisions


## Status

Spike Required
