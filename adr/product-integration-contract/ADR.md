# Product Integration Contract の実証

## Context

hamii IR は Product 固有 architecture を持たない。異なる既存 repository へ UI intent を失わず適応するには、AI に渡す contract の形を実証する必要がある。

## Decision to Make

Inputs/Events/Bindings/Tokens/States/Native/A11y intent のどの粒度で repository-aware AI に渡せば、異なる product architecture に安全に適応できるか。

## Constraints

MVVM/TCA/DI/Router は IR に入れない。AI の変更は reviewable diff、unknown mapping は Needs Resolution。

## Options

component 単位 contract、screen 単位 contract、dependency graph 付き contract。State semantics の不足部分は typed binding relation または annotated graph で補う候補として比較済み。

## Current Hypothesis

**検証時点の仮説（Decision ではない）:** UI intent の semantic contract と repository profile を渡せば、AI は異なる product architecture に適応できる可能性がある。State semantics は typed relation だけで表せる可能性がある。

## Decision

**Screen-level semantic contract を正式な Product Integration Contract の外枠とし、その中に typed state/binding relations を持たせる。** Component-level contract と full dependency graph は必須の canonical contract 構造にしない。Component 化そのものは禁止しない。Product Repository の componentization は Repository Profile と integration 実装側で判断する。

Screen contract は Product 非依存の UI semantic intent を所有する。既存の inputs / events / tokens / assets / native / accessibility に加え、typed relation は semantic output と semantic source の関係、visibility predicate、nil behavior、必要な semantic transform を表す。`profile.displayName`、`profile.createdAt`、`profile.renderable` のような semantic source は contract に属する。`Profile.nickname`、TCA/MVI/MVVM の State/Reducer、Router、Swift file path などの Product 固有の表現を contract に入れない。Repository Profile が semantic source / event / token / asset / native requirement と対象 Repository の model / action / route / source を対応付ける。

独立した `updateTrigger` field は必須にしない。[binding-state-relation-minimum Spike](spikes/binding-state-relation-minimum/SPIKE.md) では relation の source dependencies から更新対象を識別できたが、runtime 更新伝播は未検証である。Full graph は禁止せず、複雑な multi-source semantics で typed relation が一意性を保てない実証が出たときに再評価する。

**`Needs Resolution` は fail-closed integration result であり advisory warning ではない。** Mapping の欠落・空・不正、semantic source の解決不能、複数候補による曖昧さ、required transform の実装不能、既存 Product behavior と requested semantic の衝突では、その unresolved semantic に依存する code change を生成しない。AI は source 名の類似から mapping を推測せず、衝突時に overlay / fallback / replacement を無断選択しない。特に I03 の system-image avatar と Product avatar art の衝突は `Needs Resolution` とする。無関係の semantic まで常に全面停止するかはこの Decision では固定しない。部分適用するなら、依存関係を機械的に検査し、unresolved semantic に依存する patch を拒否する。

**理由:** [repository-mapping Spike](spikes/repository-mapping/SPIKE.md) と [existing-profile-state Spike](spikes/existing-profile-state/SPIKE.md) は複数 Repository / contract 表現で source-level mapping と build を確認し、component-level 外枠や graph 外枠を必須とする差を示さなかった。[independent-diff-review Spike](spikes/independent-diff-review/SPIKE.md) は3方式すべてに I03 の contract/Product conflict と修正負担を見つけた。[state-semantics-self-sufficiency Spike](spikes/state-semantics-self-sufficiency/SPIKE.md) は3方式すべてが state 名・edge だけでは不十分と確認した。[binding-state-relation-minimum Spike](spikes/binding-state-relation-minimum/SPIKE.md)（Evidence commit `155f8144fd6cfdb824a0f1f42250d37194ea3672`）では typed relation R と annotated graph G が P0–P4 × I01/I02 の10セルを同じく表現し、mapping 欠落は両方 fail closed だった。この範囲で G 固有 topology は追加の意味を提供しなかった。現行 [IntegrationContract](../../Sources/HamiiIntegration/IntegrationContract.swift) も screen を integration entry point としている。この Evidence から、screen 外枠に不足する typed relation を加える設計を採用する。

**実装完了前の検証条件:** typed relation の extraction / serialization round-trip、deterministic planning、missing / empty / ambiguous mapping の fail-closed、P0 first load と P1 cached refresh と P2 refresh failure の区別、P3 nil fallback、P4 nonnil transform、I03 conflict rejection、既存 edit route の grounded mapping、実 Product の build/test、runtime の表示・event・accessibility を確認する。Cache と update propagation、calendar/time-zone/copy、Source mapping の Product 実装が正しく動くことも検証する。Human correction は未計測と明記し、agent review を Human review に読み替えない。これらの validation は contract 粒度 Decision の撤回条件ではなく、production 実装を完成させる条件である。

## Unknowns

Production typed relation の schema、extraction / planner への接続、Repository Profile の mapping 検証、Product 統合と runtime 確認は未実装。I03 の具体的 visual 解決と Human correction は未計測である。I02 empty-profile behavior は independent reviewer 間で判定が異なったが、P0–P4 oracle では profile presence と cached refresh を分けて扱った。Runtime behavior と final Product copy の検証は必要であり、この Decision の Evidence 範囲を超える。

## Required Evidence

[spikes/repository-mapping/SPIKE.md](spikes/repository-mapping/SPIKE.md) は2つの実 SwiftUI Repository × 3表現を測り、全 final patch で source-level semantic traceability と build を確認した。試行は同一 AI の逐次実行で Human correction は未計測。[spikes/existing-profile-state/SPIKE.md](spikes/existing-profile-state/SPIKE.md) は既存 profile state / edit route を持つ reducer/store Repository 1件 × 3表現を独立 context で比較した。3方式とも既存 state/route を利用し30件の既存 tests に成功した。[spikes/independent-diff-review/SPIKE.md](spikes/independent-diff-review/SPIKE.md) はその同じ3 final patch を匿名化して生成に参加していない agent が source audit した。33セルすべてに source 根拠を記録し、全方式が I03 の字義と既存 avatar behavior を両立できず、3件とも修正後 merge 可とした。I02 の empty-profile behavior は reviewer 間で評価が異なる。[spikes/state-semantics-self-sufficiency/SPIKE.md](spikes/state-semantics-self-sufficiency/SPIKE.md) は shared fixture を渡さず既存3 contract を再評価し、9セルのいずれも I01/I02 の state behavior を contract 単体では十分に指定しないと確認した。[spikes/binding-state-relation-minimum/SPIKE.md](spikes/binding-state-relation-minimum/SPIKE.md) は P0–P4 の10セルで typed relation R と annotated graph G を機械的に比較し、どちらも 10/10、一方の Repository mapping が欠けた場合は両方が Needs Resolution となった。独立 source audit は両候補から同じ表示規則を導き、Product mapping の未実装を区別した。このケースでは full graph は state semantics の必要条件でない。Human correction と runtime UI は依然未計測である。方式の採否はまだ決めない。Spike prototype は production adapter ではない。

## Decision Criteria

上の Decision を別 commit の production 実装・検証と現行 docs に反映する。実装完了前の検証条件を満たし、未解決の follow-up がなく、Decision / Spike result が Git history に残った後にだけ [ADR workflow](../../docs/adr-workflow.md) に従って削除する。

## Status

Implementation Required
