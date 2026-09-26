# Native Preview Runtime の一次資料調査

調査日: 2026-09-26。Apple / Google の公式資料から確認できた事実と、hamii の設計上の推論を分ける。この資料は Preview Host の成立可能性を判断するためのもので、性能・無ビルド更新・生成コードとの一致を実証したものではない。

## 1. 結論

**設計上の推論:** hamii が対応ノードのレンダラを iOS / Android アプリへ事前に組み込み、IR の値を実行時に受け取り、SwiftUI / UIKit / Compose の状態更新機構へ渡す方式は技術的に試す価値がある。ただし、同じ IR を描くことと、エクスポートしたソースが実アプリで同じ結果になることは別の性質である。前者はランタイムの動作、後者はレンダラとコードジェネレータ間の意味一致テストで検証する必要がある。

「Instant Patch」は通信・検証・モデル更新・フレーム描画を含むため**速度保証ではない**。ユーザーに約束できるのは「対応プロパティ変更ではコンパイルを要求しない」という更新経路であり、遅延は実測する。構造変更での state preservation、navigation、animation、システム UI の更新は **Needs Prototype**。

## 2. SwiftUI: 事前コンパイル済みノードレンダラ

### 確認できた事実

- SwiftUI は状態の変更を観察し、影響を受ける View を更新する。Apple は “SwiftUI watches for changes in the data, and updates any affected views as needed.” と説明する。[Managing user interface state](https://developer.apple.com/documentation/swiftui/managing-user-interface-state/)
- `ForEach` は識別子を持つデータ列から View を作る。可変の子ノード列を表示する公開 API の根拠となる。[ForEach](https://developer.apple.com/documentation/swiftui/foreach)
- `UIHostingController.rootView` は読み書き可能な SwiftUI root である。ただし root の差し替えが子の state を保持する保証はこの API からは導けない。[UIHostingController.rootView](https://developer.apple.com/documentation/swiftui/uihostingcontroller/rootview)
- Apple は View の identity が変わると state が置換されると説明する。短い原文は “whenever the identity changes, the state is replaced.” である。[Demystify SwiftUI, WWDC21](https://developer.apple.com/videos/play/wwdc2021/10022/)
- `AnyView` で包む View の型が変わると、旧 hierarchy は破棄され新しい hierarchy が作られる。Apple は “the old hierarchy is destroyed” と明記する。[AnyView](https://developer.apple.com/documentation/swiftui/anyview)
- `NavigationStack` の path は binding を通して管理できる。Navigation の構造や選択状態は単純な View 子配列とは別のモデルを要する。[Understanding the navigation stack](https://developer.apple.com/documentation/swiftui/understanding-the-navigation-stack)

### hamii への推論・制約

- `HamiiNode` の enum と事前コンパイル済みの `render(node)` を使い、対応済みの `Text`、`Image`、`Button`、Stack などをデータから選択する方法は候補になる。これは **任意の SwiftUI ソースを実行時に解釈することではない**。ノード種別や新しい modifier 実装を追加すると Preview Host 自体の build が必要になる。
- hamii の stable layer ID を `ForEach` 等の View identity へ対応させる。ただし ID が同じでも View の型・親の構造が変わる場合、state 維持は保証しない。編集操作を「値変更」「同型ノードの子配列変更」「型変更・root 変更」に分け、各々を試験する。
- 大量の `AnyView` による再帰レンダラは state と性能上のリスクがある。`@ViewBuilder`、enum の `switch`、`ForEach`、局所的な型消去の組み合わせを比較し、型チェック時間、再描画範囲、focus / scroll / state 維持を測る。最適な実装は **Needs Prototype**。

## 3. UIKit: 実行時の object tree 更新

### 確認できた事実

- `UIStackView` は arranged subview の追加・削除・順序と layout property の変更に追従する。公式文書は “The stack view automatically updates its layout whenever views are added, removed, or inserted” と説明する。[UIStackView](https://developer.apple.com/documentation/uikit/uistackview)
- UIKit の View 操作は main thread で行う必要がある。[UIKit overview](https://developer.apple.com/documentation/uikit)、[UIView](https://developer.apple.com/documentation/uikit/uiview)
- 制約変更では全制約の解除・再有効化を避け、変更が必要なもののみ更新するよう Apple が明記する。[UIView.updateConstraints()](https://developer.apple.com/documentation/uikit/uiview/updateconstraints())
- View controller の追加・削除には containment の順序と lifecycle 通知が必要であり、単に subview を差し替えるだけではない。[Creating a custom container view controller](https://developer.apple.com/documentation/uikit/creating-a-custom-container-view-controller)
- `UINavigationController` が navigation bar / toolbar を管理し、内容は各 controller の `UINavigationItem` に基づく。Apple は bar の `frame` 等を直接変更しないよう求める。[UINavigationController](https://developer.apple.com/documentation/uikit/uinavigationcontroller)

### hamii への推論・制約

- UIKit は IR node ID → `UIView` / `UIViewController` のレジストリを保持し、単純な property patch と arranged subview の変更を局所適用できる有力候補。ただし Navigation、sheet、controller replacement は controller lifecycle と state の扱いが必要で、すべてを同一の軽量 patch にしない。
- Property patch の適用は main actor 上へ移し、Auto Layout の依存する制約を追跡する。変更順序や途中状態で unsatisfiable constraints を生まないよう、transaction と検証が必要。

## 4. Jetpack Compose: 状態入力からの再 Composition

### 確認できた事実

- Compose では Composable の入力が変わると再実行し、差分が UI に反映される。Google は “You update the UI by calling the same composable function with different arguments.” と記す。[Thinking in Compose](https://developer.android.com/develop/ui/compose/mental-model)
- `mutableStateOf` 等の state を読んだ Composable は、値が変わると再 Composition の対象になる。Composition を変更する手段は再 Composition である。[Lifecycle of composables](https://developer.android.com/develop/ui/compose/lifecycle)
- 同じ call site から複数の Composable を作る場合、`key` で同一性を指定できる。順序だけに依存すると移動時の state と side effect が変化しうる。[Lifecycle of composables](https://developer.android.com/develop/ui/compose/lifecycle)
- Compose は parameter の stability に応じて再 Composition を skip できる。不安定な collection を丸ごと渡すと局所更新が効くとは限らない。[Stability in Compose](https://developer.android.com/develop/ui/compose/performance/stability)
- Android アプリは `ComponentActivity.setContent` または `ComposeView.setContent` で Compose tree をホストできる。`ComposeView` の composition disposal strategy により state が失われる場合がある。[Using Compose in Views](https://developer.android.com/develop/ui/compose/migrate/interoperability-apis/compose-in-views)

### hamii への推論・制約

- 事前にコンパイルした `@Composable Render(node)` と observable IR snapshot を組み合わせれば、データ patch による再 Composition は検証可能。ただし Composable 関数そのものは Compose compiler の処理対象であり、未知の Kotlin / Compose コードを IR patch だけで追加できない。
- `key(node.id)`、immutable な小さい入力、変更箇所の state read 分離を比較する。全 tree snapshot を一つの不安定引数として渡す実装では、局所 update の性能を主張できない。Compose UI tree を UIKit の `UIView` tree のように直接 mutate する説明も不適切。
- Android 実機と Emulator、CMP の iOS target はホスト環境が異なる。CMP iOS Preview Host が Android Compose Host と同じ patch transport / lifecycle / state 特性を持つかは **Needs Prototype**。

## 5. Preview Host の通信と Simulator の境界

### 確認できた事実

- Apple Network framework の `NWListener` は接続を待ち受けられる。[NWListener](https://developer.apple.com/documentation/network/nwlistener)
- Android Emulator から開発マシンの loopback へは `10.0.2.2` が公式の special alias である。これは Emulator 固有で、実機の同じアドレスを意味しない。[Android Emulator network address space](https://developer.android.com/studio/run/emulator-networking-address)
- iOS / macOS の local network access には OS の privacy 制約がある。[TN3179: Understanding local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- Simulator は実機の性能や機能を完全には再現しない。Apple は実機でも検証するよう案内する。[Running your app on simulated or physical devices](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)

### hamii への推論・制約

- 最初の実装候補は host 側 listener と Preview Host 側 client のローカル接続。接続開始、再接続、protocol / IR schema version、sequence number、ack、full snapshot fallback、asset delivery、複数 Surface の routing を定義する。Android Emulator の host address は一次資料で確認できたが、**iOS Simulator の loopback 到達方法と安定性は Unknown**。そこを実測せずに共通 transport を確定しない。
- Preview Host は source generator と独立した renderer であり、生成コードの実行結果そのものではない。`same IR → host preview` と `same IR → generated code → app` の差をスクリーンショット・アクセシビリティ tree・interaction traces で比較する fidelity harness が要る。
- Host を常駐させる場合も、OS による suspend / termination、device 切替、接続切断を通常状態として扱い、再接続後に full snapshot を再同期する。持続時間と再起動率は **Needs Benchmark**。

## 6. Build boundary の暫定判断

| 変更 | 事実から言えること | 暫定更新経路 | 未検証事項 |
|---|---|---|---|
| 対応ノードの text / color / spacing / state | 各 framework は状態・property 変更後の UI 更新を提供 | IR patch → Preview Host の observable model | 通信＋描画遅延、state / focus 維持 |
| 子の追加 / 削除 / 移動 | UIKit は view / stack の変更 API、SwiftUI / Compose は識別付きデータから再構成可能 | runtime reconciliation | identity、scroll / animation、controller lifecycle |
| Navigation / toolbar / system UI | framework 所有の navigation 状態と設定 API がある | semantic update または runtime refresh | 対象 framework / OS ごとの差 |
| hamii 対応ノード種別の追加 | 新しい renderer コードを既存 binary に追加する必要がある | Preview Host build | 部分 build の単位と配布方法 |
| Custom native component 内部コード変更 | IR 値の変更とは異なるコード変更 | component build **候補** | iOS Simulator への動的組み込み、署名、再リンク、state 移行は **Unknown** |
| dependency / SDK / entitlement / project settings | 実行 binary の構成を変える | full build | 最小範囲の再 build 可否は project 構成依存 |

**設計上の推論:** `Component Build` は独立した保証済みレベルとして売り込まない。静的リンク、埋め込み方式、コード署名、アプリ再インストールの要否が確認できるまで「build が必要」と表示する。通常の対応 IR 編集と native code boundary を UI で区別することは妥当。

## 7. Prototype の検証項目

1. **SwiftUI:** 15 種程度の node をデータから構成。text / padding 更新、子の追加・移動、型変更、root 差し替えで `@State`、focus、scroll、navigation path、animation がどう変わるか記録する。`AnyView` の有無を比較する。
2. **UIKit:** node ID → view/controller mapping を作り、property、stack 順序、navigation item、toolbar、controller 置換を patch。main thread 違反と Auto Layout warning をゼロにする。
3. **Compose:** `mutableStateOf` + `key` の tree renderer を作り、patch ごとの recomposition count、frame time、`remember` state の維持を測る。大きい mutable `List` と immutable subtree の差を測る。
4. **Host transport:** iOS Simulator と Android Emulator それぞれで Mac からの接続、認証・再接続・schema mismatch・full snapshot fallback を検証。patch → frame の p50 / p95 / p99 を測る。
5. **Fidelity:** 同じ IR から Runtime Host と source generator を走らせ、同一 device / OS / fixture の画像、semantic tree、event trace を比較する。許容差は対象 control ごとに定め、system UI に pixel 同一性を約束しない。
6. **Custom component:** 一つの SwiftUI custom component と UIKit custom view を変更し、再 build 範囲、署名、Host 再起動、既存 state の扱いを実測する。

上記の結果が揃うまで、Preview Host の常駐性・無ビルド更新範囲・局所 reconciliation・production parity は **Needs Prototype / Needs Benchmark** とする。
