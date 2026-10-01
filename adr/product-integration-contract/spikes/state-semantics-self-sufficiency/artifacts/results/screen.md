# Screen contract-only state probe

- Target: Team MINO iOS `dca2202f4be21869190d19bbcf223eb8646a2acd` (verified with `git rev-parse HEAD`).
- Scope: the supplied screen `contract.json`, pinned target source, and the target's own convention documents. No source edits.
- UTC timing: recorded start **2026-10-01 11:50:21 UTC**; recorded end **2026-10-01 11:51:50 UTC**; elapsed **89 seconds**. The start clock was captured immediately after the packet/contract read; the end clock was captured after writing the result.

## What the contract actually says

`contract.json:2-8` names an “existing profile screen,” `ProfileHeader`, and four input labels: `I01 displayName`, `I02 secondaryText`, `I09 displayNameSource`, `I10 secondaryTextSource`. The “Source” entries are only names: no source expression, value, type, state, or mapping is supplied. `contract.json:22-24` interpolates `{displayName}` in an accessibility label, but likewise does not define its value or fallback. There is no state list, visibility rule, formatting rule, or condition involving `createdAt` anywhere in the contract. The three scenarios are probe inputs, not contract clauses.

## Scenario classification

| Scenario | I01 displayName: contract requirement and classification | I02 secondaryText: contract requirement and classification | Target repository observation (not evidence of hamii intent) |
|---|---|---|---|
| S0: profile unavailable **or** loading | No required value, empty behavior, or cache policy. **Ambiguous**: this scenario combines distinct target states. | No required text or visibility. **Insufficient**. | `ProfileMainState(profile: nil)` initializes `nickname` to `""` (`ProfileMainStore.swift:40-49`), while a cached profile seeds it (`ProfileCoordinator.swift:73-79`). Loading preserves the previous value; failure also leaves it intact (`ProfileMainStore.swift:108-130`). The coordinator retains the Store across tab visits (`ProfileCoordinator.swift:60-88`), and the view draws the existing `nickname` even during refresh (`ProfileTabView.swift:48-74`; `ProfileMainContentView.swift:61-78`). Thus S0 does not select one repository rendering either. |
| S1: profile loaded, `createdAt == nil` | No contract mapping from I01/I09 to profile fields. **Repository-discoverable** only: existing reducer copies `profile.nickname` to `state.nickname` (`ProfileMainStore.swift:119-122`) and view displays it (`ProfileMainContentView.swift:61-78`). | No contract mapping from I02/I10, nil fallback, or visibility rule. **Insufficient**. | `Profile.createdAt` is optional (`Profile.swift:8-18`), but `ProfileMainState` only stores nickname/avatar (`ProfileMainStore.swift:20-25, 47-55, 119-122`). The complete summary is avatar plus name row (`ProfileMainContentView.swift:31-40, 50-78`); no secondary text is rendered. |
| S2: profile loaded, `createdAt != nil` | Same gap and **repository-discoverable** existing nickname behavior as S1; contract does not say whether the date should alter the name. | No contract mapping, date relation, format, or visibility rule. **Insufficient**. | The model can carry a date (`Profile.swift:8-18`), but the reducer drops it and the current summary does not render secondary text (`ProfileMainStore.swift:20-25, 119-122`; `ProfileMainContentView.swift:31-78`). S1 and S2 are identical in current source rendering. |

Here, **repository-discoverable** reports only what the current app does. It does not promote that behavior into a contract requirement. The contract alone is **insufficient in all three scenarios for both bindings**: it never uniquely determines either rendered value. For S0, even repository inspection cannot choose between an empty and retained name without knowing cache/history.

## Minimal missing semantics

1. A binding-to-state relation for I01/I09: authoritative source (for example, whether `Profile.nickname` is intended), behavior before first load, during refresh with a last-known profile, and after failure. If S0 is to be testable as one case, specify cache presence or split it into first-load and refresh substates.
2. A binding-to-state relation for I02/I10: authoritative source or derivation; whether the text is omitted, empty, a placeholder, or another value for S0 and S1; and the required S2 value. If date-derived, specify formatter, calendar/locale/time zone, and whether updates depend on time.
3. Explicit visibility/placement rules for the two bindings in `ProfileHeader`, including whether secondary text exists in all, some, or no states. The target has no `ProfileHeader` type; its existing summary is inside `ProfileMainContentView.swift:31-78`.

A **state list alone is insufficient**: the contract needs binding-to-state rules. A dependency graph (e.g. `secondaryText <- profile.createdAt` plus formatting context) becomes necessary if I02 is derived or if multiple fields participate; no such dependency can be inferred as intended from the bare name `secondaryTextSource`. The current repository gives one possible implementation, not the missing product semantics.

## Safe patch plan

No implementation-safe patch can be chosen from this contract without silently guessing I01's loading/cache behavior and I02's content or visibility. Once the missing relations are specified, a patch can follow the target's MVI structure: place state and reducer changes in `Packages/FeatureProfile/Sources/FeatureProfile/Main/ProfileMainStore.swift`, render from state in `ProfileMainContentView.swift`, and verify the specified S0/S1/S2 transitions in `ProfileMainReducerTests.swift`. The target convention assigns one Store to a screen and makes views consume state (`.claude/docs/mvi-coordinator-di.md:245-263`); that is a structural path, not evidence for a subtitle rule.
