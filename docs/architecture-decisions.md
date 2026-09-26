# hamii Architecture Decision Records

Status: accepted design baseline, 2026-09-26. ここには現時点で確定した設計判断を記録する。実装済みという意味ではなく、未確定の具体的な技術選択は [`adr/`](../adr/) に置く。pending ADR は `adr/<name>/ADR.md`、必要な実験は同じ場所の `SPIKE.md`、成果物は `artifacts/` に置く。検証・対応後に内容をこの文書または実装・運用 docs へ反映してそのディレクトリを削除する。目標状態は `adr/` に `.gitkeep` 以外の item がないこと。番号は [最終設計](final-architecture.md) の要求順に固定。`Revisit When` は判断を開き直す条件。

## ADR-001 Source of Truth
- **Decision:** Native-semantic IR を編集正本とする。
- **Context:** Canvas、AI、Preview、source の二重正本は同期不能になる。
- **Options:** Native source / visual JSON / typed IR。
- **Chosen Approach:** versioned typed IR、source は出力物。
- **Reason:** 構造 mutation と target lowering を共有できる。
- **Trade-offs:** 任意 source の round-trip は保証しない。
- **Risks:** IR と production の意味差。
- **Revisit When:** 実 screen corpus の重要 UI を IR で表現できない。

## ADR-002 Native-semantic IR
- **Decision:** typed node、ordered effects、domain refs、stable ID を持つ。
- **Context:** 大きな万能 Layer と pixel geometry は native 意味を失う。
- **Options:** flat property bag / framework AST / typed layered graph。
- **Chosen Approach:** small node schema + component/token/asset/interaction graph。
- **Reason:** field ごとの capability、validation、diff が可能。
- **Trade-offs:** resolver と schema registry が必要。
- **Risks:** 過度な抽象化、cycle。
- **Revisit When:** Spike 01 で node taxonomy が崩れる。

## ADR-003 Supported Native Domain
- **Decision:** Supported Domain を明示し、任意 native code を対象外にする。
- **Context:** UI framework 全 API の visual round-trip は保証困難。
- **Options:** 万能 Visual IDE / bitmap design / constrained native UI。
- **Chosen Approach:** hierarchy/layout/style/system semantics/limited interaction を段階拡張。
- **Reason:** 対応機能の意味を検証できる。
- **Trade-offs:** escape hatch が必要。
- **Risks:** 日常画面に足りない可能性。
- **Revisit When:** corpus の主要画面が escape hatch だらけになる。

## ADR-004 Capability Model
- **Decision:** feature/property/target/runtime ごとに Exact/Portable/Target-specific/Approximate/Unsupported/External を評価する。
- **Context:** 無言の近似は Preview と export を誤認させる。
- **Options:** boolean support / free-text warning / typed levels。
- **Chosen Approach:** shared registry + loss report + blocking rule。
- **Reason:** Human、AI、Host、generator の判定を一致させる。
- **Trade-offs:** matrix 保守費。
- **Risks:** 過細分化。
- **Revisit When:** 判定の矛盾や保守遅延が頻発する。

## ADR-005 Document / Page / Layer
- **Decision:** Document→Page→Layer を編集骨格とし Page は自由な整理単位。
- **Context:** Page hierarchy を architecture に結びつけると WIP/Experiment を阻害する。
- **Options:** Page=feature / Page=screen / free Page + explicit ScreenRoot。
- **Chosen Approach:** ScreenDefinition ID、Surface ref、Scope は別 graph。
- **Reason:** 同じ Screen を複数 device で表示できる。
- **Trade-offs:** cross-graph references が増える。
- **Risks:** orphan Surface。
- **Revisit When:** ScreenRoot の所有と移動 UX が複雑化する。

## ADR-006 Architecture Scope
- **Decision:** UI resource の ownership を ArchitectureScope tree で表す。
- **Context:** Page や file path では module ownership を表現できない。
- **Options:** folder naming / tag / explicit scope tree。
- **Chosen Approach:** stable scope ID と親関係。
- **Reason:** 依存規則を機械的に評価できる。
- **Trade-offs:** resource 配置と promotion の操作が増える。
- **Risks:** 実 repository architecture と乖離。
- **Revisit When:** 多数の例外が必要になる。

