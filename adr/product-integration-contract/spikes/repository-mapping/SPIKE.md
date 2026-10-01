# Spike: Product Integration Contract の実証

## Related Decision

[ADR.md](../../ADR.md) の Decision to Make を検証する。全体の優先順位は [Technical Spikes](../../../../docs/spikes.md) を参照。

## Hypothesis

semantic contract と repo profile を渡せば AI は異なる product architecture に UI intent を保持して統合できる。

## Questions

二つ以上の repo で inputs/events/bindings/tokens/a11y を追跡できるか。AI は不明な mapping を保留できるか。

## Prototype Scope

同じ ProfileHeader を異なる repository convention の二つ以上の実 repo に移植し、unknown mapping を意図的に含める。

## Out of Scope

hamii IR に MVVM/TCA/DI を追加すること、AI が生成した差分の自動 merge、任意 repository の完全対応。

試作 code をそのまま production code に昇格させない。

## Measurements

build/test、inputs/events/bindings/tokens/a11y 対応表、誤 mapping、Human 修正量、diff review 時間を記録する。

実行環境、fixture、command、実装 commit、raw data を記録する。必要なときだけ `artifacts/` を作成し、巨大な build output は commit しない。定量 budget は実験前に固定する。

### Predeclared experiment protocol (2026-10-01; before integration attempts)

