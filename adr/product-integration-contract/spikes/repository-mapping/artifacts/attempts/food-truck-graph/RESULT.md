# Food Truck × dependency graph contract — exploratory attempt 3

- Date: 2026-10-01 UTC. Source reset to `apple/sample-food-truck@3954a769e99f3cc53297d94f2b960ceb2665b3d6`; same Codex GPT-6 agent and direct file tools. The agent had seen attempts 1–2, so this is not blinded.
- Inputs: this directory's fixed `prompt.md` and `contract.json`, shared fixture/profile. Allowed edit: `App/Account/AccountView.swift` only.
- [Patch](final.patch.gz), SHA-256 (decompressed patch) `d677814175f3dc794ccbdd049501698326c93e860e584e2c4af210e9be1341ce`: 1 file, `+48/-11` lines. The baseline-equivalent iOS Simulator build passed. No target tests were available.
- AI review interval: 2026-10-01 08:19:51–08:20:01 UTC = 10 s. No independent human review; Human correction count remains **unmeasured**. AI reviewer correction candidates: semantic `0`, architecture/convention `0`, cosmetic `0`.

| Intent | Classification and exact target evidence |
| --- | --- |
| I01 displayName | correct — `AccountView.swift:25-27,119-122,139`. |
| I02 secondaryText | correct — `AccountView.swift:119-122,141`, derived from username. |
| I03 avatar | correct — `AccountView.swift:123,134`, specified system image. |
| I04 editProfile | correct — `AccountView.swift:27-30,147`, emitted closure. |
| I05 spacing | correct — `AccountView.swift:130,133,138`, 12 pt presentation constant. |
| I06 accessibility | correct — `AccountView.swift:136`, label derived from display name. |
| I07 system navigation | correct — existing `App/Navigation/ContentView.swift:42`. |
| I08 normal state | correct — `AccountView.swift:25-31`, authenticated branch displays enabled edit action. |
| I09 displayName binding | correct — observed `AccountStore.currentUser` supplies username to `Presentation`. |
| I10 secondaryText binding | correct — same observed username derives the secondary text in `Presentation`. |
| I11 edit destination | explicitly unresolved — `AccountView.swift:27-30,91-95`; no route was invented. |

Silent guess `0`; silent loss `0`. The graph-shaped input led to an explicit presentation value object, but this single sequential trial cannot establish that the graph representation caused the extra `+48/-11` lines.
