# Compose / CMP target 導入時期

## Context

SwiftUI/UIKit だけで IR を固定すると portable semantics が Apple 固有へ偏る恐れがある。一方 CMP Host を MVP に含めると検証範囲が広がる。

## Decision to Make

Compose Android と CMP iOS の architecture validation/Host 実装をどの Phase に置くか。

## Constraints

Compose Android と CMP iOS は別 artifact/profile。MVP の中心仮説は SwiftUI で先に検証する。

## Options

IR 段階で Compose lowering だけ試す、Android Host を MVP 同時実装、Phase 5 以降に導入。

## Current Hypothesis

**未確定:** 小さな Compose lowering を早期に行い、Host は Later とする可能性が高い。

## Unknowns

portable IR の偏り、Compose recomposition/state、CMP resource/entry point 差、工数。

## Required Evidence

- [Compose IR validation](spikes/compose-ir-validation/SPIKE.md)

## Decision Criteria

Spike の結果を用いて選択肢を比較し、判断を先に commit する。必要な実装・検証と Current Architecture への反映を終えるまで削除しない。

## Status

Spike Required
