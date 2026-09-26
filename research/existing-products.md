# 既存製品と開発環境の一次資料調査

調査日: 2026-09-26。**事実**は各社の公開資料に限る。**解釈**は hamii の設計に向けた推論であり、非公開の内部実装を断定しない。

| 対象 | 公開資料で確認できるモデル | hamii への解釈 |
|---|---|---|
| Figma | REST の node は FRAME、COMPONENT、INSTANCE 等と layoutMode、sizing、componentProperties を持つ。[Node types](https://developers.figma.com/docs/rest-api/file-node-types/) | 図形・フレームを土台に実装情報を接続する設計。公開 API から SwiftUI 等の実行時意味を完全復元できるとは言えない。 |
| Figma Code Connect / MCP | Code Connect はデザインの component と repository の component を結ぶ「bridge」。MCP は選択範囲の design context を取得できる。[Code Connect](https://developers.figma.com/docs/code-connect/)、[MCP tools](https://developers.figma.com/docs/figma-mcp-server/tools-and-prompts/) | 既存設計を実装に関連付ける仕組みは有効。hamii では対応関係を IR に一次情報として保持する。 |
| Sketch | `.sketch` は JSON と画像を含む ZIP、ページ別 JSON。[File format](https://developer.sketch.com/file-format/) | ページ単位の保存・外部読取を参考にできる。ZIP は Git diff に不利なので、そのまま採用しない。 |
| Framer | Code Component は React component で、canvas、preview、公開サイトに描画できる。[Code Components](https://www.framer.com/developers/components-introduction)、[Sharing Components](https://www.framer.com/help/articles/sharing-components/) | 対象実行系を Web に絞ると同じ renderer を共有しやすい。4 種の native target では同じ前提を置けない。 |
| Penpot | Flex Layout は CSS Flexbox ベースで「as close as possible to the final output」。[Flexible Layouts](https://help.penpot.app/user-guide/designing/flexible-layouts/) | Web と異なり SwiftUI、Auto Layout、Compose には共通の CSS 実行系がない。類似 property 名だけで fidelity を保証しない。 |
| Xcode Interface Builder | Storyboard は scene、segue、control を視覚編集し、実行時に復元する resource として保存する。[Apple technote](https://developer.apple.com/documentation/technotes/tn3123-refactoring-your-storyboard) | native interface と近いが、SwiftUI source の GUI 往復とは別系統。大きな単一 storyboard の source control 難も公式が指摘する。 |
| SwiftUI / Xcode Previews | SwiftUI/UIKit/AppKit の `#Preview` を code に付け、IDE canvas で実行表示。[Xcode previews](https://developer.apple.com/documentation/xcode/adding-previews-to-your-interface-files) | native 実行結果の検査経路。Xcode preview は hamii の editable layer tree の代替ではない。 |
| Android Studio Layout Editor | View XML の hierarchy を drag-and-drop で編集。[Android Layout Editor](https://developer.android.com/studio/views/layout-editor)、[XML layouts](https://developer.android.com/develop/ui/views/layout/declaring-layout) | XML が declarative tree のため visual 編集と対応しやすい。Compose は Kotlin 関数の実行系なので同じ round trip を前提にしない。 |
| Compose Preview | `@Composable` と `@Preview` で Android Studio の design view に表示。[Compose previews](https://developer.android.com/develop/ui/compose/tooling/previews) | コードの実行結果確認。hamii の可編集 tree への逆変換機能ではない。 |
| Compose Preview | `@Preview` 付き composable を Android Studio の design view に表示。[Compose previews](https://developer.android.com/develop/ui/compose/tooling/previews) | Kotlin code 実行の確認経路。macOS の canvas に Android runtime を埋め込めるという根拠ではない。 |
| Builder Visual Copilot | Figma からコードへの変換と既存コード component の mapping を公表。[Visual Copilot](https://www.builder.io/blog/figma-to-code-visual-copilot) | 一方向の変換と既存 component 再利用が焦点。任意コードの完全往復を保証する根拠はない。 |
| FlutterFlow | Widget tree は Row/Column/Stack 等の Flutter widget 構造を表し、components は parameter と callback を持つ。[Widgets](https://docs.flutterflow.io/resources/ui/widgets/)、[Components](https://docs.flutterflow.io/resources/ui/components/using-components/) | 対象を単一 framework に絞ることで意味構造を保ちやすい。hamii は共通核と target 固有表現を分ける必要がある。 |

## 判断に効く短い原文

- Figma Code Connect: “a bridge between your codebase and Figma’s Dev Mode”。デザイン node 自体が native code という意味ではない。[公式](https://developers.figma.com/docs/code-connect/)
- Penpot: “built over Flexbox”。そのため Web への対応が明快だが、この構造を SwiftUI/UIKit に直輸入すべき根拠にはならない。[公式](https://help.penpot.app/user-guide/designing/flexible-layouts/)
- Sketch: “ZIP archives containing JSON encoded data”。編集可能なモデルと公開保存形式を分けられる例。[公式](https://developer.sketch.com/file-format/)
- Framer: “rendering directly on the canvas, in the preview, and on your published site”。同じ React 実行環境に寄せた設計上の強み。[公式](https://www.framer.com/developers/components-introduction)
- FlutterFlow: “foundation of the Widget Tree”。visual editor と対象 framework の階層が近いことが重要。[公式](https://docs.flutterflow.io/resources/ui/widgets/)

## Unknown / Needs Validation

- Figma、Framer、Builder、FlutterFlow の**非公開 internal representation** は Unknown。公開 API から内部保存形式を推測しない。
- 各製品の任意コード round-trip の網羅率は公式資料だけでは確認できない。Unknown。
- Figma MCP の出力トークン量と hamii 案の比較は、実ファイルを使う benchmark が必要。
