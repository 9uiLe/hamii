# SyncUps × dependency graph contract — exploratory attempt 6

- Date: 2026-10-01 UTC. Source reset to `pointfreeco/swift-composable-architecture@377da4061db10d26337a71bb279c506bb951f50f`; same Codex GPT-6 agent and direct file tools, with all prior attempts in context.
- Inputs: this directory's fixed `prompt.md` and `contract.json`, shared fixture/profile. Semantically edited only `Examples/SyncUps/SyncUps/SyncUpsList.swift`; Xcode's `Package.resolved` regeneration is excluded.
- [Patch](final.patch.gz), SHA-256 (decompressed patch) `88c9b2f3aaf1a8036946b518c0d009685db748123044a10b67a99dd726061a02`: 1 file, `+61/-0` lines. Baseline-equivalent iOS Simulator build and iOS 27 Simulator test passed; 21 Swift Testing tests, 12 pre-existing known issues. New event behavior was not exercised by those tests.
- AI review interval: 2026-10-01 08:28:48–08:28:57 UTC = 9 s. Independent Human correction count is **unmeasured**. AI reviewer correction candidates: semantic `0`, architecture/convention `0`, cosmetic `0`.

| Intent | Classification and exact target evidence |
| --- | --- |
| I01 displayName | correct — `SyncUpsList.swift:21,93,146-148,166`, new fixture-owned State. |
| I02 secondaryText | correct — `SyncUpsList.swift:94,146-148,167`, derived from shared count. |
| I03 avatar | correct — `SyncUpsList.swift:144,162`, specified system image. |
| I04 editProfile | correct — `SyncUpsList.swift:29,70-73,96,170`, store action. |
| I05 spacing | correct — `SyncUpsList.swift:158,161,165`, 12 pt presentation constant. |
| I06 accessibility | correct — `SyncUpsList.swift:151,164`, display-name-derived label. |
| I07 system navigation | correct — existing `AppFeature.swift:56`. |
| I08 normal state | correct — `SyncUpsList.swift:90-98`, enabled action displayed. |
| I09 displayName binding | correct — observable State flows into `ProfileHeaderPresentation`, then the view. |
| I10 secondaryText binding | correct — observed `@Shared syncUps` count flows into `ProfileHeaderPresentation`. |
| I11 edit destination | explicitly unresolved — `SyncUpsList.swift:70-73,176-182`; no route/effect was invented. |

Silent guess `0`; silent loss `0` by source audit. The graph-shaped input led to an explicit presentation value object, but the sequential context and one sample do not establish causal superiority or production contract choice.
