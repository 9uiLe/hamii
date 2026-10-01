# Food Truck × component contract — exploratory attempt 1

- Date: 2026-10-01 UTC. Source: `apple/sample-food-truck@3954a769e99f3cc53297d94f2b960ceb2665b3d6` (unchanged baseline before attempt).
- AI/tool condition: Codex GPT-6 root agent in the ongoing hamii conversation, direct file tools. This attempt was not blinded from repository preflight; later attempts will also have knowledge carryover.
- Inputs: this directory's `prompt.md` and `contract.json`, plus `../../profile-header-fixture.json` and `../../repository-profiles.md`. Allowed path was `App/Account/AccountView.swift`; no target dependency/project setting changes.
- Initial generated diff: [initial.patch](initial.patch.gz), SHA-256 (decompressed patch) `5bdc408aed247d488c187f1d2aca636c73287d06b3143afe9740b61ec3531ea9`. Baseline-equivalent `xcodebuild ... build` passed, but review found the closing `Form` brace moved before existing controls. This was a semantic regression that build success did not detect.
- Review interval for initial diff: 2026-10-01 08:13:50–08:14:25 UTC = 35 s, starting at opening the diff and ending after classification and correction list. The reviewer was the same AI agent, **not an independent human**. Human correction count is unmeasured.
- AI reviewer corrections: semantic `2` (restore `Form` boundary; derive secondary text from the observed username rather than a signed-in Boolean that is constant within this branch), architecture/convention `0`, cosmetic `0`.
- Corrected diff: [final.patch](final.patch.gz), SHA-256 (decompressed patch) `4e1ef98a8e0ca47b7570a78a2022ed472d96bf24357a56cafd3a22328b530668`. Changed files `1`, added/deleted LOC `42/12`. Same iOS Simulator build command passed again (`** BUILD SUCCEEDED **`). Food Truck declares no test target, so target tests were not run. This is build evidence only, not UI execution evidence.

| Intent | Final classification | Evidence in target source |
| --- | --- | --- |
| I01 displayName | correct | `AccountView.swift:25-28` takes authenticated `username` from `AccountStore.currentUser`. |
| I02 secondaryText | correct | `AccountView.swift:29` derives visible secondary text from `username`; this is new presentation wording. |
| I03 avatar asset | correct | `AccountView.swift:127` uses the specified system image. |
| I04 editProfile event | correct | `AccountView.swift:30-33,140` emits the button closure and records activation. |
| I05 spacing token | correct | `AccountView.swift:123,126,131` has one app-local 12 pt presentation constant. |
| I06 avatar a11y label | correct | `AccountView.swift:129` uses the specified label with display name. |
| I07 native navigation | correct | Existing `App/Navigation/ContentView.swift:42` hosts the account view in `NavigationStack`. |
| I08 normal state | correct | `AccountView.swift:25-35` renders the available control for the authenticated state. |
| I09 displayName binding | correct | `AccountStore.currentUser` drives `username` and the view recomputes the property. |
| I10 secondaryText binding | correct | The same observed `username` drives the derived secondary text. |
| I11 edit destination | unresolved | `AccountView.swift:30-33,95-99` gives an explicit unavailable alert; no route was invented. |

Silent guess `0`; silent loss `0` after correction. The initial patch would have failed the semantic review criterion despite a green build. This is one attempt, not evidence that the component contract outperforms the other shapes.
