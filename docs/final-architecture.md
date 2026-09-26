# hamii — Product & System Architecture

Status: **設計基準（実装前）** / 2026-09-26。ここでの「採用」は製品方針であり、Native Host の性能や同等性を実証した意味ではない。確認済みの外部事実には一次資料を付け、hamii 固有の判断は設計上の推論として扱う。検証手順は [Technical Spikes](spikes.md)、確定した設計判断は [Decision Records](architecture-decisions.md)、未確定の検証事項は [`adr/`](../adr/) に置く。

## 1. Executive Summary

hamii は Human と AI が同じ **Current Native-semantic IR** を編集する macOS の UI 設計環境である。Actor ごとの入口は違っても、共通の Intent、Mutation、Authoring Harness、Validation を通る。IR から Canvas、コンパイル済み Native Preview Host、standalone generator、Product Integration Contract へ分岐する。Git repository の分割された Current Format が永続正本で、SQLite は再構築可能な検索 index。旧形式は隔離された migrator が Current Format へ変換する。

最大の設計上の留保は **Preview と production の意味的一致**である。Preview Host と生成コードは別実装なので、同じ Target Plan、capability diagnostics、fixture、accessibility/interaction/visual conformance で差を観測する。「Instant」は compile 不要を意味し、遅延ゼロは保証しない。[Apple SwiftUI state](https://developer.apple.com/documentation/swiftui/managing-user-interface-state/)、[Compose lifecycle](https://developer.android.com/develop/ui/compose/lifecycle)。

## 2. Product Definition

| Is | Is not |
|---|---|
| Native の意味を持つ Layer/Component を Human と AI が作る Visual Development Environment | Figma の模倣、任意 Swift/Kotlin の完全 round-trip IDE |
| 制約した Supported Domain を実行・検証・統合する workbench | business logic、network、DB、auth、DI、app lifecycle の builder |
| Native Preview と Production Integration へ同じ UI intent を渡す環境 | 両者の source syntax や pixel の一致を無条件に保証する仕組み |

初期 target は iOS SwiftUI/UIKit。Android Compose と CMP は別 target として設計し、MVP の成立後に cross-target IR の検証へ導入する。

## 3. Product Principles

1. Native semantics を geometry より優先し、system-owned UI は configuration で表す。
2. Human と AI は同じ revision、policy、validator、undo 経路で第一級の Author となる。
3. Supported feature の意味は保証し、Unsupported/Approximate を黙って変換しない。
4. 通常の GUI 編集から暗黙の build を起動しない。
5. Portable 意味だけ共有し、platform/framework 固有の意味を保存する。
6. IR に MVVM/TCA/DI/Repository/Router を入れない。
7. Authoring Policy は機械的に検査し、Prompt はその説明にとどめる。
8. Core は Current Format のみ読む。Local index と render cache は捨てられる。
9. Stable ID、意味単位の file 分割、原子的 mutation で Git と Undo を支える。
10. Native Preview と production の差は測り、capability と revision を画面に表示する。

## 4. Responsibility Boundaries

| Boundary | Owns | Does not own |
|---|---|---|
| Current Core / IR | UI hierarchy、意味、scope、component API、state、event、token/asset/binding 参照 | product の domain logic と source layout |
| Authoring | actor Intent、policy、validation、atomic patch | raw file 直接編集による抜け道 |
| Canvas | 選択、hit test、viewport、近似描画 | Native fidelity の最終判定 |
| Preview | Target Plan の native 実行、diagnostics、frame/event | 任意 source の実行、production repository の構成 |
| Standalone Generation | 対応 subset の再現可能な native source | 既存 repo の architecture 推測 |
| Integration | contract、repository profile、AI 適応、reviewable diff | IR 内への product-specific architecture 混入 |
| Git canonical storage | 分割 Current Format、資産の参照/実体 | query index、thumbnails |
| Migration | 旧形式の解析、変換、review report | Core に legacy branch を残すこと |

## 5. Whole Architecture Diagram

```text
Human GUI ─ Human Harness ─┐
                          ├─ Intent → Authoring Harness → Mutation/Validation → Current IR (revision)
AI Query/Command ─ Agent Harness ┘                         │
                                    ┌───────────────────────┼────────────────────────────┐
                                    ▼                       ▼                            ▼
                             Resolved Canvas Tree      Target Plan             Integration Contract
                                    │                  ┌─────┴─────┐                      │
                              AppKit/CG Canvas    Native Host  Generator       Integration Harness + AI
                                                     │          │                      │
                                              Native Preview Generic code       Product-native code
                                    │
Git canonical Current Format ↔ Format/Repository ↔ Core → Indexer → Disposable SQLite → Query/AI
Old Git Format → isolated Migration Coordinator → Current Format (reviewed branch)
```

## 6. Domain Model

```text
Document (project identity)
├─ Pages (free canvas organization) ─ Layer trees / AppSurfaces
├─ ArchitectureScopes (ownership tree, independent of Pages)
├─ ComponentDefinitions / Variants
├─ Tokens / Assets / Motions / Interactions / Fixtures
├─ Targets / Capability policy / Project settings
└─ AuthoringHarness reference or snapshot
```

Page は `Login`、`WIP`、`Experiment` など自由に整理でき、Scope を意味しない。ScreenDefinition は stable ID を持つ UI root、AppSurface はそれを参照する Page 上の editor object とする。Screen の subtree を Surface ごとにコピーしない。Layer は ID、kind、親子順、typed property、token/asset/component/interaction refs、target override に絞る。Definition の内部 tree は library entity が所有し、instance は参照する。全 reference と cycle、ID 一意性を検証する。

**修正点:** Document=1 App を初期 UX の既定値とし、file format の強制にはしない。複数 app target、design system 単独 repository、将来の package 分割を閉ざさない。Page や filesystem path は architecture ownership にならない。

```text
Page: Experiments              Scope: App
 ├─ Profile Screen ────────────────┐ ├─ Commerce ─ Product / Checkout
 └─ iPhone Surface → Profile       └─ Account ─ Profile / Settings
Component: PriceBadge → ownerScope Commerce.Product
```

## 7. Architecture Scope Model

Scope は DDD の Domain ではなく **UI resource ownership**。Resource の owner は stable Scope ID。Consumer は Screen/Component/Surface の effective Scope で決まる。基本 predicate は `owner ∈ ancestors(consumer) ∪ {consumer}`。したがって Checkout から App/Commerce/Checkout は可、Product/Account は不可。Component 定義内の nested instance も **定義 owner** から検査する。Instance を別 Scope へ置く時は Definition とその transitive dependencies の両方を検査する。

Promotion は sibling 参照を開ける shortcut ではない。Product の `PriceBadge` を Checkout で使うなら所有者を LCA の Commerce へ移し、全利用箇所・依存 component・token/asset policy・公開 API を再検査する。AI の promotion は approval-gated な architecture change として提案 diff を示す。事前に委任された approval policy 以外では自動適用しない。

AvailabilityPolicy は `deny`/`allowOnly` の例外で、Scope rule を上書きして sibling dependency を許す手段にしない。順序は structural ownership → explicit deny → allowOnly → actor permission。Policy は ID 参照で保持し、rename に耐える。例外件数と理由を可視化し、増殖したら Scope 設計を見直す。Picker と AI の `get_available_components(scope)` は同じ evaluator を呼び、unavailable item は理由付きで検索できる。

## 8. Component Architecture

```text
Definition(id, name, ownerScope, visibility, availability)
├─ API: typed props / slots / bindings / emitted events / override rules
├─ Variant axes: size={small,medium,large}, state={default,loading,disabled}
├─ Base implementation: Layer tree / interactions / motions
└─ Variant deltas: stable node ID + allowed property paths
Instance(definitionRef, variantSelection, propValues, slotContent, overrides)
                 ↓ resolver + validation
             Resolved tree (cache only)
```

Scope は Definition に属する。Variant は API の有限な選択肢であり、Scope owner を変えない。組合せを全保存せず sparse delta + default + precedence を使い、矛盾する同一 path の override は error。Variant が node kind や native semantics を変える場合は target capability を各組合せで検査する。Instance は subtree を永続コピーしない。公開された slot/property/path 以外の override は拒否する。Definition dependency graph の cycle を拒否し、cache key は definition revision、selection、override hash、target/environment、token revision。変更が波及する instance のみ invalidate。Variant 軸が多くなる場合は状態・props・別 Definition へ分割する設計レビューを要求する。

## 9. Human / AI Architecture

```text
Pointer / Inspector / Command Palette → Human Harness ─┐
                                                        ├→ typed Intent → preflight → atomic Patch
Semantic Query / Command / Patch API → Agent Harness ────┘                 │
                                                              same Validator + Revision Store
```

Human の drag は `MoveLayerIntent` に変換する。AI は `get_document_summary`、`get_scope`、`get_available_components`、`get_subtree`、`get_dependencies`、`get_selection`、`get_recent_changes` と `create/move/update/instantiate` 等を使用する。両者とも Document Store を直接 mutate しない。`expectedRevision` と ID/path ごとの precondition により stale write を conflict として返す。複数 Agent Harness（Builder、Reviewer、Accessibility Auditor 等）は権限、retrieval budget、変更上限、承認条件、validation loop を別に持つ。Human Harness は snapping、default insertion、shortcut、表示設定を持つが、共通 policy を迂回できない。

## 10. Authoring Harness

Machine-readable policy は versioned Current Format の一部。`ArchitectureScopes`、Capability、ComponentAvailability、Token、Asset、Interaction、Naming、Structure、Accessibility、Defaults を含む。例: `absolutePositioning=forbidden`、`colors=tokenOnly`、`scopeDependencies=ancestorOnly`。Validator は rule ID、対象 ID/path、理由、修正候補を返す。Policy の変更も mutation/validation 対象であり、既存違反の report と明示的な migration/waiver が必要。Prompt には可読な投影を渡すだけで、prompt の文面を enforcement とみなさない。Policy 自体を過度に厳格化しないため、`error/warning/advisory` と scope 限定、期限付き waiver、監査を設計する。

## 11. Integration Harness

Authoring Harness が **hamii 内での作り方**を制御するのに対し、Integration Harness は **既存 product repo への写し方**を記述する。Repository Profile、architecture rules、component/token/routing/state/asset mappings、code modification policy、検証コマンド、所有者を含む。これは IR の field ではなく project/target ごとの integration profile。AI は repository を読み、contract と profile に沿って変更案を生成し、build/test/diff をレビュー可能にする。未知の mapping は推測を確定扱いにせず `Needs Resolution` とする。

```text
Authoring Harness → valid hamii UI      Agent Harness → actor authority/context
Integration Harness → valid repository adaptation (export time)
```

## 12. IR

IR は source syntax の mirror でなく、typed semantic nodes と別 domain graph の集合。`Portable UI Semantics → Platform Semantics → Framework Semantics → Native Escape Hatch` の階層を持つ。VerticalStack は SwiftUI VStack/Compose Column へ写せるが、`NavigationSplitView`、`UINavigationController`、`LazyColumn` は無理に統一しない。layout の `fill/intrinsic/fixed` は意図であり、target 毎の測定規則が違う。[SwiftUI layout](https://developer.apple.com/documentation/swiftui/laying-out-a-simple-view)、[UIKit Auto Layout](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/AutolayoutPG/)、[Compose layout](https://developer.android.com/develop/ui/compose/layouts/custom)。効果の順序は hit area/描画に影響するので必要な node で ordered effects を保持する。[SwiftUI modifiers](https://developer.apple.com/documentation/swiftui/configuring-views)、[Compose modifiers](https://developer.android.com/develop/ui/compose/modifiers)。

```json
{"id":"lay_cta","kind":"control.button","children":[],"content":{"binding":"user.cta","previewFallback":"Continue"},"layout":{"padding":{"token":"space.md"}},"native":{"intent":"systemButton"},"accessibility":{"label":"Continue"},"interactionRef":"int_cta"}
```

Typed node schema は許可 property、child cardinality、target lowering、validation を定義。未知 node/field は **read-only preserved extension** として round-trip 可能なら保持し、編集/preview/export は診断付きで制限する。Core が旧 format を読むこととは区別する。NativeComponent は opaque symbol/interface/preview artifact を持ち、内部 source は解析しない。

## 13. Capability Model

Capability key は `feature + property + target + target runtime version`。結果は `Exact`、`Portable`、`Target-specific`、`Approximate`、`Unsupported`、`External Integration Required`。`Exact` は宣言した semantic contract の一致で pixel 同一を意味しない。Approximate は loss report と明示選択が必要。Unsupported は preview/export を block。External Integration Required は contract 出力可、standalone 実行不可。Canvas/Picker/Validator/Target Plan/Generator/AI Query は同じ registry を参照する。

例: `layout.stack` は SwiftUI/UIKit/Compose で Portable、`navigation.toolbar` は target ごとの semantic rule、`asset.remoteImage` は Preview では supported でも production loader は External Integration Required としうる。UIKit の navigation bar は controller 管理なので rectangle の width/height として扱わない。[UINavigationController](https://developer.apple.com/documentation/uikit/uinavigationcontroller)。Capability table の実際の coverage は Spike 01–04 で確定する。

## 14. Interaction / State / Motion

UI-local state は typed, finite state machine とする。`collapsed --tap/setState--> expanded` のように Event、guard、Action、Transition を保存する。初期 event は tap、valueChanged、appear、後に doubleTap/longPress/hover/focus/drag を拡張。Action は setState、setVariant、setValue、navigate、present、dismiss、openURL、emitEvent の supported subset。Business action は `emitEvent` で product に渡す。Motion は transition から参照する別定義で、instant/tween/spring/keyframe と target override、Reduce Motion fallback を持つ。Preview と export で event trace/state result を比較する。

## 15. Asset Model

Image Layer は `assetRef` を持ち、Asset entity は type、source、contentHash、metadata、license/provenance を持つ。Repository asset は小さいものを Git、大きいものは Git LFS の条件を project policy で指定。LFS は repo には pointer を置き実体は別保存で、未導入の共同作業者は実体を得られないため preflight が必要。[GitHub LFS](https://docs.github.com/en/repositories/working-with-files/managing-large-files/collaboration-with-git-large-file-storage)。Remote は URL と policy のみ正本、cache は派生。Runtime-bound は binding metadata、System は symbol identity、Generated は生成 provenance と採用済み実体を持つ。Repository asset の object 名に SHA-256 を使い deduplicate/integrity verify するが、論理 Asset ID は別にして参照や metadata を安定させる。thumbnail、decoded bitmap、GPU texture、remote cache は Git に入れず eviction 可。Secret を含む URL の保存を policy で拒否する。

## 16. Token Architecture

Token は color、typography、spacing、radius、border、shadow、opacity、motion の typed graph。Primitive→Semantic alias、mode、target override を持つ。Cycle と型不一致を拒否。`color.blue.500 → color.action.primary` のように利用側は semantic token を推奨。Template は新規作成時に project へ snapshot instantiate し、`templateID/version` を provenance として残す。更新は three-way migration/merge、上書きしない。Production の `AppColors.brandAction` への対応は Integration Harness の mapping。Font/license/platform availability は target 検証対象。

## 17. App Surface

AppSurface は Page 上で ScreenDefinition を `rootRef` する実行可能な view。`target、device profile、orientation、environment、fixture、architectureScope、preview mode` を持つ。Device は viewport/scale/insets/OS、Environment は color scheme/locale/Dynamic Type/accessibility/theme。Screen の実体と device 表示を分離する。Surface の Canvas 座標は export 対象でない。Scope は Screen の effective Scope と矛盾させず、Surface の Scope 変更時に全 resource reference を再検証する。Design Mode は高速近似、Native Preview Mode は Host frame と入力転送、Full Validation は明示的な Simulator/Device build。Simulator.app window の Canvas 埋め込みに依存しない。

## 18. Native Preview Architecture

```text
Current IR + Fixture + Target/Environment
             │ validate / resolve / lower
             ▼
Target Plan(version, sourceRevision, sourceMap, capability/loss report)
             │ snapshot or ordered patch/ack
             ▼
Persistent Preview Host in target runtime
  ├─ SwiftUI: precompiled node renderer + observable snapshot → SwiftUI update
  ├─ UIKit: view/controller factory + ID registry → main-thread patch/reconcile
  └─ Compose: precompiled Composables + observable state → recomposition (Later)
             │ frame + accessibility tree + event trace + diagnostics
             ▼
Canvas AppSurface (revision badge, stale indicator)
```

SwiftUI の任意 source を runtime interpretation しない。SwiftUI identity が変わる構造更新で state が失われ得るため、値 patch と subtree reconciliation を区別し reset diagnostic を出す。[Apple SwiftUI identity](https://developer.apple.com/videos/play/wwdc2021/10022/)。UIKit の controller containment/navigation は lifecycle を守る。[Apple UINavigationController](https://developer.apple.com/documentation/uikit/uinavigationcontroller)。Compose は IR patch を observable model に反映し、UI は recomposition する。[Google lifecycle](https://developer.android.com/develop/ui/compose/lifecycle)。Host protocol は `LoadSnapshot/ApplyPatch(baseRev,newRev)/SetEnvironment/SetFixture/InputEvent/Ack/Diagnostic`。欠番・再起動・schema mismatch は full snapshot と stale 表示。Transport、frame capture、state retention、p95 latency は Needs Prototype/Benchmark。Preview と production の parity は bounds、a11y tree、interaction trace、visual の別指標で評価する。

## 19. Build Boundary Matrix

| Class | 例 | Host 更新 | ユーザー表示 |
|---|---|---|---|
| Instant Patch | 対応済み layout/style/text/token/fixture/state/basic motion | snapshot data patch、compile なし | 更新 revision/latency |
| Runtime Reconciliation | 子の追加/移動、variant structure、navigation configuration | subtree/controller rebuild、compile なし | state reset の可能性 |
| Component Build | custom native source、Preview adapter、新 node factory | artifact build と host 再起動の可能性 | 明示 build required |
| Full Build | dependency、entitlement、SDK、project/host integration | host/app build-install | 明示 full validation |

「Component Build」が full relink/install より軽い保証はない。これは Spike で境界を定める。Supported navigation でも target runtime が再構築を要する場合は Runtime Reconciliation に分類する。GUI edit は build を暗黙に開始しない。

## 20. Persistence Architecture

Git **repository** の Current Canonical Format が正本で、GitHub は remote sharing/review。GitHub service 自体を唯一の storage としない。offline clone でも編集可能。推奨 layout:

```text
hamii.json                      # document ID, format versions, references
scopes/<id>.json
pages/<id>/page.json
pages/<id>/layers/<id>.json     # initial granularity; benchmark で shard 調整
components/<id>/definition.json
components/<id>/variants/<id>.json
tokens/<id>.json  interactions/<id>.json  motions/<id>.json
fixtures/<id>.json  assets/catalog/<id>.json  assets/objects/sha256/...
harness/authoring.json  integration/<profile-id>.json
```

Stable ID を file identity とし、name/rename を path に使わない。Canonical schema は domain serialization であり Swift struct/SQLite schema と独立。JSON canonical ordering/formatting、single entity writer、reference validation、atomic staged save、crash recovery journal を規定する。Git に partial transaction が残らないよう multi-file save は temporary staging + manifest revision の切替と recovery を検証する。`NSDocument` は file/package lifecycle の候補だが Git repo directory との integration は Spike で決める。[NSDocument](https://developer.apple.com/documentation/appkit/nsdocument/)。外部 editor による file 変更は再parse・conflict check を通し、直接 Core memory を変更しない。

## 21. Local Query Architecture

```text
Git files → changed-entity detector → Current Format parser → Current Model
                                           ↓
                        dependency invalidation → SQLite index
                                           ↓
                  Scope/Component/Layer/Usage/FTS Query API → Human/AI
```

Index は component usage、scope closure、token/asset usage、dependency graph、layer locator、FTS を持つ。`canonical commit/tree hash + working-tree fingerprint + index schema version` で鮮度を判定し、外部 pull や未commit変更を検知する。Query result は source revision を返す。破損・schema mismatch・drift は index を削除して rebuild。SQLite migration history を維持しない。大規模 document の incremental reindex と full rebuild は Benchmark が必要。

## 22. Migration Architecture

```text
Old Git tree ──> Migration Coordinator ──> historical parser vN
                      │                         ↓
                      └──── migrator N→N+1 → ... → Current Format
                                                   │ validate
                                                   ▼
                                           Current Format parser → Core
```

`hamii-core` と `hamii-format-current` は旧 schema に依存しない。`hamii-migrations` の別 package/target が historical types、edge migrators、registry、report を持つ。App は format header を読んだ時だけ coordinator を呼び、Core へ old model を渡さない。Migration は Lossless / Lossless with normalization / Potentially lossy / Manual に分類。未知 future format は read-only/unsupported とし downgrade を推測しない。歴史的 migrator は通常の AI coding context から除外するが、必要な変更時は参照可能にする。

## 23. Destructive Migration UX

Preflight は git status、format path、assets/LFS availability、disk space、reference graph、必要な manual decisions を調べる。Dirty working tree なら勝手に進めず commit/snapshot/cancel を提示する。Migration は temporary worktree/branch で実行し、元 tree を保持する。各 edge 後に schema/ID/reference/scope/component/token/asset/interaction/harness を検証し、最後に fresh index rebuild。Ambiguous literal color→token は自動選択せず `Requires Resolution` として候補・影響件数・diff を表示する。Unsupported legacy component は blocking report。Human review 後に migration commit を作り、必要なら PR として共有。異なる format version の branch 同士は先に同じ version に揃え、それから merge。Git worktree は同一 repository の別 working tree を提供する。[Git worktree](https://git-scm.com/docs/git-worktree)。

## 24. Versioning

| Version | Purpose | Compatibility |
|---|---|---|
| AppVersion | 配布 binary | document format と別 |
| DocumentFormatVersion | canonical graph syntax/semantics | migration graph |
| AuthoringHarnessFormatVersion | machine policy schema | 独立 migrator/validator |
| IntegrationProfileFormatVersion | repo mapping schema | 独立 migrator |
| TargetPlanProtocolVersion | Host との通信 | handshake、mismatch 拒否 |
| LocalIndexSchemaVersion | derived SQLite | drop/rebuild |

Format version は semantic breaking change の時だけ上げる。単なる内部 struct refactor では上げない。Cross-version merge は受け付けない。

## 25. Git Collaboration

MVP は通常の Git text merge、stable IDs、細分化 file、deterministic serialization を使う。`git pull` 後に変更 entity を検知、validate、index update。異なる property の同一 file 編集が text conflict になることはある。conflict UI は base/ours/theirs と ID/path を見せ、解決後に全 document validation。AI は repo の未 commit 変更を保持して patch を適用し、他人の変更を一括 rewrite しない。GitHub PR は review/承認の共有点で、リアルタイム同時編集 server は MVP 対象外。

## 26. Semantic Diff / Merge

将来の engine は `(entity ID, node ID, property path)` の base/ours/theirs 三者差分を作る。別 path の変更なら merge、同 path の異値、remove-vs-edit、move-vs-move、variant/policy の意味衝突は人間へ提示。Array の順序は stable child ID と position operation で扱い、index 番号だけを key にしない。Merge 後は scope/capability/reference/policy を再検証する。Patch log は Undo/Redo、autosave、preview 更新、semantic diff に再利用できるが、Git commit history と完全に同一ではない。MVP では semantic merge を自動有効化しない。

## 27. AI Context Architecture

Document summary→Scope→Page→Layer summary→subtree detail の段階的 retrieval。Selection、viewport、recent changes、available components、token/asset/dependency を on demand。Scope filter は利用できる resource の候補に絞り、unavailable の理由照会は明示 API にする。Screenshot は semantic context とは別に selected/viewport/native frame を必要時だけ取得。Query は index revision と source ID を返し、AI patch に expectedRevision を要求。Actor Harness は read/write/architecture-promotion 権限、context budget、変更数、validation loop を規定する。Context 減少と task success は Spike 13 で測定する。

## 28. Code Generation

Standalone generator は `Current IR → validated Target Plan → deterministic formatter/source files + manifest`。Supported subset の SwiftUI/UIKit を優先し、同じ入力/target version なら同じ出力を保証する。Source map、capability/loss report、component API、events/bindings/fixture-free stubs を同梱。Preview fixture の値を production default に混ぜない。任意 hand-edit の round-trip は契約外。生成 file の所有境界を manifest に記録する。

## 29. Product Integration

```text
hamii IR → Integration Contract (inputs, events, bindings, tokens, states, native/a11y intent)
          + Integration Harness (repo rules/mappings/verification)
          + Existing Repository
                     ↓ AI reads repo and proposes patch
             Product-native source → build/test/review
```

AI は MVVM/TCA/DI/router/image loader 等の既存 convention に適応する。hamii IR はそれらを知る必要がない。例 `ProfileHeader(name,avatarURL,editTapped)` と `color.text.primary` を contract に出し、repo の `ProfileViewModel` や `AppColors` への接続は Integration Harness と repo 調査で決める。Mapping が曖昧なら未解決を示す。Preview code と production code は syntax が違ってよい。意味的一致を contract と conformance で確認する。

## 30. macOS Module Architecture

```text
AppShell / HumanUI (Canvas, Inspector, Panels) ─┐
AIInterface / AgentHarness ───────────────────────┼→ AuthoringAPI
                                                  ▼
                                  MutationEngine → ValidationEngine
                                       │                  │
                                       ▼                  ▼
                              CurrentDomain/IR ← Scope/Component/Token/Asset/Interaction Engines
                                       │
                   ┌───────────────────┼──────────────────────────┐
                   ▼                   ▼                          ▼
             CurrentFormat       TargetLowering              QueryProjection
                   │               ├─ CanvasRenderer              │
             GitRepository         ├─ PreviewCoordinator → Host   LocalIndexer → SQLite
                                   └─ CodeGenerator
HistoricalFormat → Migrations → MigrationCoordinator → CurrentFormat
IntegrationContract → IntegrationLayer + Harness → AI/repository adapter
```

依存規則: Core は AppKit/SwiftUI/UIKit/SQLite/Git/AI/migrations に依存しない。Format は Core 型への adapter、Migration は Current Format を出力する。Query は Core の read projection。Canvas と Preview は Target Plan/resolve API の consumer。Integration Layer は Contract を読むが Core の mutation path に書き戻さない。SwiftUI は macOS shell、AppKit/CG/CA は Canvas。UIKit は iOS Host target。Metal は Canvas benchmark 後に検討。

## 31. MVP

**Must:** macOS app shell、Document/Page/Layer/Screen/Surface、Scope tree+validator、Text/Image/Button/Stack/Scroll、system Navigation/Toolbar の限定 subset、Definition/Variant/Instance、color/spacing/type token、asset refs、binding+fixture、tap→local state/emitEvent、basic motion、Authoring Harness、Human/AI 共通 mutation/query、Git Current Format、disposable SQLite index、SwiftUI Host と deterministic SwiftUI generation、integration contract の end-to-end demo。

**MVP gate:** Human または AI が同じ policy に従い UI を作り、対応編集で compile なしの SwiftUI Preview を更新し、generator と integration contract に渡せること。UIKit Host は Spike 後に MVP inclusion を決める。**Later:** Compose/CMP、任意 native code round-trip、複雑 motion timeline、real-time server、fully automatic semantic merge、全 historical migration 配布。UIKit は architectural target として初期 schema に含めるが、SwiftUI と同時に二つの Host を必須とすると MVP 検証が遅れる。UIKit runtime Spike が早期成功した場合のみ MVP gate に追加する。

## 32. Technical Spikes

優先順は `01 IR → 02 SwiftUI Host → 04 Patch → 05 Scope → 07 Harness → 08 Git → 09 Index → 10 Migration → 14 Integration`。UIKit(03)と Component Variant(06)は IR/Host の成立に並走。Destructive migration(11)、Asset(12)、AI Context(13)を実運用前に完了。各実験の hypothesis、fixture、計測、失敗条件は [spikes.md](spikes.md)。P0 の失敗は Supported Domain または Preview の約束を改訂する。

## 33. ADRs

[ADR-001〜030](architecture-decisions.md) は確定した設計判断の記録。未確定・未対応の技術選択だけを [`adr/`](../adr/) の個別ディレクトリに置く。`ADR.md` と必要な `SPIKE.md`、成果物を同居させる。Spike/実装で解決した項目は判断を docs または code に反映してから個別ディレクトリを削除する。目標は `.gitkeep` 以外 0 件。旧 18 ADR は今回の Scope/Git/Migration/Harness の追加により失効した。

## 34. Risks

| Risk | Impact | Likelihood | Mitigation / gate |
|---|---|---|---|
| IR が generic 過ぎる / framework 寄り過ぎる | 高 | 高 | cross-target conformance、target-specific layer、Spike 01/03 |
| Supported domain が狭過ぎる | 高 | 中 | 実 screen corpus、escape hatch、loss report |
| Capability/availability 例外が複雑化 | 中 | 高 | shared evaluator、例外数 dashboard、policy review |
| Variant explosion / scope promotion misuse | 中 | 高 | sparse variants、API review、approval gate |
| Preview と production の乖離 | 高 | 高 | shared Target Plan、a11y/event/visual parity tests |
| Host/Canvas 性能不足 | 高 | 中 | revision trace、viewport culling/LOD、p95 benchmark |
| AI context 増大 / repo 誤解 | 高 | 中 | scope retrieval、contract、reviewable integration diff |
| Git conflict / canonical instability | 高 | 中 | stable ID、file split、canonical serializer、version discipline |
| Migration 蓄積 / lossy 変換 | 高 | 中 | isolated edges、manual resolution、branch review |
| Asset 増大 / LFS 導入摩擦 | 中 | 中 | thresholds、content hash、preflight、cache separation |
| Index drift / corruption | 中 | 中 | source fingerprint、revision checks、drop/rebuild |
| Legacy code の Core/AI context 漏れ | 中 | 中 | package dependency gate、context filtering |
| Harness の硬直化 | 中 | 中 | severity、scoped waiver、usage review |

確率は設計時の相対評価であり実測ではない。Spike 後に更新する。

## 35. Open Questions

- **Needs Prototype:** iOS Simulator Host transport/frame/input、SwiftUI structure change の state identity、UIKit controller reconcile、custom component artifact/loading。
- **Needs Benchmark:** patch→frame p50/p95、10k/50k Canvas、component 1k instance、index rebuild、Git shard 粒度。
- **Needs Validation:** UI semantics の cross-framework loss threshold、a11y parity、acceptable policy waiver と promotion UX、LFS 閾値、fixture の privacy。
- **Unknown:** CMP iOS Host の別 artifact 統合方法、実 repo での integration AI 成功率。これらを先に固定しない。

## 36. Recommended Implementation Order

| Phase | Deliverable | Exit gate |
|---|---|---|
| 0 | corpus、IR vocabulary、capability contracts、Spike 01 | core node と loss を記述できる |
| 1 | Current Core/Format、scope、component、mutation/validator、Authoring Harness | Human/AI command が同じ違反で拒否される |
| 2 | SwiftUI Host、Patch protocol、minimal Canvas/Surface、generator | compile なし値更新、revision/diagnostic、parity sample |
| 3 | Git shards、query index、assets/fixtures、migration boundary | pull/reindex、dirty tree migration review、rebuild |
| 4 | Human editor、AI query/mutation、integration contract+AI demo | MVP end-to-end gate |
| 5 | UIKit Host、advanced system UI、Compose Android IR validation | target 差を capability と test で説明できる |
| 6 | CMP、semantic merge、expanded motion/custom integration | evidence に基づき個別採否 |

## Source Notes

外部事実の根拠は本文の一次資料と [Native platform research](../research/native-platforms.md)、[Preview research](../research/preview-runtime.md)。hamii の各 module/API/format は提案であり実装済みではない。Apple/Google/JetBrains/Git/GitHub の API と制限は実装時に対象 SDK/version で再確認する。
