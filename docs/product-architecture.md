> **Historical draft / superseded.** 現行設計は [Product & System Architecture](final-architecture.md)。この文書の persistence、preview、scope に関する方針は採用されていません。

# hamii: プロダクト定義と初期アーキテクチャ

> **旧案 / Superseded:** この文書は初回調査時点の案。Native Preview、MVP、persistence 等の現行設計は [Final Architecture](final-architecture.md) と [照合表](../research/design-reconciliation.md) を参照する。

状態: **初期設計案**（実装上の採否は [Technical Spikes](spikes.md) の結果で更新）。調査根拠は [既存製品](../research/existing-products.md) と [Native platform](../research/native-platforms.md) に記録する。以下の「決定」は v0.1 の実装方針であり、未検証の性能・変換精度を事実として扱わない。

## 1. Executive Summary

hamii は **native UI の意味を持つ layer tree を、人間の視覚編集と AI の構造編集が共有する macOS アプリ** とする。正本は versioned **hamii UI IR**。IR の共通核は stack、text、image、button、装飾、サイズ指定等の小さな subset に限定する。iOS/Android 差分は platform profile、framework 固有の構文は target extension として明示する。SwiftUI/Compose のコードは IR から生成する派生物であり、任意の手書きコードの完全再取込は目標にしない。