- Same semantic fixture: `ProfileHeader` displays `displayName` and `secondaryText`, an avatar image, and an edit action. It uses one spacing token, one avatar accessibility label, and one system navigation intent. The **only intentionally unknown mapping** is the destination for `editProfile`; the attempt must leave it explicitly unresolved and must not invent a route. The remaining inputs may be supplied by a repository-owned presentation state where a repository has no existing profile model; that addition must be counted in the diff and mapping audit. Each attempt receives the same intent. State and binding meaning must be retained even though current production `IntegrationContract` lacks dedicated state/dependency fields.
- Repository A: [Apple Food Truck](https://github.com/apple/sample-food-truck), commit `3954a769e99f3cc53297d94f2b960ceb2665b3d6`, MIT-style `LICENSE.txt`. Existing `AccountView` uses `@ObservedObject FoodTruckModel` and `@EnvironmentObject AccountStore`. Baseline gate: `xcodebuild -project 'Food Truck.xcodeproj' -scheme 'Food Truck' -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath <outside-hamii> CODE_SIGNING_ALLOWED=NO build` (passed). The macOS variant failed on iOS Live Activity APIs; it is not the chosen gate. No test target is declared in the project.
- Repository B: [Point-Free Composable Architecture SyncUps](https://github.com/pointfreeco/swift-composable-architecture/tree/main/Examples/SyncUps), commit `377da4061db10d26337a71bb279c506bb951f50f`, MIT `LICENSE`. `SyncUpsList` and `AppFeature` use reducers, observable state and store actions. Baseline build gate: `xcodebuild -project Examples/SyncUps/SyncUps.xcodeproj -scheme SyncUps -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath <outside-hamii> -skipMacroValidation CODE_SIGNING_ALLOWED=NO build` (passed). Xcode first requested macro approval; the flag is fixed for all runs. Unit-test gate uses the same project/scheme with `-destination 'platform=iOS Simulator,id=10849834-229F-4AB1-A1B3-88BBEB25B5CF' -only-testing:SyncUpsTests test`; baseline passed 21 Swift Testing tests with 12 known issues. The initial iOS 26.5 test destination was rejected because this project requires iOS 27.0.
- Both targets are cloned outside hamii. Before each attempt, reset source files to the exact pinned commit and use a separate target checkout or worktree. The build output stays outside hamii. The same target-specific repository profile and convention extract are reused across all three contract shapes. Dependency resolution, Xcode version, simulator destination, model/tool mode, and any observation carryover are recorded. Sequential attempts by the same agent are not blinded: later attempts may benefit from earlier repository knowledge, so contract-shape comparisons remain exploratory rather than causal evidence. A target baseline build failure blocks that target; it is not scored as an integration failure.
- Contract shapes: (1) component API/implementation with explicit references, (2) screen-level flat intent plus placement context, (3) intent/dependency nodes and edges. The semantic items are identical. The only variable intended to differ is representation; any additional context required by a shape is disclosed in the attempt record. The current production screen contract's missing state/dependency fields are evaluated explicitly.
- Matrix: Food Truck × {component, screen, graph}; SyncUps × {component, screen, graph}. Each attempt saves full input prompt, contract, profile, convention extract, model/tool/date, allowed paths, generated diff, build/test command and exit status, and semantic audit. An attempt is retained even if it fails.
- **Acceptance budget:** silent mapping guess `0`; silent semantic loss `0`; every required intent item `100%` mapped to a code location or marked explicitly unresolved. A patch for all mapped items must pass the target baseline build gate. No production API or CLI is changed during this Spike.
- Review starts when the initial patch is available and ends when every semantic item has a `correct` / `unresolved` / `incorrect` / `silently lost` classification and correction list. Record changed file count, added/deleted lines, and elapsed review time for every attempt. Record semantic, architecture/convention, and cosmetic correction counts separately. These are observations, not a Product SLA. If no independent human reviews the patch, label the counts as AI reviewer estimates and leave the Human correction criterion unverified.
- An attempt with an ungrounded edit route or silently missing item fails even if it builds. Six completed and comparable attempts, including failures, are required before this ADR may move to `Ready for Decision`; no option is selected in the Spike.

Preflight candidate rejected: [Austin-Almighty SwiftUI-Template](https://github.com/Austin-Almighty/SwiftUI-Template) at `61f9b40d414cc3fd77bb21b427319d5672f39ac5` failed its unmodified `swift test` baseline under Swift 6.4 in pinned TCA 1.22.3 (`NavigationStack+Observation.swift`: main-actor key-path compiler error). It is excluded from the six-attempt matrix rather than counted as a contract failure. Environment: macOS 27.0, Xcode 27.0 build 27A266a, Apple Swift 6.4, arm64. Local full logs and DerivedData are outside this repository under `/tmp/hamii-integration-spike/`; only bounded evidence belongs in Git.

## Success Criteria

両 repo で contract の各項目が追跡可能で、unknown mapping を silent guess しない。

## Failure Criteria

contract の意味が失われる、unknown mapping を silent guess する、または差分が review 困難。

## Result

2026-10-01 に、固定した2つの実 Repository と同一 ProfileHeader fixture で6つの逐次 AI 試行を実施した。各 attempt の prompt、contract、差分、項目別 mapping、build/test、修正候補、review 時間は [artifacts/attempts/](artifacts/attempts/) にある。各 `*.patch.gz` を展開した原本は対象の pinned commit へ `git apply` で再適用し、展開後 SHA-256、`git diff --check` と差分行数を照合した。gzip は patch 内容を変えずに、外部 source の既存空白を hamii 自身の diff whitespace 判定から分離するための保存形式である。大きな checkout / build log / DerivedData は Repository 外に置いた。

| Target | Shape | Final build | Existing tests | Patch files / + / − | AI self-review wall time | AI semantic / architecture / cosmetic corrections |
| --- | --- | --- | --- | --- | --- | --- |
| [Food Truck](artifacts/attempts/food-truck-component/RESULT.md) | component | pass | target なし | 1 / 42 / 12 | 35 s | 2 / 0 / 0 |
| [Food Truck](artifacts/attempts/food-truck-screen/RESULT.md) | screen | pass | target なし | 1 / 31 / 12 | 10 s | 0 / 0 / 0 |
| [Food Truck](artifacts/attempts/food-truck-graph/RESULT.md) | graph | pass | target なし | 1 / 48 / 11 | 10 s | 0 / 0 / 0 |
| [SyncUps](artifacts/attempts/syncups-component/RESULT.md) | component | pass | 21 pass, 12 known issues | 1 / 47 / 0 | 13 s | 0 / 0 / 0 |
| [SyncUps](artifacts/attempts/syncups-screen/RESULT.md) | screen | pass | 21 pass, 12 known issues | 1 / 32 / 0 | 9 s | 0 / 0 / 0 |
| [SyncUps](artifacts/attempts/syncups-graph/RESULT.md) | graph | pass | 21 pass, 12 known issues | 1 / 61 / 0 | 9 s | 0 / 0 / 0 |

**Confirmed within source audit:** 各 final patch では I01–I10 が target code location に対応し、I11 `editProfileDestination` は明示的 unresolved だった。意図しない route / state / API の創作は0、silent lossは0。MVVM/TCA の型は外部 patch 内だけにあり hamii IR は変更していない。Food Truck component 試行の **初回** patch は build success でも既存 `Form` の閉じ括弧を早く置き、後続 control を外へ出す semantic regression があった。レビューで発見・修正してから同じ build を再実行した。build 成功だけを semantic correctness としない証拠である。

**Measured conditions:** Food Truck iOS Simulator baseline / 3 post-patch builds は成功。プロジェクトに test target はない。SyncUps baseline / 3 post-patch builds と baseline / 3 post-patch unit-test gates は成功し、各 test gate は Swift Testing 21件、既存 known issues 12件を報告した。SyncUps では Xcode macro approval を `-skipMacroValidation` で固定し、iOS 27.0 Simulator を使用した。macOS Food Truck build、iOS 26.5 SyncUps test destination、および別の TCA template candidate の baseline failure は対象選定・環境の失敗として記録し、contract failure に混ぜていない。

**Interpretation limits:** 同一 agent が6件を順番に実施したため学習の持ち越しがあり、方式間の行数・修正数・review 時間を因果効果として比較できない。reviewer は AI 本人で独立 Human correction は**未計測**。SyncUps に既存 profile domain がなく、表示名は fixture 用 State を追加した。既存 tests は新しい edit action を exercise せず、目視の runtime 確認もしていない。したがって「実 Product の未知 mapping に対して AI が一般に安全」とは結論できない。現行 production `IntegrationContract` には States と dependency structure の独立 field がない。screen 試行では state を `stateNote` と共有 fixture で補ったため、その欠落が実験で消えたわけではない。

## Conclusion

3表現とも、検証した2 Repository では semantic item を source 上で追跡できた。ただし独立 Human review、context を分離した AI 比較、既存 profile data を持つ reducer Repository、new-action runtime validation が不足する。どの contract granularity を production の正式方式にするかは**未決定**。ADR は `Spike Required` のまま維持し、追加の Evidence を絞ってから判断する。特に review independence と、既存 product state / edit route が実在する Repository で unknown mapping を評価する必要がある。この Spike の patch は prototype であり production adapter / API に昇格しない。

## Artifacts

[artifacts/](artifacts/) に固定 fixture、3表現、2 Repository profile、6件の full prompt / small patch / 結果表を保存する。target checkout、Xcode DerivedData、raw build/test logs は commit しない。
