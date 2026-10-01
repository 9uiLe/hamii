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

代表 corpus で決めた typed semantic node と separate domain graph を Current IR の境界とする。新しい supported semantics は個別の要件・consumer evidence に基づいて追加する。

## Unknowns

他の ordered effects、typed target extension、native escape hatch の具体的な production 対象は、現在の supported domain として要求されていない。必要になった場合は該当 feature の境界で format / migration と consumer lowering を検討する。

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

## Closure Review

Current IR の supported scope は7種類の typed `LayerPayload`、独立した domain graph、Screen-level system semantics、Stack spacing、順序付き padding effect である。Validator、TargetPlanner、Canvas、macOS Native Preview、SwiftUI Generator が対応する current semantics を扱う。Capability の宣言粒度と loss 評価は production の `CapabilityRegistry`、`SemanticRequirementExtractor`、`CapabilityEvaluator` と [Current Architecture](../../docs/final-architecture.md) が定める。

`nativeIntent: String?` と `targetOverrides: [String: String]` は Current Format v2 の opaque field であり、typed target extension / native escape hatch を実装したものではない。Round-trip で保持され、SemanticRequirementExtractor に抽出されるが、Preview / Generator catalog は supported と宣言しない。Target declaration が Exact でも Native Preview と SwiftUI Generator は拒否する。Product repository 固有の mapping は [Product Integration Contract ADR](../product-integration-contract/ADR.md) の別 decision boundary とする。

Evidence は minimal IR corpus `1a9ab4e874ecb35ac31ab2caaabdfec0dae3e0e0`、decision `b69dcf85672f54f986e4c357d3fb4ed3301b18d9`、typed Layer payload `84e75b4bf3547e105acd9ea48ae7567dc1a266f5`、Current Format v2 padding `9b83fc2417a60664ca91b49d3d1a0686bf84404a`、SwiftUI padding `4f1d777c404030024db50cb7efc4e8ddfb27cc91` と CLI contract `204a4719250c3d27ae187f1fa2ef6b610cf59754`、SwiftUI Stack spacing `a0c50ad6bf30dd2cfe4e1e93cf57fe769617b1b1` と CLI contract `0179706836dab7bb8843f5d43accd8fb648f8a7d` に残る。この closure commit は opaque field の Current Format round-trip と consumer fail-closed regression を追加する。

将来、代表 product screen が別の ordered effect、typed target extension、native escape hatch を必要とする、target extension が portable semantics を支配する、または UIKit / Compose lowering で portable semantics の意味が両立しないと判明した場合は、具体的な要求と evidence をもとに新しい decision boundary を作る。Current Format v2 reader は未知の effect kind を拒否するため、別の persisted effect は format / migration を伴う。これらを現 ADR の未完了作業とはしない。Closure commit が history に残り恒久テスト・Current Architecture が成立した後、次の commit でこの ADR を削除する。

## Status

Implementation Required