## ADR-007 Component Definition / Variant / Instance
- **Decision:** Instance は Definition ref+selection+values+限定 override を持つ。
- **Context:** subtree copy は更新、保存、merge に不利。
- **Options:** copy / ref / ref with detach。
- **Chosen Approach:** ref と sparse variant delta、明示 detach。
- **Reason:** shared Definition の変更を追跡できる。
- **Trade-offs:** resolver cache/invalidation が必要。
- **Risks:** variant explosion、cycle。
- **Revisit When:** 1k instance benchmark または UX が失敗する。

## ADR-008 Component Scope Rules
- **Decision:** Consumer は自己・祖先 Scope の resource のみ参照する。
- **Context:** sibling 依存は architecture boundary を曖昧にする。
- **Options:** 無制限 / allowlist / ancestor-only + promotion。
- **Chosen Approach:** ancestor-only、LCA promotion、例外は availability の制限だけ。
- **Reason:** 依存方向が明瞭で検証可能。
- **Trade-offs:** promotion の再検証と承認が必要。
- **Risks:** 上位 Scope の肥大化。
- **Revisit When:** promotion が常態化し上位 API が不安定になる。

## ADR-009 Actor Interface
- **Decision:** GUI と AI は異なる interface から同じ Intent API を使う。
- **Context:** store への直接書込は policy bypass と Undo 不整合を生む。
- **Options:** direct mutation / GUI automation / semantic commands。
- **Chosen Approach:** Human controls→Intent、AI Query/Command/Patch→Intent。
- **Reason:** 同じ validation と revision 管理。
- **Trade-offs:** command taxonomy が必要。
- **Risks:** GUI の高頻度 drag latency。
- **Revisit When:** interaction budget を満たせない。

## ADR-010 Actor Harness
- **Decision:** Human/Agent の操作設定と権限を actor 別に保持する。
- **Context:** 複数 Agent は retrieval と自律性が異なる。
- **Options:** global settings / prompts only / actor profiles。
- **Chosen Approach:** Human Harness と複数 Agent Harness。
- **Reason:** 共通 policy を維持しつつ入口を調整できる。
- **Trade-offs:** profile 管理費。
- **Risks:** role 権限の誤設定。
- **Revisit When:** profile が resource policy と重複する。

## ADR-011 Authoring Harness
- **Decision:** scope、capability、token、asset、a11y 等を machine policy とする。
- **Context:** prompt のみでは Human/AI に同じ制約を課せない。
- **Options:** 文書規約 / prompt / typed policy+validator。
- **Chosen Approach:** versioned policy、rule ID、severity、waiver。
- **Reason:** 編集時に強制し説明できる。
- **Trade-offs:** policy schema と migration が必要。
- **Risks:** rigid な authoring。
- **Revisit When:** waiver が多発する。

## ADR-012 Integration Harness
- **Decision:** product repository 適応を Authoring Harness と分ける。
- **Context:** MVVM/TCA/DI/Router は hamii UI の意味ではない。
- **Options:** IR に統合規則 / generator に固定 / separate profile。
- **Chosen Approach:** repository profile、mapping、verification policy。
- **Reason:** 同じ UI Intent を異なる repo に適応できる。
- **Trade-offs:** contract/profile 同期が必要。
- **Risks:** AI による誤 mapping。
- **Revisit When:** repo-aware integration の成功率が低い。

## ADR-013 Mutation Model
- **Decision:** expectedRevision 付き atomic typed patch を唯一の write path とする。
- **Context:** Human/AI/Undo/Preview を別更新にすると不整合。
- **Options:** JSON rewrite / mutable object / command transaction。
- **Chosen Approach:** Intent→preflight→all-or-nothing Patch→revision。
- **Reason:** Undo、conflict、incremental invalidation に再利用。
- **Trade-offs:** inverse と stale conflict UX が必要。
- **Risks:** multi-entity transaction の保存失敗。
- **Revisit When:** fault injection で破損する。

## ADR-014 Canvas Renderer
- **Decision:** AppKit/CG/CA の viewport culling と LOD で編集描画。
- **Context:** Native Host は high-frequency infinite canvas の renderer ではない。
- **Options:** node ごとの NSView / SwiftUI Canvas / AppKit custom / Metal。
- **Chosen Approach:** custom Canvas、Metal は benchmark 後。
- **Reason:** hit test、選択、dirty region を制御しやすい。
- **Trade-offs:** Native 表示とは近似になる。
- **Risks:** fidelity drift、a11y の別実装。
- **Revisit When:** 10k/50k layer benchmark 失敗。

