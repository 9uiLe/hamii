# hamii — Current Architecture

hamii の Runtime / Editing Source of Truth は Native-semantic IR です。Human GUI と AI/automation CLI は同じ `ProjectService` へ semantic intent を送り、`MutationEngine` と `DocumentValidator` を通した結果だけを Canonical repository に保存します。

## Product boundary

hamii は Canvas、Layers、Components、Inspector、Tokens、Assets と Native UI semantics を結ぶ macOS design environment です。Networking、authentication、database、business logic、routing implementation、DI、app lifecycle は Core IR の対象ではありません。Product repository に統合するときは semantic contract と integration profile を AI に渡し、既存 architecture へ適応します。Native source は IR の正本になりません。

## Modules

| Module | Responsibility | Dependencies |
|---|---|---|
| `HamiiCore` | Document IR、ArchitectureScope、Component、Token、Asset、Interaction、Motion、Authoring rules、validation | Foundation |
| `HamiiApplication` | Human/Agent intent、revision precondition、semantic patch、repository port、query service | Core |
| `HamiiFormat` | Current Canonical Format の JSON sharding、schema version gate | Core、Application |
| `HamiiIndex` | disposable SQLite component / usage / scope projection | Core |
| `HamiiPreviewProtocol` | revisioned patch、acknowledgement、build boundary | Core |
| `HamiiNativeRuntime` | 対象 OS の SwiftUI view、Text value patch、event trace | Core、PreviewProtocol、SwiftUI |
| `HamiiGeneration` | 対応 SwiftUI subset の deterministic source、unsupported diagnostics | Core |
| `HamiiIntegration` | Screen の semantic contract、repository profile、unresolved mapping | Core |
| `HamiiMigrations` | Raw manifest preflight、migration classification、unsupported edge report | Foundation |
| `HamiiCLI` | structured automation interface、versioned skill text、exit categories | Application、Format、Index、Generation、Integration、Migrations |
| `HamiiApp` | macOS Canvas、Layers、Inspector、Human intent adapter、Native Preview panel | Application、Format、Core、NativeRuntime |

`scripts/check-architecture.sh` が Core と Application の forbidden imports を検査します。Production sources は `adr/` を読みません。

## IR and ownership

`Document` は自由な Page、Screen、Scope、ComponentDefinition、Token、Asset、Interaction、Motion、PreviewFixture、Target と AuthoringHarness を含みます。Page は Canvas organization であり Scope ではありません。Screen は Scope と Layer root を持ち、AppSurface は Screen を参照します。AppSurface には Target、Device、Runtime、BuildEnvironment、Fixture、Scope が別 field であります。

ArchitectureScope の依存 predicate は `owner ∈ ancestors(consumer) ∪ {consumer}` です。Component、Token、Asset の参照に同じ rule を適用します。Component availability は nested Definition にも再帰的に適用し、Picker、SQLite projection、Mutation Validator が共通 evaluator を使います。ComponentDefinition の owner は Variant に移せません。Instance は Definition ID、variant selection、property/slot value、public override のみ保持し、解決結果は永続化しません。`ComponentResolver` は選択 variant の衝突と private override を拒否します。Promotion candidate は consumer Scope の Least Common Ancestor です。Agent の Scope promotion は profile で明示的に許可されない限り拒否します。

Layer は stable ID、semantic kind、layout、content/reference、accessibility、native intent、target override を持ちます。実装済み kind は Stack、Text、Image、Button、Component Instance、Scroll、Overlay です。正確な typed IR taxonomy と target lowering は [Native-semantic IR ADR](../adr/native-semantic-ir/ADR.md) の判断待ちです。System UI を自由配置 Rectangle として保存する設計は採用しません。

`CapabilityDeclaration` は target ごとに `Exact`、`Portable`、`Target-specific`、`Approximate`、`Unsupported`、`External Integration Required` を表します。`TargetPlanner` は未宣言を Unsupported とし、Approximate に明示承認を要求します。Framework ごとの確定 coverage と粒度は [Capability ADR](../adr/capability-contract/ADR.md) で検証します。

## Mutation and authoring

Human/Agent adapter は `AuthoringIntent` を `ProjectService` に渡します。Service は client が観測した opaque な `ClientPrecondition` を現在の Canonical observation と照合し、MutationEngine が candidate Document と `SemanticPatch` を作成します。DocumentValidator が ID、参照、Scope、Component、Token、Asset、Interaction、Harness rule を検証し、失敗した candidate は保存しません。同値編集は revision を進めず Canonical files を書かず、同じ precondition を返します。Patch は entity ID、property path、old/new value を持ちます。GUI と CLI は同じ service を使用します。`DocumentRevision` は MutationEngine 内の順序検査に残しますが、client state identity の代わりにはしません。

