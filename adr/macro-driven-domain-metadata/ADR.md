# Swift Macro の責務境界

## Context

IR、patch、Inspector、CLI metadata を手動で重複記述すると drift が起きる。一方、Macro を schema の唯一の正本にすると Canonical Format の安定性が compiler implementation に依存する。

## Decision to Make

Domain metadata のうち Swift Macro で生成する範囲と、明示的 schema として保つ範囲を決める。

## Constraints

Canonical Format は runtime type layout と独立する。Core は Macro plugin 実装を runtime dependency にしない。build time と AI context cost を測る。

## Options

No Macro、property/patch metadata だけ生成、Inspector/CLI/Capability metadata まで生成。

## Current Hypothesis

**未確定:** 小さな metadata 生成に限定し、永続 schema を明示的に version 管理する。

## Unknowns

Swift 6.4 build cost、診断品質、生成物の差分、schema rename 時の migration 誤検知。

## Required Evidence

[Metadata prototype](spikes/metadata-prototype/SPIKE.md) で手動実装と比較する。

## Decision Criteria

重複を実測で減らし、build/debug cost と Canonical stability の両方を維持できる範囲だけ採用する。

## Status

Spike Required
