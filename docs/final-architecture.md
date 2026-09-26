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

Human/Agent adapter は `AuthoringIntent` を `ProjectService` に渡します。Service は保存済み revision を照合し、MutationEngine が candidate Document と `SemanticPatch` を作成し、DocumentValidator が ID、参照、Scope、Component、Token、Asset、Interaction、Harness rule を検証します。失敗した candidate は保存しません。Patch は entity ID、property path、old/new value を持ちます。GUI と CLI は同じ service を使用します。

AgentHarness は profile 名、mutation limit、Scope promotion 権限を持ち、`hamii-agent-profiles.json` に独立 version で保存します。`builder` と読み取り専用 `reviewer` を作成時に登録します。HumanHarness は snap と insertion preference を持つ actor 設定です。両者は Product rule を変更できません。AuthoringHarness は現在、control label、token spacing、atomic mutation count の machine-readable rule を持ちます。Policy の拡張と waiver は [Authoring Policy ADR](../adr/authoring-policy-enforcement/ADR.md) の検証対象です。Skill text は操作方法の説明であり、権限判定ではありません。

## Persistence, query, migration

Git に置く `hamii.json` と entity ごとの JSON が Canonical Data です。Stable ID は filename と reference の両方に使います。Document、Authoring Harness、Integration Profile の format version は独立 field です。Current Format 以外は `HamiiFormat` の version gate で拒否します。Current Core は historical parser を持ちません。Shard 粒度は [Sharding ADR](../adr/git-canonical-sharding/ADR.md) の検証対象です。

`HamiiFormat` は変更された shard の旧新 bytes を `.hamii/transaction.ready` に journal として準備し、Canonical shard を更新してから `hamii.json` の revision を最後に切り替えます。次の `load` / `save` は journal を先に復旧し、manifest が旧版なら rollback、新版なら roll forward します。旧新 bytes 以外の外部変更には conflict を返し、その bytes と journal を保持します。処理済み journal は rename 後に削除するため、cleanup 中の停止でも完全な revision を開けます。停電耐久性と外部 Git 書込の同時性はそれぞれ [Power-loss ADR](../adr/canonical-power-loss-durability/ADR.md)、[External Git Write ADR](../adr/git-external-write-coordination/ADR.md) の検証対象です。

Repository Asset の blob は `assets/blobs/<sha256>` に置き、Asset entity は source path と content hash を持ちます。同じ content は同じ blob を共有します。CLI の `asset import ... --storage git` が取り込み、Canonical validation は欠落と hash 不一致を拒否します。Remote Asset は URL が正本、Runtime-bound Asset は binding が正本で、Preview Fixture とは別です。Large binary の Git/LFS 境界は [Asset ADR](../adr/asset-storage-policy/ADR.md) の判断待ちです。Derived cache は Git に置きません。

`.hamii/index.sqlite` は削除可能です。`hamii index rebuild` が Canonical Document から component、usage、scope closure、availability を再構築します。再構築時に Git HEAD、Canonical JSON の tracked diff と untracked bytes から Source Fingerprint を保存します。`hamii query components` は読み取り前後の fingerprint と index metadata を照合し、外部編集や branch 切替を検出した場合は `staleIndex` を返します。Git の同時書込と増分再索引は [Index ADR](../adr/index-consistency/ADR.md) の検証対象です。

Document Format v1 が唯一の Canonical Format です。`HamiiMigrations` は Core を import せず raw manifest を preflight し、未知 version を Manual / no migration edge として報告します。未復旧の Canonical journal がある場合、migration plan は blocker を返します。変換 edge が必要になった場合は Current Core の外で classification、reviewable worktree、validation、commit を通します。[Migration ADR](../adr/migration-core-boundary/ADR.md) と [Review ADR](../adr/migration-review-protocol/ADR.md) が実装境界を定めます。

## Canvas, Preview, generation, integration

macOS Canvas は編集用 SwiftUI view です。Native Preview は対象 OS が描画する別 runtime とします。`HamiiPreviewProtocol` は revision、surface、build boundary を含む patch と acknowledgement を定義します。`HamiiNativeRuntime` は macOS SwiftUI AppSurface の supported subset を実 OS 上で描き、Text value patch を compile なしで反映します。Spacing Token の literal / alias は Canvas と Native Preview の Stack spacing / container padding へ解決し、`token.spacing` capability を要求します。`Instant Patch`、`Runtime Reconciliation`、`Component Build`、`Full Build` を区別し、build が必要な patch を compile-free path で受け付けません。iOS Simulator Host と transport は [Preview Host ADR](../adr/preview-host-transport/ADR.md)、SwiftUI state reconciliation は [Reconciliation ADR](../adr/swiftui-reconciliation/ADR.md) で検証中です。iOS Native Host と product repository 変更 adapter は未実装です。

`HamiiGeneration` は対応した静的 SwiftUI subset を決定的に出力します。Binding、interaction、token lowering など未対応 semantics は error にし、曖昧な source を出しません。`HamiiIntegration` は Screen の input/event/token/asset/native/accessibility contract と repository profile を分離し、未知 mapping を unresolved として返します。AI による product repository 変更と build/test review は [Product Integration ADR](../adr/product-integration-contract/ADR.md) の実証対象です。hamii IR に TCA、MVVM、Router、DI を入れません。

## CLI and development contract

`hamii` は唯一の AI/automation interface です。主要 command は `--json` を提供します。Skill discovery は `skills list` / `skills get` で、内容は binary と同じ version です。Mutation は `--revision`、validation error は diagnostic rule、stale revision は conflict category です。長期 command taxonomy は [CLI Command ADR](../adr/cli-command-taxonomy/ADR.md)、error と exit schema は [CLI Error ADR](../adr/cli-error-contract/ADR.md) で検証します。

`preview plan SURFACE_ID --json` は Target capability と Screen semantics の適合を確認します。Plan の成功は対象 OS の Host が利用可能であることを意味しません。Starter sample の macOS Surface は sample validation で plan を検査します。

`bash scripts/check.sh` が Swift 6.4 build/test、dependency check、ADR schema、CLI smoke test を実行します。CI はこの入口を使います。Current implementation の supported subset と未解決の設計判断は ADR queue に示します。