v0.1 は **SwiftUI first** の、静的な component/screen を作成・AI 編集・コピーし、iOS Simulator で照合する縦断体験を検証する。Compose は同じ IR からの限定変換を spike で検証してから製品化する。UIKit は宣言型 view tree との意味差が大きいため後段とする。CMP は Compose と API を多く共有しても、iOS 上の system control や platform integration まで SwiftUI と同等にはならない。[Compose Multiplatform overview](https://www.jetbrains.com/help/kotlin-multiplatform-dev/compose-multiplatform.html)

### 最重要の制約

`Design = Implementation` は **hamii-supported subset に限り、対象 platform・OS・フォント・コンテナ条件を指定して検証した場合の目標**。任意の SwiftUI/Kotlin、ビジネスロジック、UIKit imperative API、すべての platform の pixel 同一性は成立しない。対象 framework ごとの実装を捨てる universal DSL は作らない。

## 2. Product Definition

| 項目 | 定義 |
|---|---|
| 何か | native component の意味構造を編集・共有・export する visual UI workbench |
| 何ではないか | 任意の native code を GUI に復元する IDE、アプリ全体の logic builder、pixel 完全一致を約束する design tool |
| Target user | iOS/Android UI engineer、実装を意識する product designer、両者と作業する coding agent |
| Primary use cases | screen の構築、再利用 component の定義、target への code export、AI による局所修正、native preview と差分確認 |
| 価値 | 視覚編集・構造編集・export が同じ意味構造を参照し、デザインから実装への翻訳量を減らす |

製品の位置付けは **UI Design Tool と Visual Native IDE の間の UI workbench**。状態/イベントの interface は設計するが、API 接続・永続データ・任意のアプリ logic の visual programming は対象外。Figma が node と layout/property を公開し、Code Connect で code component へ橋をかけることは確認できるが、hamii は native mapping を最初からモデルに持つ。[Figma node](https://developers.figma.com/docs/rest-api/file-node-types/)、[Code Connect](https://developers.figma.com/docs/code-connect/)

## 3. Product Principles

1. **意味から描く**: Button は rectangle と text の組ではなく、action を受け取る control。
2. **人間と AI は同じ command path**: undo、validation、revision は共通。
3. **正本は編集可能な IR**: code と canvas image は派生物。
4. **共通化は意味が一致する範囲だけ**: 不一致は platform/framework 固有で明示。
5. **変換の損失を隠さない**: export は capability report と診断を返す。
6. **プレビューは対象実行系で検査**: canvas は高速編集用、native preview が fidelity 判定用。
7. **小さく問い合わせる**: AI は selection、summary、subtree、diff の順に取得。
8. **生成物は人が保守できる**: callback とデータ依存を外部 interface に出し、手書き logic を生成領域に閉じ込めない。

## 4. Conceptual Model

| Entity | 責務 / 同一性 |
|---|---|
| Document | 1 プロジェクトの正本。page index、component definitions、asset manifest、tokens、targets、schema version を所有。 |
| Page | 自由な整理領域。画面・feature 等の意味を強制しない。複数の root Layer を持てる。 |
| Layer | Page 内の編集単位。stable ID、kind、parent、ordered children、layout、style、content、target mapping を持つ。 |
| Component Definition | 再利用可能な layer subtree と公開 interface（props、slots、events、state previews）。Document scope。 |
| Component Instance | 定義 ID を参照する Layer。値と許可された override のみ持つ。 |
| Asset | content hash で参照する画像/フォント等。license、用途、target name を管理。 |
| Token | 型付き design value。mode（light/dark 等）と target mapping を持つ。 |
| Target | framework、platform、minimum OS/API、device preview config、export policy の組。Document に複数設定可。 |

Page は画面と同義にしない。**export root** を Page 内の任意 Layer/Component として明示する。これで feature 単位の Page から複数 screen を export できる。

## 5. Domain Model

```text
Document ─┬─ pages[] ─ Page ─ roots[] ─ Layer ─ children[] ─ Layer
          ├─ components[id] ─ Definition ─ root: Layer
          ├─ assets[hash]
          ├─ tokens[id] ─ modes / target overrides
          ├─ targets[id] ─ framework / platform / version / preview device
          └─ schemaVersion / revision

Layer ── token references ──> Token
Layer ── asset references ──> Asset
Instance Layer ── definitionId ──> Definition
ExportRoot ── targetId ──> Target
```

所有関係は Page→Layer の木。component、asset、token、target への参照は別の有向グラフとし、循環する component dependency は禁止。Layer ID は移動・rename 後も不変、path は人間向けの可変表示名。ordering は親の `childIds` 配列で一意に表す。deleted ID は再利用しない。

## 6. Source of Truth Decision

評価: ◎ 適合、○ 条件付き、△ 弱い、× 不適合。これは設計上の評価であり、製品の実測値ではない。

| 観点 | Native source | Swift/Kotlin AST | 純粋な共通 IR | 階層化 IR + target extension |
|---|---:|---:|---:|---:|
| GUI 編集 | △ | △ | ◎ | ◎ |
| native code 生成 | ◎ | ○ | ○ | ○ |
| 任意 code 往復 | △ | ○ | × | △ |
| SwiftUI↔Compose | × | △ | ○ | ○ |
| AI 局所編集 | △ | △ | ◎ | ◎ |
| Diff / Git | ○ | △ | ◎ | ◎ |
| schema migration | △ | △ | ○ | ○ |
| native debugging | ◎ | ○ | △ | ○ |

**採用: 階層化 IR を唯一の編集正本**。hybrid は「source code と IR の二重正本」ではなく、共通 IR 内に target 固有の**型付き拡張 node**を持つ方式。AST は import/export の境界で使用し、document 本体には保存しない。任意コードを source of truth とすると GUI 操作がプログラム変換となり、closure や制御フローを一般に安全編集できない。純粋共通 IR は target 固有の挙動を落とす。生成 source は deterministic にして diff と debugging を容易にする。

## 7. UI Intermediate Representation

```yaml
schema: 1
id: layer_01J...           # stable, opaque
kind: control.button       # semantic kind; container.stack / content.text / instance
name: Continue
parentId: layer_root
childIds: []                # order is semantic
layout:
  width: {mode: fill}       # fixed | intrinsic | fill | constrained
  height: {mode: intrinsic}
  padding: {top: 12, right: 16, bottom: 12, left: 16}
style:
  foreground: {token: color.action.foreground}
  background: {token: color.action.background}
content:
  label: {literal: Continue} # later: localization key or prop reference
component: null
native:
  intent: systemButton      # semantic requirement
  overrides: {}             # target-scoped typed fields, no opaque universal CSS
interaction:
  event: onActivate         # export interface, not implementation closure
  previewState: enabled
```

IR node は `identity / hierarchy / layout / style / content / component / native mapping / interaction` を明示する。field の absent と default は区別する。寸法は IR の論理単位を使い、iOS point / Android dp への写像を target profile で明示する。同じ数値が同じ pixel を意味するとは扱わず、scale、font metric、system control は target preview で評価する。未知 field は migration で保持し、未知 node kind は read-only placeholder とする。IR は semantic intent と target realization を別に持ち、生成器は capability matrix で「unsupported / approximated / exact-for-subset」を報告する。

### 抽象化レベル

| レベル | 例 | 方針 |
|---|---|---|
| Universal | linear stack、text、image、padding、fixed/intrinsic size | 両系で意味が近い最小核。 |
| Platform | iOS safe area、Android window insets | platform ごとの型付き profile。 |
| Framework | SwiftUI `List`、UIKit constraint、Compose `LazyColumn` | target 専用 node/extension。別 target へは明示的な fallback。 |
| Escape hatch | custom native component reference と prop schema | opaque 実装として canvas に preview provider / placeholder。跨ぐ変換は拒否または置換要。 |

「VStack = Column」は children の縦配列という意味だけに限定する。spacing default、weight、alignment、intrinsic measurement、scroll 等は別途 mapping を規定する。modifier の順序は SwiftUI/Compose の描画・hit area に効くため、IR の style を無順序の bag にしない。必要な場合は **ordered effect pipeline** として保持する。[SwiftUI layout](https://developer.apple.com/documentation/swiftui/layout)、[Compose modifiers](https://developer.android.com/develop/ui/compose/modifiers)

## 8. Framework Mapping

記号: **E** = hamii subset の意味が対応、**P** = platform 差分を伴う部分対応、**N** = 共通表現なし。E は pixel 同一の保証ではない。

| hamii concept | SwiftUI | UIKit | Jetpack Compose | CMP |
|---|---|---|---|---|
| vertical/horizontal stack | E `VStack/HStack` | P `UIStackView` | E `Column/Row` | E `Column/Row` |
| overlay stack | E `ZStack` | P subviews/z order | E `Box` | E `Box` |
| text/image | E `Text/Image` | P `UILabel/UIImageView` | E `Text/Image` | E `Text/Image` |
| button + callback interface | E `Button(action:)` | P `UIButton` target/action | E `Button(onClick)` | E `Button(onClick)` |
| fixed/intrinsic/fill | P frame/priority | P constraints/CHCR | P modifier/weight | P modifier/weight |
| lazy list | P `LazyVStack/List` | P `UICollectionView` | P `LazyColumn` | P `LazyColumn` |
| safe area/insets | P safeArea APIs | P layout guides | P window insets | P platform dependent |
| navigation | P `NavigationStack` | P `UINavigationController` | P navigation library | P navigation library |
| native system control style | P OS dependent | P OS dependent | P Material/theme dependent | P platform dependent |
| custom native view | N reference | N reference | N reference | N reference |

UIKit は macOS editor の実装技術ではなく **iOS export target**。CMP は Compose API を共有する target family だが、Android の system integration や Material behavior をそのまま共有すると仮定しない。[UIKit](https://developer.apple.com/documentation/uikit)、[CMP](https://www.jetbrains.com/help/kotlin-multiplatform-dev/compose-multiplatform.html)

## 9. Round-trip Strategy

| 経路 | 判定 | 条件 |
|---|---|---|
| GUI→IR→GUI | Lossless | schema が理解する field と asset を保持。 |
| IR→generated SwiftUI→IR | Mostly Lossless | 生成物に stable ID/manifest を付け、**hamii-owned generated region** を未編集で再取込する場合。AST 解析による一般的復元ではない。 |
| supported SwiftUI literal subset→IR | Mostly Lossless を目標 | 明示 whitelist の構文に限り parser prototype で検証。未対応 modifier は import 診断。 |
| arbitrary SwiftUI/Kotlin→IR | Lossy/Unsupported | 関数呼出し、generic、closure、条件分岐、custom layout、async 等は一般には解釈不能。 |
| IR→SwiftUI→Compose | P/Lossy | IR の共通核から両者を生成する。SwiftUI source を中間正本にしない。 |

| 機能 | 扱い |
|---|---|
| arbitrary code / custom View / UIKit imperative | custom component ref と preview adapter。実装本体は外部 repository。 |
| modifier | 対応する型付き effect のみ往復。未知 modifier は source import を拒否/opaque。 |
| closure / async logic | event interface と dependency stub まで生成。logic は app 側で接続。 |
| state / binding / Compose state | component prop、read/write binding contract、preview fixture を表現。state owner の runtime logic は app 側。 |
| animation / gesture / navigation | v0.1 外。後に限定 interaction schema。framework 固有挙動は target extension。 |
| environment | theme、locale、dynamic type 等の preview config と依存宣言。任意 environment key は escape hatch。 |

生成 code を手修正した後の同期は、まず **生成領域の再生成 + 外部 wrapper** を推奨。手修正を自動で取り込むと宣伝しない。source importer は独立研究課題。IR↔IR の canonical serialization / parse equality を lossless の検証基準とする。

### Layout semantics contract

Figma Auto Layout は `FIXED/HUG/FILL`、padding、alignment 等を node 属性に持つ。[Figma node types](https://developers.figma.com/docs/rest-api/file-node-types/) SwiftUI は親が提案サイズを子へ渡し、子が応答する。[Apple layout](https://developer.apple.com/documentation/swiftui/laying-out-a-simple-view) UIKit は制約を解く。[Auto Layout Guide](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/AutolayoutPG/) Compose は親制約の下で子を測定する。[Compose custom layouts](https://developer.android.com/develop/ui/compose/layouts/custom) よって hamii は Figma の property 名をそのまま相互変換の意味契約にしない。

| hamii 指定 | 共通意味 | target 変換上の注意 |
|---|---|---|
| `fixed(value)` width/height | 指定した論理寸法 | Dynamic Type で clip する危険を警告。 |
| `intrinsic` (hug) | content を収める最小必要寸法 | font metric と control intrinsic size は target 実測。 |
| `fill` | 親から許可された領域を占有 | SwiftUI priority、UIKit constraint、Compose weight/fill の差を検査。 |
| `constrained(min,max,preferred)` | 上下限を課す | 矛盾した制約は IR validation error。 |
| padding / spacing | content 内周 / sibling 間隔 | effect 順序と target default spacing を明示。default を暗黙採用しない。 |
| alignment | 軸ごとの child alignment | baseline は text metrics に依存。 |
| aspect ratio | 幅高の比率 | fit/fill と clip を別 field にする。 |
| overlay | 重ね合わせと z-order | hit testing 順序を保持。 |
| absolute | 指定 container 内の位置 | canvas の自由配置専用。responsive export は warning。 |

Layout evaluator は canvas の近似 geometry を作るが、**native framework の layout engine を置き換える仕様源にはしない**。IR は constraint intent を持ち、target adapter が実現する。canvas と native の結果が diverge した場合は target preview に warning を出し、silent fallback を禁止する。scroll と lazy layout、safe area は generic stack の属性に押し込まず専用 container/target profile とする。

### Native Component contract

Layer は配置された個々の UI object。Component Definition は再利用される UI の公開 interface と内部 tree。Instance は定義参照と prop values、variant selection、許可された overrides を持つ Layer。definition 内の子に対する無制限 override は構造破壊につながるため、変更可能箇所を prop/slot に公開する。variants は名前付き prop preset と preview state の組とし、別の複製 tree を正本にしない。slots は型付き child insertion point、events は callback signature、bindings は read/write value contract、state は app-owned と preview fixture を分ける。定義変更時は instance の公開 interface 互換性を検証する。custom native component は target 別 symbol/prop/event schema/preview provider/依存 package を持つ opaque reference で、hamii は実装本体を編集しない。

### Interaction boundary

`hover/pressed/focused/disabled/selected/loading/error` は **preview state または外部入力 prop**として扱う。`onActivate/onChange` 等は event signature で、動作本体はアプリ側。navigation/modal/transition は将来、`intent` と target adapter に分離し、画面遷移グラフや非同期 business logic の編集を v0.1 に含めない。状態ごとの表示差は variant preset で確認できるが、runtime state machine を hamii が所有するとは限らない。Compose が state hoisting を推奨することも、この境界を支持する。[State and Jetpack Compose](https://developer.android.com/develop/ui/compose/state)

## 10. Canvas Architecture

**採用案**: SwiftUI/AppKit の editor shell、AppKit `NSView` の viewport と input、Core Graphics/Core Animation による可視範囲の描画・overlay。Metal は profiling で必要と判定したときだけ検討。各 layer を live SwiftUI/native view として canvas に置かない。iOS の UIKit/SwiftUI は macOS 内でそのまま実行できず、Android runtime も同様。native preview は別の target build/simulator/emulator 経路とする。

```text
IR snapshot → layout approximation/cache → display list → tiled viewport draw
           ↘ spatial index (bounds) → hit test / marquee / selection
input events → edit command → validate → revision → invalidated subtree/tile
native preview adapter ← generated target project ← same IR revision
```

Pan/zoom は viewport transform に限定し、IR の座標を書き換えない。selection box、guide、handles は editor overlay。drag/resize は layout property を変える command として表現し、stack child を座標移動させる場合は reorder/padding/align へ変換する。できない場合は操作を拒否し、安易な absolute position を挿入しない。空間 index と可視 tile、dirty subtree により thousands of layers を狙うが、性能は spike で測る。native controls の canvas 表示は approximation badge を出す。

## 11. macOS Architecture

```text
SwiftUI App Shell / document windows / panels
  ├─ Editor Coordinator (selection, undo, commands)
  ├─ AppKit Canvas (input, viewport, draw, overlays)
  ├─ Document Engine ─ IR model / validation / dependency graph
  ├─ Query + Patch Engine ─ AI, GUI and automation use same transactions
  ├─ Persistence ─ package files, migration, recovery
  ├─ Export ─ SwiftUI / later Compose and UIKit backends
  └─ Native Preview Adapter ─ generated harness + simulator/emulator + diagnostics
```

Swift は core model と generators。SwiftUI は window/panels/inspector。AppKit は精密 input と canvas viewport。Core Graphics は vector/text drawing、Core Animation は compositing/overlay が適合する候補。Metal は大量 layer や effects で CPU/GPU 実測が必要になれば導入。UIKit は生成先のみ。境界は `DocumentSnapshot`, `EditCommand`, `Query`, `ExportBundle`, `PreviewArtifact` の versioned contracts とし、generator が editor の mutable state に直接依存しない。外部 compiler/simulator は process boundary で呼ぶ。Apple の Xcode preview は SwiftUI/UIKit/AppKit を対象とする。[Xcode previews](https://developer.apple.com/documentation/xcode/adding-previews-to-your-interface-files)

## 12. AI Architecture

AI client は editor process の **local authenticated interface** から、GUI と同じ query/command service にアクセスする。MCP は外側の adapter 候補。内部 command schema は transport と独立させる。AI には任意 filesystem mutation を直接許さず、revision を指定する atomic patch を実行する。

```json
{"op":"set","id":"layer_42","field":"layout.padding.top","value":16,
 "expectedRevision":127,"requestId":"ai-73"}
```

Query は `documentSummary`, `pageSummary`, `layerSummary(ids)`, `subtree(id, depth, fields)`, `ancestors(id)`, `dependents(id)`, `viewport(bounds)`, `selection`, `changesSince(revision)`。summary は name/kind/child count/warnings/target status を主とし、style 全量を含めない。`fields` projection、pagination、depth limit、token/byte budget、stable ID、revision cursor を標準化する。path は検索用で patch の識別子にしない。visual context は選択 subtree の crop と target preview artifact を明示要求した場合だけ渡す。`changesSince` は revision と tombstone を含む。古い revision の patch は conflict と現在値を返し、無言で上書きしない。GUI と AI の連続操作は同一 undo log に一つの transaction として入る。

`copyAs(target, rootId)` は source 文字列だけでなく `ExportBundle {sourceFiles, imports, assets, tokenDefinitions, componentDependencies, integrationSteps, diagnostics, capabilityReport}` を返す。小さな self-contained component は text clipboard。依存が複数ある場合は zip/package と manifest を優先し、「貼り付けるだけ」で完成するかを UI に示す。

Command の最小集合は `insert`, `set`, `unset`, `move`, `delete`, `createDefinition`, `instantiate`, `setInstanceProp`。`move` は oldParent/newParent/index と期待 revision を含め、cycle・slot 型・target capability を一括検査する。patch response は `newRevision`, `appliedIds`, `inversePatch`, `diagnostics`。query response は `revision`, `result`, `truncated`, `nextCursor`。AI が巨大な結果を要求しても上限を超えた分は cursor で取得させる。tool の削除操作は undo 可能な soft delete transaction とし、参照中の component definition 削除は診断付きで拒否する。

### Generation pipeline

`IR snapshot → schema validation → dependency closure → target capability check → target lowering → source formatting → buildable ExportBundle → optional native build`。target lowering は IR を直接文字列連結せず、target ごとの typed code model へ落とす。各生成 file に generator version・IR revision・source layer ID の対応 manifest を付ける。diagnostic は `nodeId`, `fieldPath`, `target`, `severity`, `fallback` を持つ。lossy fallback はユーザーが明示承認した export policy の場合だけ実行する。callback は stub body に業務 logic を書かず、外部から渡す public interface にする。

## 13. File Format

`.hamii` は macOS package directory とし、v0.1 は **canonical JSON files + content-addressed assets** を採用。Sketch が page 別 JSON を ZIP に収納する形式は外部読取の参考になるが、hamii は Git diff を優先するため ZIP を正本にしない。[Sketch file format](https://developer.sketch.com/file-format/)

```text
MyApp.hamii/
  manifest.json             # schema, document ID, target list, page order
  pages/<page-id>.json      # root IDs and owned layer records
  components/<id>.json
  tokens.json
  assets/<sha256>.<ext>
  assets/index.json
  .recovery/                 # app-managed, Git ignore 対象
```

JSON は stable key order、UTF-8、数値正規化、ID order を規定する。autosave transaction は (1) 変更 file の新旧版と操作 manifest を `.recovery/<txid>/` に準備、(2) 内容と参照整合性を検証、(3) 新 file を順次 atomic replace、(4) document revision を `manifest.json` の atomic replace で commit、(5) recovery を掃除する。再起動時に commit 前なら旧版へ rollback、commit 後なら新版へ redo する。実装では file/directory sync と cloud sync の挙動を S07 で検証する。assets は hash 参照で重複排除。schemaVersion ごとに順次 migration、旧 schema の read-only open を用意する。外部編集時は on-disk revision mismatch を検出し、保留/再読込/merge の選択肢を出す。大規模 document で JSON 書換・startup が詰まった場合に SQLite index/cache を**派生データ**として追加し、正本二重化を避ける。document package を `NSDocument`/SwiftUI `FileDocument` のどちらに載せるかは spike で確定。[Apple NSDocument](https://developer.apple.com/documentation/appkit/nsdocument)、[FileWrapper](https://developer.apple.com/documentation/foundation/filewrapper)

## 14. UX / Editor Structure

```text
Top: target / device / appearance / preview revision / Export
Left: Pages, Layers tree, Components, Assets
Center: infinite canvas + target-sized preview frames + semantic overlays
Right: Inspector (Meaning, Layout, Style, Props/Events, Target mapping, warnings)
Bottom: AI conversation + proposed patch diff + apply/undo + diagnostics
```

Inspector は「Button」「Stack」等の意味と target capability を最初に示す。layer を drag したとき、再配置の意味（reorder、spacing、absolute）を feedback に表示。Canvas と native preview を split view で比較し、対象 OS/device/font/dynamic type を固定した状態を表示する。AI 提案は実行前に affected IDs と field diff を見せ、ユーザーが undo できる。Page の用途は強制しない。

## 15. Core User Flows

| Flow | 最小の操作と完了条件 |
|---|---|
| A 新規 Document | New→target preset/OS→`.hamii` package 作成→空 Page。target は後から追加可能。 |
| B Canvas で UI | palette から semantic Stack/Text/Button→drop target に挿入→layout inspector→canvas と target preview で確認。 |
| C Layer 編集 | selection→property edit/drag→typed command→validation→同 revision の tree/canvas 更新→undo。 |
| D Component 化 | subtree 選択→props/slots/event 公開→Definition 作成→元 node を instance に置換→依存循環検査。 |
| E AI 生成 | target と選択 context→AI が summary/subtree query→patch 提案→diff 確認→atomic apply→preview。 |
| F AI 修正 | selection/viewport/changelog 取得→expectedRevision patch→conflict 時 re-query→apply/undo。 |
| G SwiftUI Copy | export root→SwiftUI capability check→bundle/diagnostics→clipboard or files→Xcode build/preview。 |
| H Compose Copy | 同じ IR root→Android target profile→unsupported 差分表示→bundle→Android Studio build/preview。v0.1 では spike のみ。 |

## 16. Technical Risks

| Risk | Impact | Reason | Mitigation | Needs Prototype? |
|---|---|---|---|---|
| 任意 source round trip の期待 | 高 | closure、制御フロー、custom API を静的に一般復元できない | supported subset と明示、generated region manifest | Yes |
| cross-framework の意味差 | 高 | sizing、system controls、navigation が異なる | capability matrix と target extension | Yes |
| canvas/native fidelity | 高 | native runtime/font/layout engine が異なる | native preview を判定基準、差分測定 | Yes |
| thousands of layers | 中高 | text layout と hit test が重い | culling、cache、spatial index | Yes |
| arbitrary custom component | 高 | preview と export の依存が外部 | typed reference、preview adapter、opaque 表示 | Yes |
| AI context の肥大 | 高 | subtree 全送信と画像反復 | summary/projection/diff/budget | Yes |
| concurrent GUI/AI 編集競合 | 中高 | stale revision で上書き | optimistic concurrency と atomic transaction | Yes |
| package 保存破損 | 高 | 複数 JSON の更新が途中停止 | journal、atomic replace、recovery | Yes |
| component dependency 循環 | 中 | recursive export/preview | graph validation | No |
| token の platform 差 | 中 | font/shadow/motion の描画差 | target values と diagnostic | Yes |
| generated code 保守性 | 高 | 再生成で手修正を壊す | generated files 分離、public props/events | Yes |
| UIKit export 複雑化 | 中高 | imperative lifecycle と Auto Layout | later、専用 backend | Yes |
| simulator/emulator toolchain | 中 | Xcode/Android SDK 依存と起動時間 | adapter process、cache、環境検出 | Yes |
| accessibility 欠落 | 高 | 見た目だけで意味不足 | semantic role、label、focus を IR に必須化 | Yes |

## 17. Prototype Experiments

詳細な手順・評価基準は [spikes.md](spikes.md)。優先順は **IR→SwiftUI build/preview、fidelity、AI patch、canvas 1k、Compose mapping、source import**。外部 toolchain が必要な spike は `Needs Validation` のまま進め、数値目標は製品要件の仮置きとして結果に応じて改訂する。

## 18. MVP v0.1

**Must**: macOS document、Page と semantic layer tree、stack/text/image/button、fixed/intrinsic/fill の限定 layout、color/typography/spacing token、basic component definition/instance（props は text/color 程度）、selection/inspector/undo、typed query/patch API、SwiftUI export bundle、iOS Simulator screenshot comparison、loss report、保存と recovery。代表的 2 screen と 1 reusable component を GUI と AI の両方で編集して export/build する。

**Later**: Compose 製品向け export（spike は先行）、UIKit、CMP、任意 source import、lazy lists、navigation、animation、gestures、stateful logic、collaboration、Metal canvas、外部 design tool import。v0.1 で `Copy as Compose/UIKit/CMP` を有効にするなら、それぞれの build と fidelity gate を通過した subset に限る。未達なら UI に提供しない。

MVP の成功は機能数でなく、(1) GUI/AI が同じ revision を編集し undo できる、(2) export が target build に成功する、(3) supported subset の screenshot 差分と diagnostics が許容範囲、(4) 依存付き copy の導入手順が再現可能、で判定する。

## 19. Architecture Decision Records

判断の Context、Options、Reason、Trade-offs、Revisit When を明示した記録は [architecture-decisions.md](architecture-decisions.md) を正本とする。

| ID / Decision | Context / Options | Chosen Approach / Reason | Trade-offs / Revisit When |
|---|---|---|---|
| ADR-001 Source of Truth | code / AST / IR / hybrid | versioned IR。GUI/AI が局所編集でき、target へ複数 export 可能。 | 任意 code の往復を捨てる。source importer の subset が実証されたら再検討。 |
| ADR-002 IR | universal DSL / framework-only / layered | universal kernel + platform/framework typed extensions。意味の共通部だけ再利用。 | schema と capability matrix が増える。target が増えた際の拡張負荷で再検討。 |
| ADR-003 Canvas Renderer | live native / web / custom / Metal | AppKit viewport + CG/CA の custom canvas、native preview は別。macOS 上で全 target を live 描画できない。 | 近似が必要。性能 spike で不足なら Metal。 |
| ADR-004 Persistence | monolithic JSON / SQLite / ZIP / package | page/component 別 canonical JSON の `.hamii` package。Git diff と外部読取を優先。 | 複数 file の crash consistency 対策が必要。大規模測定で SQLite cache を検討。 |
| ADR-005 Code Generation | clipboard text / bundle / source sync | deterministic per-target bundle + dependency manifest。buildability と依存を示す。 | 一行 copy UX は限定的。export integration test 失敗時に backend を見直す。 |
| ADR-006 AI Interface | raw document JSON / direct model access / query-patch | projected query + optimistic patch + revision diff。小 context と GUI 同等の validation。 | API が複雑。AI task benchmark で見直す。 |
| ADR-007 Native Preview | canvas only / embedded runtime / external target build | external simulator/emulator adapter。実装結果を対象 runtime で評価。 | 遅く toolchain 依存。preview latency 測定で cache/remote を再検討。 |

## 20. Open Questions

| 状態 | 問い / 決めるための証拠 |
|---|---|
| Needs Prototype | SwiftUI 生成物の限定 parser import がどの程度安全にできるか。unsupported modifier の診断が使えるか。 |
| Needs Benchmark | 1k/10k layer canvas の描画、hit test、save、AI query latency。 |
| Needs Validation | 対象 iOS/Android OS version、dynamic type、font availability、device matrix と fidelity 許容値。 |
| Unknown | 既存 native project の custom component を hamii にどう登録し、preview binary を安全に実行するか。 |
| Needs Prototype | Compose/CMP で component tree と target platform 差分をどこまで共通 export できるか。 |
| Needs Validation | `.hamii` package の source control 利用者と cloud sync 利用者の比率。 |
| Needs Validation | AI の primary client が local agent、IDE plugin、MCP のどれか。内部 service は独立させる。 |
| Unknown | UIKit export に要求される画面タイプと iOS minimum version。 |

## Visual fidelity の受入境界

「同じ」と呼べるのは、固定 viewport と同一 content/font/assets/theme で、**hamii が所有する layout geometry と指定した tokens**が target runtime で許容差に入る場合。system control の外観、font rasterization、dynamic type、accessibility size、OS version、Android OEM、safe area、gesture/scroll physics は target 依存であり、canvas 単独で pixel perfect を保証しない。比較は target/device/OS/locale/color scheme/content size を記録した screenshot と geometry metadata で行う。アクセシビリティは見た目とは別の acceptance gate（label、role、focus、contrast、touch size）とする。[Apple Dynamic Type](https://developer.apple.com/documentation/uikit/scaling-fonts-automatically)、[Android accessibility](https://developer.android.com/guide/topics/ui/accessibility)

## Tokens と実装接続

Document token は color、typography、spacing、radius、border、opacity を v0.1 の型として採用。shadow と motion は schema slot を予約し Later。token は `semanticId + modes + optional target override`。SwiftUI は `Color`/`Font` 等の生成定義、UIKit は `UIColor`/`UIFont` 等、Compose は `Color`/`TextStyle`/`Dp` 等へ出力し、同名でも実装値が一致しない場合は target override を要求する。asset は hash と target filename の manifest を付ける。callback は public closure/lambda interface、state は app-owned input と preview fixture を生成する。生成物に imports、target minimum、依存 component、asset 配置、build 手順を含める。
