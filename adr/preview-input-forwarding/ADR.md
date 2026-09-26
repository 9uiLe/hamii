# Native Preview input forwarding

## Context

Canvas 内の Native Preview を操作可能にするには、pointer/keyboard/gesture を target Host の座標系と state へ届ける必要がある。

## Decision to Make

AppSurface の入力を Host に転送し、event trace と UI state を同期する方式を決める。

## Constraints

Human の Canvas 操作と Preview 操作を区別する。入力は対象 Surface と source revision に対応する。

## Options

座標付き pointer/key event forwarding、semantic action forwarding、platform input injection。

## Current Hypothesis

**未確定:** basic tap の転送は可能と見込むが target API と gesture fidelity は未検証。

## Unknowns

座標変換、focus/keyboard、gesture、複数 Surface routing、OS 権限。

## Required Evidence

- [Preview input routing](spikes/input-routing/SPIKE.md)

## Decision Criteria

必要な Evidence から選択肢を比較し、採用理由と残る制約を記録する。判断と結果を先に commit し、必要な実装・検証と Current Architecture への反映を完了する。削除は [ADR workflow](../../docs/adr-workflow.md) の全条件を満たすまで行わない。

## Related Decisions

- [preview-host-transport](../preview-host-transport/ADR.md)
- [preview-frame-capture](../preview-frame-capture/ADR.md)

## Status

Spike Required
