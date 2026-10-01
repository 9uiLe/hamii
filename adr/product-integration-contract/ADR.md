# Product Integration Contract の実証

## Context

hamii IR は Product 固有 architecture を持たない。異なる既存 repository へ UI intent を失わず適応するには、AI に渡す contract の形を実証する必要がある。

## Decision to Make

Inputs/Events/Bindings/Tokens/States/Native/A11y intent のどの粒度で repository-aware AI に渡せば、異なる product architecture に安全に適応できるか。

## Constraints

MVVM/TCA/DI/Router は IR に入れない。AI の変更は reviewable diff、unknown mapping は Needs Resolution。

## Options

component 単位 contract、screen 単位 contract、dependency graph 付き contract。

## Current Hypothesis

**未確定:** UI intent の semantic contract と repository profile を渡せば、AI は異なる product architecture に適応できる可能性がある。

## Unknowns

contract の粒度を選ぶための独立 review、Human 修正量、新しい表示・イベントの runtime behavior。既存 profile state / edit route への mapping は1つの reducer/store Repository の独立3試行で検証したが、system avatar 指定は2方式で未達だった。現行 screen-level `IntegrationContract` は States と dependency structure を独立 field に持たず、共通 fixture の補足なしで十分かは未検証。

## Required Evidence

[spikes/repository-mapping/SPIKE.md](spikes/repository-mapping/SPIKE.md) は2つの実 SwiftUI Repository × 3表現を測り、全 final patch で source-level semantic traceability と build を確認した。試行は同一 AI の逐次実行で Human correction は未計測。[spikes/existing-profile-state/SPIKE.md](spikes/existing-profile-state/SPIKE.md) は既存 profile state / edit route を持つ reducer/store Repository 1件 × 3表現を独立 context で比較した。3方式とも既存 state/route を利用し30件の既存 tests に成功した一方、2方式で avatar asset の固定意図が未達だった。screen 表現の States / dependency 欠落は共通 fixture で補われており、方式の採否はまだ決めない。次の Evidence は独立 review と新しい表示・イベントの runtime validation のうち1件へ絞る。Spike prototype は production adapter ではない。

## Decision Criteria

[spikes/repository-mapping/SPIKE.md](spikes/repository-mapping/SPIKE.md) の成功・失敗基準に照らして選択肢を比較し、採用する方式と残る制約を記録する。判断と結果を commit した後に、必要な実装・検証と現行 docs への反映を完了する。削除は [ADR workflow](../../docs/adr-workflow.md) の全条件を満たすまで行わない。

## Status

Spike Required
