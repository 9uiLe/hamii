# Generated Asset の採用境界

## Context

生成された候補画像と Project に正式採用された asset は永続性が違う。元の Asset policy ではこの区別が未決。

## Decision to Make

Generated Asset をいつ Repository Asset に昇格し、provenance と content hash をどう保存するか。

## Constraints

未採用の生成 cache を Git 正本にしない。採用済み実体は再現可能な参照と integrity を持つ。

## Options

明示採用で repository object 化、生成物を常に repository 化、外部参照を維持。

## Current Hypothesis

**未確定:** 明示採用を要求する可能性が高いが未決定。

## Unknowns

生成 source/provenance の最低限の記録、再生成の可否、ライセンスと容量。

## Required Evidence

必要な調査と利用事例を記録する。現時点で Technical Spike の要否も未確定。

## Decision Criteria

必要な Evidence から選択肢を比較し、採用理由と残る制約を記録する。判断と結果を先に commit し、必要な実装・検証と Current Architecture への反映を完了する。削除は [ADR workflow](../../docs/adr-workflow.md) の全条件を満たすまで行わない。

## Related Decisions

- [asset-storage-policy](../asset-storage-policy/ADR.md)
- [remote-asset-cache](../remote-asset-cache/ADR.md)

## Status

Open