## ADR-015 Native Preview Runtime
- **Decision:** Supported node を事前 compile した Host に Target Plan を送る。
- **Context:** 通常編集で Xcode build を回すと設計操作が遅い。
- **Options:** build-per-edit / Canvas only / precompiled Host。
- **Chosen Approach:** SwiftUI first、UIKit separate、Compose later。
- **Reason:** 値更新を Native state mechanism に載せられる可能性。
- **Trade-offs:** generator とは別実装。
- **Risks:** latency、identity、parity 未実証。
- **Revisit When:** Spike 02/04 で成立しない。

## ADR-016 Build Boundaries
- **Decision:** Patch/Reconciliation/Component Build/Full Build を明示する。
- **Context:** custom source と値の変更は必要作業が違う。
- **Options:** implicit build / 常時 build / classified boundary。
- **Chosen Approach:** build は明示 action、stale preview を表示。
- **Reason:** 編集コストを予測できる。
- **Trade-offs:** custom component の preview 更新は遅れる。
- **Risks:** component-only build が実際には full relink。
- **Revisit When:** artifact spike で必要 build 範囲が判明する。

## ADR-017 Custom Native Components
- **Decision:** opaque implementation と typed interface/preview contract を保持する。
- **Context:** arbitrary source は Core の理解外。
- **Options:** AST import / bitmap / native adapter。
- **Chosen Approach:** symbol、props/events、layout behavior、artifact ref。
- **Reason:** supported IR の境界を守れる。
- **Trade-offs:** 内部 visual edit 不可。
- **Risks:** code signing、artifact lifecycle。
- **Revisit When:** adapter build spike が失敗する。

## ADR-018 System-managed UI
- **Decision:** Navigation/Toolbar/Sheet/Safe Area 等は semantic configuration。
- **Context:** OS/framework が geometry と behavior を所有する。
- **Options:** rectangle layer / opaque screenshot / typed system config。
- **Chosen Approach:** System と Custom の明示変換。
- **Reason:** native behavior と Inspector の意味が一致。
- **Trade-offs:** target ごとの対応差。
- **Risks:** custom 化で a11y/system behavior 喪失。
- **Revisit When:** system UI capability が足りない。

## ADR-019 Interaction / State
- **Decision:** typed UI-local state machine と event/action を採用。
- **Context:** static design だけでは preview 実行できない。
- **Options:** full logic editor / static variant / small state graph。
- **Chosen Approach:** tap、setState/setVariant、emitEvent から開始。
- **Reason:** business logic を Core に入れず動作を示せる。
- **Trade-offs:** complex interaction は外部へ委ねる。
- **Risks:** 状態数と event ordering。
- **Revisit When:** 主要 screen の preview が成立しない。

## ADR-020 Motion
- **Decision:** Transition と MotionDefinition/Token を分離する。
- **Context:** 状態変化と時間変化は別の意味。
- **Options:** inline animation / target raw API / semantic motion。
- **Chosen Approach:** instant/tween/spring、target override、Reduce Motion。
- **Reason:** 再利用と target 診断。
- **Trade-offs:** 完全な時間一致は保証しない。
- **Risks:** Host/export drift。
- **Revisit When:** motion conformance が失敗する。

## ADR-021 Assets
- **Decision:** Layer から Asset entity を参照し、source type を区別する。
- **Context:** repo/remote/runtime/system/generated は寿命が違う。
- **Options:** inline URL/path / untyped asset / typed source。
- **Chosen Approach:** logical ID + hash object、derived cache 分離。
- **Reason:** integrity、rename、eviction が独立。
- **Trade-offs:** resolver と LFS policy が必要。
- **Risks:** repo 肥大、remote secret。
- **Revisit When:** asset spike が運用難を示す。

## ADR-022 Preview Fixtures
- **Decision:** runtime binding schema と sample fixture を分ける。
- **Context:** production data と preview value を混ぜられない。
- **Options:** literal default / bindings only / binding+fixture。
- **Chosen Approach:** typed binding path、Surface-selected fixture。
- **Reason:** preview 実行と production contract を両立。
- **Trade-offs:** fixture 保守。
- **Risks:** PII、schema drift。
- **Revisit When:** export API と fixture が噛み合わない。