AgentHarness は profile 名、mutation limit、Scope promotion 権限を持ち、`hamii-agent-profiles.json` に独立 version で保存します。`builder` と読み取り専用 `reviewer` を作成時に登録します。HumanHarness は snap と insertion preference を持つ actor 設定です。両者は Product rule を変更できません。AuthoringHarness は現在、control label、token spacing、atomic mutation count の machine-readable rule を持ちます。Policy の拡張と waiver は [Authoring Policy ADR](../adr/authoring-policy-enforcement/ADR.md) の検証対象です。Skill text は操作方法の説明であり、権限判定ではありません。

## Persistence, query, migration

Git に置く `hamii.json` と entity ごとの JSON が Canonical Data です。Stable ID は filename と reference の両方に使います。`hamii.json` の revision は hamii semantic mutation の順序と journal の旧新判定に使います。これは Canonical contents の identity ではありません。Document、Authoring Harness、Integration Profile の format version は独立 field です。Current Format 以外は `HamiiFormat` の version gate で拒否します。Current Core は historical parser を持ちません。Shard 粒度は [Sharding ADR](../adr/git-canonical-sharding/ADR.md) の検証対象です。

`HamiiFormat` は保存時に読み込み時点の Document から期待 Canonical bytes を組み立て、現在 bytes と照合します。不一致なら journal 作成前に conflict として中断します。変更された shard の旧新 bytes を `.hamii/transaction.ready` に journal として準備し、Canonical shard を更新してから `hamii.json` の revision を最後に切り替えます。次の `load` / `save` は journal を先に復旧し、manifest が旧版なら rollback、新版なら roll forward します。適用時に旧新 bytes 以外を観測した場合は conflict を返し、その bytes と journal を保持します。処理済み journal は rename 後に削除するため、cleanup 中の停止でも完全な revision を開けます。現行 `.hamii/write.lock` は hamii process 同士の保存協調用です。journal は hamii save の停止復旧用であり、観測されない外部書込を復元しません。検知できた競合は保存中断へ倒します。check と replace の間に入る外部書込を現行実装が必ず検知する保証はありません。停電耐久性は [Power-loss ADR](../adr/canonical-power-loss-durability/ADR.md) の検証対象です。

### Canonical collaboration contract

一つの worktree は一つの coordinated writer domain です。hamii GUI、hamii CLI / AI、hamii-managed Git operation が同じ worktree を変更するときは共通の lock、generation、recovery、validation を通します。raw Git CLI、外部 editor / script / AI など非協調 writer による同一 worktree 直接変更は安全な共同編集経路として保証しません。外部変更の検知は defense-in-depth です。独立 writer は別 branch / worktree で作業します。

統合では Git merge を candidate として隔離し、Canonical parse、schema、stable ID、reference、Scope / Component、Authoring rule を検証します。同じ source state から Index generation を作成・検証した後にのみ、利用可能な hamii Project として publish します。Git merge exit 0 は hamii merge success ではありません。失敗時は candidate を拒否し、両側の有効な branch / worktree を保持します。現在はこの managed Git / validated merge / publication pipeline を実装していません。現行 CLI の raw Git 操作を managed operation とみなしません。実装は [External Git Write ADR](../adr/git-external-write-coordination/ADR.md) に残り、Index の source / generation binding は [Index ADR](../adr/index-consistency/ADR.md) の検証対象です。

`DocumentRevision` は hamii mutation の順序、Canonical state identity は観測した contents の同一性、worktree generation は協調 writer domain 内の transition、Index generation は公開済みの derived snapshot、client session token は client の観測基点を表します。同じ token で実装できる可能性はありますが、概念は別です。`ClientPrecondition` は worktree path、coordinated local epoch、現在の Canonical JSON path/bytes を結び付けた opaque value です。Agent profile JSON も計算対象です。`ProjectService` が GUI と CLI に同じ照合を適用し、同じ revision の別 contents を拒否します。`.hamii/client-observation-epoch` は Git に保存せず、hamii save の前に更新します。Process restart では journal 回復後に再観測し、epoch の欠損で旧 token を失効、破損時は client observation / mutation を拒否します。Raw Git 等の protocol 非参加 writer による無通知 A → B → A は保証外です。Managed Git による epoch 更新と Undo / Redo base の連携は [Canonical state precondition ADR](../adr/canonical-state-precondition/ADR.md) の実装待ちです。

Repository Asset の blob は `assets/blobs/<sha256>` に置き、Asset entity は source path と content hash を持ちます。同じ content は同じ blob を共有します。CLI の `asset import ... --storage git` が取り込み、Canonical validation は欠落と hash 不一致を拒否します。Remote Asset は URL が正本、Runtime-bound Asset は binding が正本で、Preview Fixture とは別です。Large binary の Git/LFS 境界は [Asset ADR](../adr/asset-storage-policy/ADR.md) の判断待ちです。Derived cache は Git に置きません。

