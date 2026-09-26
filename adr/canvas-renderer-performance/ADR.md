# Canvas Renderer の描画基盤

## Context

大きい Page の pan/zoom と hit testing は Native Host と異なる性能要件を持つ。AppKit/CG/CA で足りるか未実測。

## Decision to Make

Canvas の基盤を AppKit/CG/CA のままにするか、Metal へ移す条件を決める。

## Constraints

Canvas は近似表示であり selection/hit test/a11y を持つ。viewport culling と LOD を前提とする。

## Options

AppKit/CG/CA、Metal、hybrid。

## Current Hypothesis

**未確定:** AppKit/CG/CA で初期範囲を満たせる可能性がある。

## Unknowns

10k/50k Layer、画像、Zoom、memory pressure での性能。

## Required Evidence

- [Large Canvas benchmark](spikes/large-canvas/SPIKE.md)

## Decision Criteria

Spike の結果を用いて選択肢を比較し、判断を先に commit する。必要な実装・検証と Current Architecture への反映を終えるまで削除しない。

## Status

Spike Required
