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

未実施。実測値、観察、失敗、成果物への link を記入する。

## Conclusion

未実施。結果が ADR の Options と Current Hypothesis をどう変えたかを記入し、削除前に commit する。

## Artifacts

未作成。検証時に必要な成果物だけをこの Spike ディレクトリの `artifacts/` に保存する。
