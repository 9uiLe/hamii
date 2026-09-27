# hamii

hamii は Human と AI が同じ native-semantic UI model を編集する macOS 設計環境です。UI の正本は hamii IR です。Canvas は編集、Native Preview は対象 OS 上の実行、standalone generator は source 出力を担当します。AI の正式な入口は CLI です。

## Build / Run

macOS 14 以上、[Swift 6.4](https://www.swift.org/blog/swift-6.4-released/)、Xcode、Git が必要です。`.swift-version` は 6.4.0 を指定します。

```bash
~/.swiftly/bin/swift build
~/.swiftly/bin/swift run hamii-studio
~/.swiftly/bin/swift run hamii -- skills list --json
bash scripts/package-app.sh
open .build/hamii.app
```

`hamii-studio` は macOS editor です。Project directory を Open すると Pages、Screens、Layers、Components、Assets、Canvas、Text Inspector を表示します。Asset は toolbar の Import Asset to Git から Git storage へ取り込み、利用可能な Asset を sidebar から Screen に挿入できます。macOS SwiftUI AppSurface は Native Preview へ切り替えられ、対応する Text patch は compile なしで反映されます。iOS Simulator Native Preview Host は Preview 関連 ADR の検証対象です。

`hamii preview plan SURFACE_ID --json` は Target の capability 宣言と Screen の意味を検証します。成功した plan は Host の起動可否とは別です。Starter sample の macOS Surface は CI で plan を検証します。

## Project / CLI

```bash
~/.swiftly/bin/swift run hamii -- --project /path/to/project --json init MyApp
~/.swiftly/bin/swift run hamii -- --project /path/to/project --json inspect
~/.swiftly/bin/swift run hamii -- --project /path/to/project --json skills get authoring
~/.swiftly/bin/swift run hamii -- --project /path/to/project --json validate
~/.swiftly/bin/swift run hamii -- --project /path/to/project --json index rebuild
~/.swiftly/bin/swift run hamii -- --project /path/to/project --json skills get assets
```

`init` は directory を Git repository にし、worktree 固有の `.hamii/` を Git ignore に登録します。`inspect --json` は `document.revision` と opaque な `statePrecondition.rawValue` を返します。Semantic mutation には `--state TOKEN` が必須です。例えば `screen create SCOPE_ID Profile --state TOKEN` は GUI と同じ Application Service と Validator を通り、結果から次の token を取得できます。古い token は `conflict` として拒否されます。`--json` は structured output、失敗時は `category` と非ゼロ exit status を返します。AI は `skills list` / `skills get` でインストール済み version の操作方法を取得し、Canonical JSON や Local DB を直接編集しません。

Spacing Token は `skills get tokens` で操作方法を取得できます。`token create`、`token alias`、`layer token` は Scope と参照を検証し、Canvas と macOS Native Preview に spacing / padding を反映します。

`hamii-agent-profiles.json` は Actor Harness の versioned 設定です。`--profile builder` は mutation 可能、`--profile reviewer` は読み取り専用です。Scope promotion の権限は profile に明示されない限りありません。Skill text は操作説明であり権限ではありません。

## Architecture

```text
hamii-studio ─┐
              ├─> HamiiApplication ─> HamiiCore
hamii CLI ────┘          │
                        └─> ProjectRepository port <─ HamiiFormat

HamiiIndex           ─> HamiiCore   (CanonicalRevision calculator port,
                                    disposable SQLite query view)
HamiiPreviewProtocol ─> HamiiCore   (revisioned patch contract)
HamiiNativeRuntime   ─> HamiiCore, HamiiPreviewProtocol
HamiiGeneration      ─> HamiiCore   (standalone SwiftUI source)
HamiiIntegration     ─> HamiiCore   (semantic contract and profile)
HamiiMigrations     (raw historical format preflight boundary)
```

Core は GUI、CLI、Git、SQLite、Simulator、AI provider を import しません。`HamiiApplication` は semantic intent を検証済み patch に変換します。`HamiiFormat` は Current Canonical Format だけを読みます。

Project の `hamii.json` は identity、revision、独立した format version、Authoring Harness を保持します。`scopes/`、`pages/`、`screens/`、`components/`、`tokens/`、`assets/` などは stable ID の JSON files です。Git が共有正本です。保存時は読み込んだ Document の Canonical bytes と現在 bytes を照合し、外部変更を検知したら conflict で中断します。Multi-file save は `.hamii/` の journal で hamii の保存処理停止後に旧版または新版へ復旧します。`.hamii/write.lock` は現在 hamii process 同士の保存協調に使います。

Canonical collaboration の Product Contract は「1 worktree = 1 coordinated writer domain」です。`WorktreeCoordinator` は Canonical save と managed `git switch BRANCH --state TOKEN` の lock と observation epoch を共有します。中断した switch は Canonical access を拒否し、`hamii git recover` が clean な source / target branch と Canonical validation を確認した場合だけ再開します。独立 writer は別 branch / worktree を使い、Git merge candidate の Canonical semantic validation と Index generation を経て publish します。raw Git / 外部 editor による同一 worktree の直接変更は安全な共同編集経路ではありません。Validated merge publication と Index generation protocol は実装待ちです。`hamii.json` の revision は mutation 順序であり、merge をまたぐ Canonical state identity や client session token ではありません。現在の `ClientPrecondition` は Canonical JSON bytes と worktree 固有の local epoch を結び付け、GUI / CLI mutation と Preview patch の基点を照合します。詳しくは [Current Architecture](docs/final-architecture.md) を参照してください。

再構築可能な SQLite index は `~/Library/Application Support/hamii/indexes/` の Document / worktree 別領域に置き、Git に保存しません。外部編集後の検索は Canonical revision の不一致で `staleIndex` として拒否されるため、`hamii index rebuild` を実行します。Canonical file に Git の `assume-unchanged` / `skip-worktree` flag または Git filter がある場合は、設定を解除してから再構築します。自動復旧と増分再索引は検証中です。

Repository Asset は `asset import SCOPE_ID NAME MEDIA_TYPE SOURCE_PATH --storage git --state TOKEN` で明示的に取り込みます。バイナリは `assets/blobs/<sha256>` に一度だけ保存され、Asset の JSON は hash と参照を保持します。`validate` は blob の改ざんと欠落を検出します。大きなファイルの Git LFS 運用境界は [Asset ADR](adr/asset-storage-policy/ADR.md) で検証中です。Remote cache、thumbnail、decode 結果は Canonical Repository に含めません。

Document Format v1 が唯一の Canonical Format です。`hamii migrate plan --json` は source version と利用可能な変換を preflight し、元 repository を変更しません。Historical transformation edge はまだありません。新形式の導入時は Current Core に旧型の分岐を追加せず、isolated migration と reviewable worktree 変換を実装します。

## Capability / Preview

Layer の実装済み kind は Stack、Text、Image、Button、Scroll、Overlay、Component Instance です。Support coverage を追加するときは IR、validation、Canvas、Native Preview、generator、CLI の契約を揃え、target 別の support state を明示します。[Capability ADR](adr/capability-contract/ADR.md) が粒度と framework coverage を検証します。Unsupported な意味を暗黙に近似しません。

`HamiiPreviewProtocol` は state precondition 付き snapshot、base/new state と revision を分けた patch、ack と build boundary を定義します。`HamiiNativeRuntime` は macOS の supported SwiftUI subset を実 OS の SwiftUI で描き、Text patch を compile なしで適用します。欠番 patch は拒否し、snapshot で再同期できます。iOS Simulator Host transport、frame/input、structure reconciliation と state preservation は個別 ADR/Spike の検証対象です。OS-dependent system UI は対象 OS の Host が描画します。

[Starter sample](Samples/Starter/) は Page、Screen、AppSurface、Target capability、Text / Button Layer、Spacing Token を持つ Git 正本形式の例です。

`hamii generate swiftui SCREEN_ID TARGET_ID --json` は対応した静的 subset の standalone source を返します。Runtime binding や未対応 semantics は error になります。`hamii integration contract SCREEN_ID --json` は product repository に渡す input/event/token/asset contract を返し、source generation とは別経路です。

## Tests / development / ADR

```bash
bash scripts/check.sh
```

Swift 6.4 build/test、module dependency、ADR/Spike 形式、CLI smoke test を実行します。CI も同じ入口を使います。

[`adr/`](adr/) は未確定・未検証・未実装の設計判断の queue です。判断は一件一境界、実験は `spikes/<name>/SPIKE.md` に記録します。判断と実験結果を先に commit、実装を次に commit、完了した ADR の削除を後の commit に分けます。[ADR workflow](docs/adr-workflow.md) と [Current Architecture](docs/final-architecture.md) を参照してください。

実行可能な機能の範囲と残る実装は [Implementation Status](docs/implementation-status.md) に記録します。
