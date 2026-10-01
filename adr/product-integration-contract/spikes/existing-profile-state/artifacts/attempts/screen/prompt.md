# Isolated existing-profile-state attempt: screen

Work only in `/tmp/hamii-integration-spike/targets/team-mino-screen` and this attempt artifact directory. The target must remain at `dca2202f4be21869190d19bbcf223eb8646a2acd` before edits. Do not read any other attempt prompt, contract, patch, result, or review. This is a fresh-context attempt, not a production hamii change. Do not push the external repository.

Integrate the same ProfileHeader semantic intent into the target's existing profile screen. Reuse existing product profile data and the existing edit action/path/destination. Do not invent parallel business state or a route. The destination mapping is not provided by the profile: inspect target source and tests and report exact evidence, or leave it explicitly unresolved. Preserve unrelated profile settings, product behavior, and module boundaries. The screen contract has no dedicated States or dependency graph field; do not add a `stateNote` or extra field to it. You may use the common semantic fixture, but record when it supplies meaning absent from this contract shape.

Read the fixed repository profile and source files as needed. Edit only allowed target files. Produce an initial patch, perform a source-level semantic audit of I01-I11, make necessary corrections, then run the fixed baseline-equivalent test gate. Record failures and retries. The existing edit-profile reducer/coordinator tests must pass. Report each item as correct with exact source path and line, explicitly unresolved, incorrect, or silently lost. Report any semantic, architecture/convention, and cosmetic correction candidates, review start/end timestamps, changed-file and +/- line counts, build/test command and exit status, and test counts. Independent Human corrections are unmeasured. Do not claim a production integration or runtime visual verification.

## Fixed repository profile

# Fixed target convention extract — Team MINO iOS

- Source: <https://github.com/mash-up-kr/Team-MINO-iOS> at `dca2202f4be21869190d19bbcf223eb8646a2acd`; Apache-2.0 `LICENSE` is included as `TARGET-LICENSE.txt`. The external checkout and build output stay outside hamii.
- `Packages/FeatureProfile` is the scoped target. Its `FeatureProfile` scheme has a baseline of 30 passing tests in 3 suites on the iOS 27 Simulator. The tested package uses local `Domain`, `MVI`, `FlowCoordination`, `DesignSystem`, and `ProfileSetupUI` packages.
- Repository convention: screen state/action/navigation and reducer live in `Main/ProfileMainStore.swift`; pure markup receives `state + send` in `Main/ProfileMainContentView.swift`; the coordinator owns navigation. Source rule: `.claude/docs/mvi-coordinator-di.md` says "화면 전환은 `.navigate`로 Coordinator에 넘깁니다" (screen transitions go to the coordinator). Keep these responsibilities intact.
- Repository convention: display text uses `.mhTypography` and existing `MH*` components when a matching component exists; `Packages/DesignSystem/README.md` states "그 외 모든 텍스트(라벨·버튼·본문·타이틀 등)는 `.mhTypography(...)` (SUITE)". Keep unrelated profile settings and actions intact.
- Existing product user data lives in the `Domain.Profile` model and profile feature state. The fixture identifies `Profile.createdAt` as the semantic source for secondary membership text; read the source and record the exact mapping locations. No fixture-owned profile/business data may be added.
- The edit-profile destination mapping is **withheld here**. It exists in target source. Inspect the existing reducer action, navigation effect, coordinator route and tests to prove the mapping. If evidence is insufficient, report unresolved. Do not add a parallel route, alert, Bool, or destination.
- Allowed edits: `Packages/FeatureProfile/Sources/FeatureProfile/Main/ProfileMainStore.swift`, `Packages/FeatureProfile/Sources/FeatureProfile/Main/ProfileMainContentView.swift`, and optionally one new file under that same `Main/` directory if needed. Read any target source and tests. Do not edit tests, Domain model, package/project manifests, build settings, unrelated UI, or hamii production code. A new file must be counted and justified.
- Fixed gate from `Packages/FeatureProfile`: `xcodebuild test -scheme FeatureProfile -destination 'platform=iOS Simulator,id=10849834-229F-4AB1-A1B3-88BBEB25B5CF' -derivedDataPath <attempt-specific outside-hamii path> CODE_SIGNING_ALLOWED=NO`. Report exact exit status and passing test count. Existing edit-profile reducer/coordinator tests must remain in the run.

All three attempts receive this same extract. It identifies source boundaries but does not supply an edit destination mapping or extra state/dependency fields to the screen-level contract.

## Contract representation: screen

```json
{
  "screen": "existing profile screen",
  "component": "ProfileHeader",
  "inputs": [
    "I01 displayName",
    "I02 secondaryText",
    "I09 displayNameSource",
    "I10 secondaryTextSource"
  ],
  "events": [
    "I04 editProfile"
  ],
  "assets": [
    "I03 avatar: person.crop.circle.fill"
  ],
  "tokenIDs": [
    "I05 spacing.profileHeader = 12 pt"
  ],
  "nativeIntents": [
    "I07 navigation.system"
  ],
  "accessibilityLabels": [
    "I06 Profile avatar for {displayName}"
  ]
}
```

## Common canonical semantic fixture

```json
{
  "fixtureVersion": 2,
  "component": "ProfileHeader",
  "host": "existing native navigation screen",
  "intent": [
    {
      "id": "I01",
      "kind": "input",
      "name": "displayName",
      "type": "String",
      "meaning": "visible profile name, supplied by host state"
    },
    {
      "id": "I02",
      "kind": "input",
      "name": "secondaryText",
      "type": "String",
      "meaning": "visible Korean membership-date secondary text derived from the existing product Profile.createdAt; when date is nil show 가입일 정보 없음; no new profile fixture data"
    },
    {
      "id": "I03",
      "kind": "asset",
      "name": "avatar",
      "type": "systemImage",
      "value": "person.crop.circle.fill"
    },
    {
      "id": "I04",
      "kind": "event",
      "name": "editProfile",
      "meaning": "user activates Edit profile"
    },
    {
      "id": "I05",
      "kind": "token",
      "name": "spacing.profileHeader",
      "value": 12,
      "unit": "pt"
    },
    {
      "id": "I06",
      "kind": "accessibility",
      "name": "avatarLabel",
      "value": "Profile avatar for {displayName}"
    },
    {
      "id": "I07",
      "kind": "nativeIntent",
      "name": "navigation.system",
      "meaning": "host uses native NavigationStack semantics"
    },
    {
      "id": "I08",
      "kind": "state",
      "name": "normal",
      "meaning": "display inputs and make Edit profile available"
    },
    {
      "id": "I09",
      "kind": "binding",
      "name": "displayNameSource",
      "target": "I01",
      "meaning": "host state changes refresh displayed name"
    },
    {
      "id": "I10",
      "kind": "binding",
      "name": "secondaryTextSource",
      "target": "I02",
      "meaning": "host state changes refresh displayed secondary text"
    },
    {
      "id": "I11",
      "kind": "repositoryMapping",
      "name": "editProfileDestination",
      "source": "I04",
      "status": "sourceDiscoveryRequired",
      "meaning": "the existing edit-profile destination is not mapped in the repository profile; discover it from exact source evidence or mark unresolved, never invent a route"
    }
  ]
}
```
