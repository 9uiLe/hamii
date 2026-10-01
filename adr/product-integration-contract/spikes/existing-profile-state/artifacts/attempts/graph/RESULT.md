# Graph attempt result — isolated external prototype

Target: `/tmp/hamii-integration-spike/targets/team-mino-graph` at baseline commit `dca2202f4be21869190d19bbcf223eb8646a2acd`. The external checkout remains uncommitted. No hamii production code, test, Domain model, or manifest was edited.

Review: 2026-10-01T10:56:16Z–2026-10-01T10:58:06Z. Source audit followed `initial.patch.gz`; `final.patch.gz` contains the post-audit cosmetic correction. Changed files: `Packages/FeatureProfile/Sources/FeatureProfile/Main/ProfileMainStore.swift` (+12/−0), `Packages/FeatureProfile/Sources/FeatureProfile/Main/ProfileMainContentView.swift` (+11/−3). Total: 2 files, +23/−3; no new file.

## Source-level semantic audit

Paths below are relative to the external target. “Correct” means the intent is evidenced in the prototype and its existing host; it does not imply visual verification.

| Item | Verdict | Exact source evidence |
| --- | --- | --- |
| I01 displayName | Correct | `Main/ProfileMainStore.swift:22,58,131` stores `Profile.nickname`; `Main/ProfileMainContentView.swift:72` displays `state.nickname`. Full prefix: `Packages/FeatureProfile/Sources/FeatureProfile/`. |
| I02 secondaryText | Correct | `Main/ProfileMainStore.swift:28-34` derives Korean date text from `createdAt`, with `가입일 정보 없음` for nil; `Main/ProfileMainContentView.swift:38-40` displays it with `.mhTypography`. |
| I03 avatar = `person.crop.circle.fill` | **Incorrect** against the graph value. `Main/ProfileMainContentView.swift:55-62` retains `MHAvatar(AvatarPalette.image(of: state.avatarColor))`. `Packages/ProfileSetupUI/Sources/ProfileSetupUI/AvatarPalette.swift:75-90` maps the product color to character art, including the plain variant for nil. Replacing this with the SF Symbol would discard the existing avatar behavior. This mismatch is explicit, not silently lost. |
| I04 editProfile | Correct | `Main/ProfileMainContentView.swift:70` sends the existing `.tapEditProfile`; `Main/ProfileMainStore.swift:216-217` emits `.pushProfileSetup`. |
| I05 spacing.profileHeader = 12 pt | Correct | `Main/ProfileMainContentView.swift:34` uses `Metric.profileHeaderSpacing`; its value is 12 at line 204. |
| I06 avatarLabel | Correct | `Main/ProfileMainContentView.swift:63-65` groups the avatar accessibility element and sets `Profile avatar for \(state.nickname)`. |
| I07 navigation.system | Correct | `Packages/FeatureProfile/Sources/FeatureProfile/ProfileTabView.swift:17,21-29` owns the existing `NavigationStack` and destination. |
| I08 normal | Correct | `Main/ProfileMainContentView.swift:33-41` renders the avatar and display inputs; lines 69-84 keep the edit button active. No new state case or `stateNote` was introduced. |
| I09 displayNameSource | Correct | `Main/ProfileMainStore.swift:58,131` seeds and refreshes nickname; `Packages/FeatureProfile/Sources/FeatureProfile/ProfileTabView.swift:51-53` passes live store state; `Main/ProfileMainContentView.swift:72` reads it. |
| I10 secondaryTextSource | Correct | `Packages/Domain/Sources/Domain/Entities/Profile.swift:12,18` defines `Profile.createdAt`; `Main/ProfileMainStore.swift:59,133` seeds and refreshes it; lines 28-34 compute the text read by `Main/ProfileMainContentView.swift:38`. |
| I11 editProfileDestination | Correct, source discovered | `Main/ProfileMainStore.swift:216-217` emits `.pushProfileSetup`; `Packages/FeatureProfile/Sources/FeatureProfile/ProfileCoordinator.swift:101-104` pushes `.profileSetup`; `Packages/FeatureProfile/Sources/FeatureProfile/ProfileTabView.swift:21-29` maps that route to `ProfileSetupScreen`; `ProfileCoordinator.swift:92-95` constructs its store in `.edit` mode. `Packages/FeatureProfile/Tests/FeatureProfileTests/ProfileCoordinatorTests.swift:13-20,35-44,85-98` tests route, edit mode, and store wiring. |

The graph supplies I08, I09, and I10 node/edge relationships. The current production screen-level `IntegrationContract` has no dedicated States or dependency graph field. The common canonical fixture supplies prose meaning and the nil-date requirement; the profile extract supplies `Profile.createdAt` as the semantic source. No fixture-owned business data was added.

## Correction candidates and disposition

- AI self-review applied correction counts: semantic **0**, architecture/convention **0**, cosmetic **1**. Strict I03 remains outstanding. The shell wrapper correction is separate from the source patch; these are not Human correction counts.
- Semantic: Using the requested `person.crop.circle.fill` as the visible avatar would replace the repository’s color mapped profile art and the plain variant for users without a selected color. Kept the product avatar; I03 remains incorrect against the contract value and needs a product decision if the symbol is mandatory.
- Architecture/convention: A separate edit route, Boolean, or destination would duplicate the existing reducer/coordinator path. Reused the proven route; no correction needed. The new date field is a projection of existing `Profile.createdAt`, not an independent profile fixture.
- Cosmetic: The initial patch’s English date comment and tight property spacing differed from the adjacent Korean source style. Corrected both in `final.patch.gz`.

## Gate

Exact command, run from `Packages/FeatureProfile`:

```sh
xcodebuild test -scheme FeatureProfile -destination 'platform=iOS Simulator,id=10849834-229F-4AB1-A1B3-88BBEB25B5CF' -derivedDataPath /tmp/hamii-integration-spike/derived-data-graph CODE_SIGNING_ALLOWED=NO
```

First attempt: Xcode test reported success with 30 tests in 3 suites, but the zsh wrapper exited 1 afterward because it assigned the read-only variable `status`. Full log: `/tmp/hamii-integration-spike/graph-xcodebuild-test.log`.

Retry: same Xcode command and DerivedData; wrapper captured `test_exit`. Exit status **0**. Full log: `/tmp/hamii-integration-spike/graph-xcodebuild-test-retry.log`. Bounded excerpt:

```text
✔ Suite ProfileCoordinatorTests passed after 0.005 seconds.
✔ Suite ProfileMainReducerTests passed after 0.005 seconds.
✔ Test run with 30 tests in 3 suites passed after 0.009 seconds.
** TEST SUCCEEDED **
```

The existing edit-profile reducer and coordinator tests passed. `git diff --check` passed. No runtime visual verification or independent Human correction measurement was performed. This is exploratory evidence, not a production integration.
