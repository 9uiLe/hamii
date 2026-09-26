# Native Preview frame の取得・表示方式

## Context

Canvas の AppSurface に Host の native 描画結果を表示するには、frame を取得し revision と対応付ける必要がある。

## Decision to Make

Native Preview frame の capture/stream と stale 表示の方式を決める。

## Constraints

Simulator.app window の直接 embed に依存しない。frame は Host が ack した source revision と結びつく。

## Options

Host image stream、platform capture API、native surface bridge。

## Current Hypothesis

**未確定:** Host image stream は候補だが latency と interaction fidelity は未実測。

## Unknowns

公開 API、frame capture latency、連続 frame の帯域、resize/scale、stale frame UX。

## Required Evidence

- [Frame capture and revision fidelity](spikes/frame-latency/SPIKE.md)

## Decision Criteria

必要な Evidence から選択肢を比較し、採用理由と残る制約を記録する。判断と結果を先に commit し、必要な実装・検証と Current Architecture への反映を完了する。削除は [ADR workflow](../../docs/adr-workflow.md) の全条件を満たすまで行わない。

## Related Decisions

- [preview-host-transport](../preview-host-transport/ADR.md)
- [preview-input-forwarding](../preview-input-forwarding/ADR.md)

## Status

Spike Required
