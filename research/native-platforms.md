# Native UI と macOS 基盤の一次資料調査

調査日: 2026-09-26。事実は各社の公式資料に限定し、hamii に関する提案は「設計上の推論」と明記する。引用は判断に必要な短い原文のみとする。製品・SDK のバージョンに依存する仕様は実装時に再確認する。

## 1. Jetpack Compose のレイアウトと状態

### 検証できた事実

- Compose の `Column`、`Row`、`Box` はそれぞれ縦配置、横配置、重ね合わせの基本要素である。公式説明では「Use `Column` to place items vertically on the screen.」とある。`Column` / `Row` は配置と整列を指定でき、`Box` は重ね合わせを扱う。[Compose layout basics](https://developer.android.com/develop/ui/compose/layouts/basics)
- Compose のレイアウトは親から子にサイズ制約を渡して測定し、測定・サイズ決定・配置を行う。カスタムレイアウトでも同一の子を何度も測定できない。公式資料の表現は「Compose UI does not permit multi-pass measurement.」である。[Custom layouts](https://developer.android.com/develop/ui/compose/layouts/custom)
- Modifier の順序は表示だけでなくクリック対象領域などの動作を変える。`clickable().padding()` と `padding().clickable()` は同値ではない。公式資料は「The order of modifier functions is significant.」と明示する。[Compose modifiers](https://developer.android.com/develop/ui/compose/modifiers)
- `LazyColumn` と `LazyRow` は可視範囲に必要な項目を compose / layout する。通常の `Column` に大量の項目を入れる場合と意味・性能が異なる。[Lazy lists and lazy grids](https://developer.android.com/develop/ui/compose/lists)
- Compose の状態は Composable 内部にも、親や state holder にも置ける。状態を外部に出す標準形は値とイベントの入力であり、公式資料は「State that is hoisted this way has some important properties: Single source of truth」と説明する。[State and Jetpack Compose](https://developer.android.com/develop/ui/compose/state)
- Compose Preview は Android Studio が `@Preview` 付き Composable を Layoutlib で実行する。ネットワーク・ファイルアクセスがなく、一部 `Context` API や DI を伴う `ViewModel` の構築に制限がある。[Preview your UI with composable previews](https://developer.android.com/develop/ui/compose/tooling/previews)
- Android のシステムバー、IME、表示切り欠きは `WindowInsets` で扱う。SDK と target によって edge-to-edge の既定動作も変わる。[About window insets](https://developer.android.com/develop/ui/compose/system/insets)

### hamii への設計上の推論

- 共通 IR の `verticalStack` / `horizontalStack` / `overlay` はよい出発点になる。ただし `fill`、`hug`、`padding` を単なる独立プロパティに平坦化すると Modifier 順序と制約伝播を保存できない。共通語彙の外に、順序付きの framework mapping または明示的な layout/styling pipeline を置く必要がある。
- `LazyColumn` を単なる縦 Stack として変換してはいけない。反復データ、キー、可視項目生成、スクロール状態を持つ別種のノードとする必要がある。静的な有限個の子だけを持つ v0.1 では対象外にするのが妥当。
- UI の状態を完全に IR 内へ埋め込むと、実アプリの state holder と二重管理になる。まずは「表示に必要な入力」「イベント出力」「プレビュー用サンプル値」を定義し、ビジネスロジックはコード側の責務とする。
- Preview は生成コードの検証には有用だが、全動作の再現環境ではない。ユーザーが Canvas で見た結果との差分検証には、Preview に加えて Emulator / 実アプリでのスクリーンショット比較が必要。

## 2. Compose Multiplatform と Jetpack Compose の境界

### 検証できた事実

- Compose Multiplatform は共通 UI を複数プラットフォームへ展開できるが、各プラットフォームに固有の entry point が必要で、共通 API にない機能は platform-specific source set で実装する。[Default UI behavior on different platforms](https://kotlinlang.org/docs/multiplatform/compose-platform-specifics.html)
- 共通コードでも表示・操作が完全同一とは限らない。JetBrains は「unavoidable differences or temporary compromises」を明記し、ネイティブの選択メニューやスクロール感などの差を説明する。[Default UI behavior on different platforms](https://kotlinlang.org/docs/multiplatform/compose-platform-specifics.html)
- Compose Multiplatform と UIKit は双方向の埋め込みが可能で、UIKit view を `UIKitView` で包める。[Integration with the UIKit framework](https://kotlinlang.org/docs/multiplatform/compose-uikit-integration.html)
- CMP の共通リソースは専用ライブラリと Gradle プラグインで画像・フォント・文字列などを扱う。SwiftUI / UIKit の asset catalog と同一成果物ではない。[Resources overview](https://kotlinlang.org/docs/multiplatform/compose-multiplatform-resources.html)
- 2026 年時点の JetBrains 文書では、CMP の共通コード Preview は Android target を必要とし、Android のライブラリに依存する。[Compose UI previews](https://kotlinlang.org/docs/multiplatform/compose-previews.html)
- Kotlin の `expect` / `actual` 宣言は platform-specific API を共通コードから参照するための言語機構である。[Use platform-specific APIs](https://kotlinlang.org/docs/multiplatform/multiplatform-connect-to-apis.html)

### hamii への設計上の推論

- 「Jetpack Compose」と「CMP」は同じ Kotlin UI 構文を共有する範囲が広いものの、同一 Export Target ではない。パッケージ、リソース、entry point、依存関係、プレビュー構成を区別する。
- CMP の iOS 表示は SwiftUI 変換の代替経路にはなるが、SwiftUI ネイティブ View を生成することと同義ではない。hamii の Target 選択時にこの違いを表示すべき。
- 共通で表せない OS UI は一律の「汎用 Layer」へ押し込まず、platform mapping と fallback / interop を持たせる方が安全。

## 3. SwiftUI、UIKit とネイティブ実装の限界

### 検証できた事実

- SwiftUI レイアウトは親が提案サイズを渡し、子が計算したサイズを返す。公式資料は「The parent view proposes a size to the child views it contains, and the child views respond with a computed size.」と説明する。[Laying out a simple view](https://developer.apple.com/documentation/swiftui/laying-out-a-simple-view)
- SwiftUI の modifier も適用順序が結果を変える。`frame` と `border` の順序を使って公式資料は「The order in which you apply modifiers matters.」と述べる。[Configuring views](https://developer.apple.com/documentation/swiftui/configuring-views)
- SwiftUI の独自 View は `body` を計算して他の View を合成でき、状態に応じて表示が変わる。静的な Layer tree だけでは任意の `body` の分岐や実行時データを表現できない。[Declaring a custom view](https://developer.apple.com/documentation/swiftui/declaring-a-custom-view)、[Managing user interface state](https://developer.apple.com/documentation/swiftui/managing-user-interface-state/)
- UIKit Auto Layout は View に付与した制約からサイズと位置を算出する。公式資料の「Auto Layout dynamically calculates the size and position of all the views in your view hierarchy, based on constraints placed on those views.」が要点である。[Auto Layout Guide](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/AutolayoutPG/)
- SwiftUI と UIKit は `UIHostingController` や `UIViewRepresentable` でランタイムに混在できる。これは元の実装を保った埋め込みであり、片方の意味構造への変換ではない。[UIKit integration](https://developer.apple.com/documentation/swiftui/uikit-integration)
- Safe Area は両者に存在するが、SwiftUI は layout proposal、UIKit は view の inset / 制約との関係で扱う。[ignoresSafeArea](https://developer.apple.com/documentation/swiftui/view/ignoressafearea%28_%3Aedges%3A%29)、[UIView.safeAreaInsets](https://developer.apple.com/documentation/uikit/uiview/safeareainsets)
- Xcode の `#Preview` は SwiftUI / UIKit のコードを IDE 内で確認でき、設定を変えて Dynamic Type、言語、外観も試せる。[Adding previews to your interface files](https://developer.apple.com/documentation/xcode/adding-previews-to-your-interface-files)、[Interacting with previews in the canvas](https://developer.apple.com/documentation/xcode/interacting-with-previews-in-the-canvas)

### hamii への設計上の推論

- 共通 IR の `fixed` / `fill` / `content` は意図を表すものとし、SwiftUI の proposal / response、UIKit の constraint solver、Compose の constraint measurement にそのまま同じ数値式を強制しない。変換器ごとに意味を定義し、画面幅や文字サイズを変えた実行比較で保証範囲を定める。
- 任意の SwiftUI `body`、closure、状態遷移、UIKit imperative API を GUI の静的 Layer tree に完全復元する約束はできない。コードからの逆変換は hamii が生成した範囲、または明示した supported subset に限定する。
- UIKit を hamii の macOS エディタ本体の UI 技術として扱わない。UIKit は生成・プレビュー対象の iOS framework である。

## 4. macOS の文書管理と Canvas 描画

### 検証できた事実

- `NSDocument` はファイルまたは file package の読書きと、保存・復元・Undo などの文書ライフサイクルを扱う。[NSDocument](https://developer.apple.com/documentation/appkit/nsdocument)
- AppKit の `NSView.draw(_:)` は dirty rectangle を受け取る。無限 Canvas の描画を viewport / dirty 領域で絞るための基礎になる。[draw(_:)](https://developer.apple.com/documentation/appkit/nsview/draw%28_%3A%29)
- SwiftUI の `Canvas` は複雑な 2D 描画を行える一方、描いた個々の要素に操作やアクセシビリティを自動付与しない。公式資料は「A canvas doesn’t offer interactivity or accessibility for individual elements」と述べる。[Canvas](https://developer.apple.com/documentation/swiftui/canvas)
- Core Animation の `CALayer` はジオメトリ、内容、アニメーション状態を持つが、View の responder / event 系の代わりではない。[Core Animation Basics](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/CoreAnimationBasics/CoreAnimationBasics.html)
- `CAMetalLayer` は Metal の描画先として AppKit の `NSView` に設定できる。Apple はより高水準の `MTKView` の利用も案内している。[CAMetalLayer](https://developer.apple.com/documentation/quartzcore/cametallayer)

### hamii への設計上の推論

- 文書 UX は `NSDocument` を第一候補にし、`.hamii` package の保存、Undo、Autosave、クラッシュ復帰を検証する。`NSDocument` 自体が Git diff の扱いやすさを保証するわけではないため、内部の JSON 分割粒度は別途設計する。
- Canvas の描画結果、選択モデル、hit testing、アクセシビリティ tree を別責務とする。Canvas 上の Layer ごとに独立した `NSView` / `CALayer` を必須にしない。独自 renderer の採用可否は 1,000〜10,000 Layer の実測で決める。
- Metal は初期実装の前提にせず、Core Graphics / Core Animation / AppKit の組み合わせでの dirty region 描画、パン、ズームを測る。その結果、フレーム時間やメモリが基準を満たさない場合に Metal を比較する。
- Xcode Preview を hamii の Canvas へそのまま埋め込む公開 API は **Unknown**。最初は生成コードの別プロセス実行、Simulator screenshot、または Xcode での手動確認を前提に技術検証する。

## 5. 実装前に検証すべき点

| 状態 | 項目 | 試験案 |
|---|---|---|
| Needs Prototype | 同じ hamii layout spec が SwiftUI / UIKit / Compose で同じ寸法に落ちる範囲 | 固定・内容適合・親充填・最小最大・異なるフォントで基準画面を生成し、実行時の各 Layer frame を比較する。 |
| Needs Prototype | Modifier と SwiftUI modifier の順序を保つ IR の最小表現 | padding / background / clipping / hit testing の順序を変えた例を相互変換し、見た目と操作領域を比較する。 |
| Needs Validation | CMP の共通リソースと iOS / Android プロジェクトへの貼り付け UX | 画像・フォント・文字列を含む Component をそれぞれのプロジェクトへ移植し、コンパイルと runtime asset 解決を確認する。 |
| Needs Validation | Native Preview の自動化 API とビルド時間 | Xcode / Gradle の最小プロジェクトで生成から screenshot までの時間と失敗率を測定する。 |
| Needs Benchmark | AppKit / Core Graphics / Core Animation と Metal の Canvas 性能差 | 1,000 / 10,000 Layer、3 段階の Zoom、選択・ドラッグ中のフレーム時間、hit test、メモリを同一 Mac で計測する。 |
| Unknown | Xcode Preview を外部 macOS アプリに埋め込める安定した公開 API | Apple の公開 SDK を確認し、なければ Simulator screenshot 方式を検証する。 |
