# Native-semantic IR の最小 taxonomy

## Context

最初の node/field taxonomy が framework API の写しや汎用 property bag になると、後の Preview、生成、migration が不安定になる。

## Decision to Make

Text/Image/Button/Stack/Scroll/Navigation/Toolbar と ordered effects、target override を表す最小 Current IR の境界を決める。

## Constraints

Source of Truth は IR。Page/Scope/Component などの graph を Layer の万能 field に詰め込まない。Product 固有 architecture を入れない。

## Options

typed node と別 graph、汎用 property bag、framework-specific AST。

## Current Hypothesis

**未確定:** typed node + separate domain graph + target extension で主要 screen を loss-aware に記述できる。

## Unknowns

代表 screen corpus で不足する意味、ordered effects の最小形、target-specific extension の増加率。

## Required Evidence

[spikes/minimal-ir/SPIKE.md](spikes/minimal-ir/SPIKE.md) で検証する。結果と判断を削除前の Git commit に残す。

## Decision Criteria

Spike の成功/失敗基準に照らして方式を選び、必要な実装・検証を完了し、恒久的なルールを Current Architecture または code に移す。[ADR workflow](../../docs/adr-workflow.md) の削除条件と commit 順に従う。

## Decision

2026-09-28: [minimal-ir Spike](spikes/minimal-ir/SPIKE.md) の代表 corpus と検証結果に基づき、Current IR の設計境界として **typed semantic node payload、順序を保持する typed effects、独立した domain graph、Screen-level の system semantics、明示的な typed target extension、分離された native escape hatch** を採用する。これは taxonomy の方向を決めるものであり、Spike の試作型をそのまま production schema にする決定ではない。

- Text、Image、Button、Stack、Scroll、Overlay、ComponentInstance など、node kind 固有の意味は対応する typed payload が所有する。異なる kind の optional field を共有する形や、汎用 property bag を supported semantics の通常表現にしない。
- 意味が順序に依存する effect は IR 内の順序付き collection として扱う。Spike の padding/background という具体例だけに対象を固定しない。
- Page、ArchitectureScope、ComponentDefinition、Token、Asset、Interaction、Motion、PreviewFixture、Target は visual node に吸収しない。既存の stable EntityID、ComponentDefinition/Instance 分離、Token/Asset 参照、binding/event identity を維持する。
- System Navigation と Toolbar は自由配置の visual Layer ではなく、Screen-level の typed system semantics として扱う。Custom navigation は visual Layer tree を参照できる。
- Portable semantics に収まらない supported intent は、target/platform/framework と version を明示する typed extension に置く。Spike の `iOSSheetDetents` は境界の検証例であり、production API としては確定しない。
- Native escape hatch は portable payload と分離し、semantic owner、対象 target/platform/framework、payload version を明示する。代表 corpus の通常表現に使わない。
- Framework-specific AST を Core IR にせず、`nativeIntent` の文字列や任意の `targetOverrides` dictionary を supported semantics の主要表現にしない。

Evidence commit `1a9ab4e874ecb35ac31ab2caaabdfec0dae3e0e0` では、4 fixtures / 17 required intents の範囲で、現行形は2 intent に generic string を要し、typed candidate は generic bag と escape hatch を使わず表現した。5 focused tests は round-trip、stable ID、effect order、invalid-state probes を検証し、4 target の loss matrix は unsupported / approximate を明示した。これは **選択した corpus における taxonomy 境界**の根拠であり、framework API の網羅性、runtime parity、production lowering、将来の extension 使用頻度を証明しない。

代表的な product screen が繰り返し escape hatch を必要とする、target extension が portable semantics を支配する、必須意味に framework API の Core への漏出が必要になる、新しい順序依存を ordered effects が表せない、または UIKit / Compose lowering で一つの portable semantic の意味が両立しないと判明した場合に、この taxonomy 境界を再評価する。現時点で件数 threshold は設けない。

## Remaining Implementation

Production の `LayerPayload` は7種の現行 Layer kind を表し、Validator、TargetPlanner、Canvas、Native Preview、Generator と Mutation が利用する。Current Format v2 の Stack spacing は Stack 限定の意味として検証し、Canvas / Native Preview / SwiftUI Generator が同じ spacing Token を解決する。順序付き padding effect も Current Format v2 に保存し、3 consumer が記載順に適用する。Generator は Stack spacing に `layout.spacingToken` の宣言または既存 `token.spacing` alias を使い、padding には独立した `effect.padding` の明示宣言を要求する。Current Format v2 reader は未知の effect kind を拒否するため、別の persisted effect kind は format / migration 境界を検討せずに追加しない。残る実装は他の ordered effects、typed target extension と対応する lowering の範囲である。Screen-level system navigation は既存の別 graph に保持する。Capability の宣言粒度と loss 評価は production の `CapabilityRegistry`、`SemanticRequirementExtractor`、`CapabilityEvaluator` と [Current Architecture](../../docs/final-architecture.md) が定める。この ADR は残る production 実装と検証が完了するまで残す。

## Status

Implementation Required
