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

contract の粒度を選ぶための、state predicate と binding/output rules の最小表現、新しい表示・イベントの runtime behavior、system-image avatar intent と既存 Product avatar semantics の衝突時の扱い。既存 profile state / edit route への mapping は1つの reducer/store Repository の独立3試行で検証した。生成に参加していない agent 3名による blind review は全差分で I03 の未達または partial mapping を見つけ、I02 の empty-profile behavior は reviewer 間で判定が異なった。続く contract-only probe では screen / component / graph のすべてが S0/S1/S2 の I01/I02 を一意に指定できなかった。Product の cached profile 表示を保つには S0 の unavailable と refresh loading の区別も必要である。Human correction は未計測だが、これ単独を Decision 阻止条件にはしない。

## Required Evidence

[spikes/repository-mapping/SPIKE.md](spikes/repository-mapping/SPIKE.md) は2つの実 SwiftUI Repository × 3表現を測り、全 final patch で source-level semantic traceability と build を確認した。試行は同一 AI の逐次実行で Human correction は未計測。[spikes/existing-profile-state/SPIKE.md](spikes/existing-profile-state/SPIKE.md) は既存 profile state / edit route を持つ reducer/store Repository 1件 × 3表現を独立 context で比較した。3方式とも既存 state/route を利用し30件の既存 tests に成功した。[spikes/independent-diff-review/SPIKE.md](spikes/independent-diff-review/SPIKE.md) はその同じ3 final patch を匿名化して生成に参加していない agent が source audit した。33セルすべてに source 根拠を記録し、全方式が I03 の字義と既存 avatar behavior を両立できず、3件とも修正後 merge 可とした。I02 の empty-profile behavior は reviewer 間で評価が異なる。[spikes/state-semantics-self-sufficiency/SPIKE.md](spikes/state-semantics-self-sufficiency/SPIKE.md) は shared fixture を渡さず既存3 contract を再評価し、9セルのいずれも I01/I02 の state behavior を contract 単体では十分に指定しないと確認した。State list や graph topology だけでは source expression、state predicate、visibility / fallback / transformation を補えない。Human correction と runtime UI は依然未計測である。方式の採否はまだ決めない。Spike prototype は production adapter ではない。

## Decision Criteria

[spikes/repository-mapping/SPIKE.md](spikes/repository-mapping/SPIKE.md) の成功・失敗基準に照らして選択肢を比較し、採用する方式と残る制約を記録する。判断と結果を commit した後に、必要な実装・検証と現行 docs への反映を完了する。削除は [ADR workflow](../../docs/adr-workflow.md) の全条件を満たすまで行わない。

## Status

Spike Required