Local SQLite は Git に保存しない削除可能な Materialized Query View です。`~/Library/Application Support/hamii/indexes/` の Document ID と worktree path から導いた別領域に `index.sqlite` を置くため、clone / worktree ごとに独立します。`IndexProjection` が Canonical Document から component、usage、scope closure、availability の行を導出し、`hamii index rebuild` がその行を単一 SQLite transaction に書き込みます。Index schema が変われば再生成し、長期 schema migration は保持しません。`CanonicalRevision` は hamii が解釈する Canonical Data の状態を識別する契約であり、Git commit の別名ではありません。`IndexGeneration` は公開された derived snapshot を指す別概念です。一貫した `CanonicalSnapshot` から revision を導出する境界と明示的な generation ID は未実装です。現行 `LocalIndex` は indexed CanonicalRevision を metadata に保持します。現在の `GitCanonicalRevisionCalculator` は Git HEAD と working tree の Canonical JSON bytes を識別し、tracked file の index flags / filter attributes も検査します。Git 状態を確認できなければ検索を拒否します。HEAD が変わると、Canonical files が同じでも保守的に Index を失効させるため、この不要な失効は改善対象です。`hamii query components` は SQLite の一貫した読み取り後に revision を照合し、外部編集や branch 切替を検出した場合は `staleIndex` を返し、検索結果を返しません。計算の前後で同じ Canonical pathspec の Git status が変わった場合も拒否します。現行実装は `assume-unchanged` / `skip-worktree` flag または filter が Canonical file にある場合も拒否します。この制限は Git filter のある Repository 全般を製品上禁止する判断ではありません。同じ worktree への任意の外部同時書込を完全に防ぐ保証はありません。自動 full rebuild、増分再索引、atomic index generation publish、Git 同時操作、低 cost な鮮度判定は [Index ADR](../adr/index-consistency/ADR.md) の検証対象です。

Document Format v1 が唯一の Canonical Format です。`HamiiMigrations` は Core を import せず raw manifest を preflight し、未知 version を Manual / no migration edge として報告します。未復旧の Canonical journal がある場合、migration plan は blocker を返します。変換 edge が必要になった場合は Current Core の外で classification、reviewable worktree、validation、commit を通します。[Migration ADR](../adr/migration-core-boundary/ADR.md) と [Review ADR](../adr/migration-review-protocol/ADR.md) が実装境界を定めます。

## Canvas, Preview, generation, integration

macOS Canvas は編集用 SwiftUI view です。Native Preview は対象 OS が描画する別 runtime とします。`HamiiPreviewProtocol` は Document・Surface・state precondition の snapshot、base/new state と revision を分けた patch、適用 revision/state 付き acknowledgement を定義します。欠番 patch は拒否し、snapshot で再同期できます。`HamiiNativeRuntime` は macOS SwiftUI AppSurface の supported subset を実 OS 上で描き、Text value patch を compile なしで反映します。Spacing Token の literal / alias は Canvas と Native Preview の Stack spacing / container padding へ解決し、`token.spacing` capability を要求します。`Instant Patch`、`Runtime Reconciliation`、`Component Build`、`Full Build` を区別し、build が必要な patch を compile-free path で受け付けません。iOS Simulator Host と transport は [Preview Host ADR](../adr/preview-host-transport/ADR.md)、SwiftUI state reconciliation は [Reconciliation ADR](../adr/swiftui-reconciliation/ADR.md) で検証中です。現在の Simulator boot failure は Host install 前に生じる独立した検証環境 blocker であり、transport の評価結果ではありません。iOS Native Host と product repository 変更 adapter は未実装です。

`HamiiGeneration` は対応した静的 SwiftUI subset を決定的に出力します。Binding、interaction、token lowering など未対応 semantics は error にし、曖昧な source を出しません。`HamiiIntegration` は Screen の input/event/token/asset/native/accessibility contract と repository profile を分離し、未知 mapping を unresolved として返します。AI による product repository 変更と build/test review は [Product Integration ADR](../adr/product-integration-contract/ADR.md) の実証対象です。hamii IR に TCA、MVVM、Router、DI を入れません。

## CLI and development contract

`hamii` は唯一の AI/automation interface です。主要 command は `--json` を提供します。Skill discovery は `skills list` / `skills get` で、内容は binary と同じ version です。Mutation は `inspect` または直前の mutation で得た `statePrecondition.rawValue` を `--state TOKEN` として渡し、古い state は conflict category で拒否します。Validation error は diagnostic rule です。長期 command taxonomy は [CLI Command ADR](../adr/cli-command-taxonomy/ADR.md)、error と exit schema は [CLI Error ADR](../adr/cli-error-contract/ADR.md) で検証します。

`preview plan SURFACE_ID --json` は Target capability と Screen semantics の適合を確認します。Plan の成功は対象 OS の Host が利用可能であることを意味しません。Starter sample の macOS Surface は sample validation で plan を検査します。

`bash scripts/check.sh` が Swift 6.4 build/test、dependency check、ADR schema、CLI smoke test を実行します。CI はこの入口を使います。未解決の設計判断と検証結果は ADR queue に示します。