## ADR-023 Design Tokens
- **Decision:** typed primitive/semantic aliases と target override を持つ。
- **Context:** style literal は design system と product mapping に弱い。
- **Options:** literals / flat tokens / typed graph。
- **Chosen Approach:** graph + cycle/type validation。
- **Reason:** 一貫した変更と依存 invalidation。
- **Trade-offs:** alias 移行が必要。
- **Risks:** platform font/shape 差。
- **Revisit When:** override 数が常態化する。

## ADR-024 Token Templates
- **Decision:** Template は project へ snapshot instantiate する。
- **Context:** live dependency は外部更新で既存画面を変える。
- **Options:** live link / snapshot / forced sync。
- **Chosen Approach:** provenance を残し upgrade は merge。
- **Reason:** project ownership が明確。
- **Trade-offs:** 更新操作が必要。
- **Risks:** rename conflict。
- **Revisit When:** shared template 運用が live link を要求する。

## ADR-025 Canonical Git Storage
- **Decision:** Git repo の分割 Current Format を canonical とする。
- **Context:** チーム共有と diff/review、offline 編集が必要。
- **Options:** monolithic JSON / SQLite authoritative / semantic files in Git。
- **Chosen Approach:** stable ID file、deterministic serializer、atomic save。
- **Reason:** 通常の Git workflow を使える。
- **Trade-offs:** text merge conflict と multi-file transaction。
- **Risks:** shard 粒度・repository growth。
- **Revisit When:** merge/save benchmark が失敗する。

## ADR-026 Local Query Index
- **Decision:** SQLite は derived disposable index とする。
- **Context:** 毎 query の Git file 全走査は高価。
- **Options:** full scan / SQLite 正本 / derived SQLite。
- **Chosen Approach:** incremental index + fingerprint + rebuild。
- **Reason:** query 性能と正本を分離。
- **Trade-offs:** indexing latency。
- **Risks:** drift/corruption。
- **Revisit When:** rebuild が実用時間を超える。

## ADR-027 Migration Boundary
- **Decision:** Core は Current Format だけを理解する。
- **Context:** legacy condition は通常開発と AI context を汚染する。
- **Options:** Core 内 version switch / compatibility adapter / isolated migrators。
- **Chosen Approach:** historical parser→edge transforms→Current Format。
- **Reason:** 現行 model の単純性を守れる。
- **Trade-offs:** migration package 維持。
- **Risks:** edge 欠落、manual case。
- **Revisit When:** migration graph が運用不能になる。

## ADR-028 Format Versioning
- **Decision:** Document/Harness/Integration/Index/App/Host protocol version を分離。
- **Context:** 内部 refactor と persisted semantics の変更は別。
- **Options:** App version 一つ / all schemas lockstep / independent versions。
- **Chosen Approach:** independent version と必要な migrator。
- **Reason:** 不要な document migration を防ぐ。
- **Trade-offs:** compatibility matrix が必要。
- **Risks:** version pairing の組合せ。
- **Revisit When:** support matrix が複雑化する。

## ADR-029 Product Integration
- **Decision:** deterministic standalone generation と AI repo-aware integration を分ける。
- **Context:** 既存 app の architecture は hamii Core が知るべきでない。
- **Options:** generator に全 convention / IR に MVVM / contract+AI。
- **Chosen Approach:** semantic contract + Integration Harness + reviewable AI diff。
- **Reason:** UI intent を維持し product convention に従える。
- **Trade-offs:** AI の再現性は deterministic generator より低い。
- **Risks:** repo 誤解・破壊的変更。
- **Revisit When:** 実 repo で成功率が低い。

## ADR-030 AI Context Architecture
- **Decision:** Scope-aware staged retrieval と selection/visual context を分離する。
- **Context:** 全 document/catalog を毎回渡すと cost と誤用が増える。
- **Options:** full dump / raw file search / semantic query projection。
- **Chosen Approach:** summary→detail、available-resource filter、revision-bound patches。
- **Reason:** 小さい context で policy と整合する。
- **Trade-offs:** index/query API の保守。
- **Risks:** context omission。
- **Revisit When:** Spike 13 の task success が低い。
