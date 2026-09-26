# SwiftUI Host reconciliation and state identity

## Context

IR の値変更と構造変更は SwiftUI の identity と state に異なる影響を与える。通常編集の compile 不要という約束と state 保持範囲を具体化する必要がある。

## Decision to Make

値 patch、子移動、node kind 変更、Screen root 変更の各操作で、どの subtree を再構築し、どの state を保持できるか。

## Constraints

supported edit は暗黙 compile を起動しない。保持できない focus/scroll/@State は明示診断する。

## Options

stable ID + recursive renderer、local snapshot partition、root replacement。`AnyView` の使用範囲も比較する。

## Current Hypothesis

**未確定:** stable ID と小さな observable snapshot により、値更新は state を保ちながら compile なしに反映でき、構造更新の state reset は明示できる可能性がある。

## Unknowns

子の移動・kind 変更・root 差し替え時の @State/focus/scroll/navigation identity、型消去の性能、局所更新範囲。

## Required Evidence

- [Value patch without compilation](spikes/value-patch/SPIKE.md) — supported property 更新の成立。
- [Structure reconciliation and state identity](spikes/state-reconciliation/SPIKE.md) — 構造更新と state reset の境界。

## Decision Criteria

[spikes/state-reconciliation/SPIKE.md](spikes/state-reconciliation/SPIKE.md) の成功・失敗基準に照らして選択肢を比較し、採用する方式と残る制約を記録する。判断と結果を commit した後に、必要な実装・検証と現行 docs への反映を完了する。削除は [ADR workflow](../../docs/adr-workflow.md) の全条件を満たすまで行わない。

## Status

Spike Required
