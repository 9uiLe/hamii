# Component contract self-sufficiency probe

Target: Team MINO at `dca2202f4be21869190d19bbcf223eb8646a2acd`. Scope: packet `contract.json`, pinned target source, and target convention documentation. No source changes.

## Contract evidence and classification

The contract defines `ProfileHeader` and exposes `I01 displayName` and `I02 secondaryText` (`contract.json:2-7`). Its bindings only name `I09 displayNameSource -> I01` and `I10 secondaryTextSource -> I02` (`:9-12`); the source expressions, values, fallback rules, and state predicates are absent. Its sole state is `I08 normal` (`:16-18`), with no definition or mapping to profile availability or `createdAt`. `I06 avatarLabel = Profile avatar for {displayName}` (`:20-23`) establishes reuse of whatever `displayName` becomes, not the value of `displayName` itself. No contract field relates `secondaryText` to `createdAt`.

| Scenario | What the contract itself uniquely requires for I01 / I02 | Classification | What pinned repository source reveals, without proving contract intent |
|---|---|---|---|
| S0: profile unavailable or loading | Neither value, visibility, placeholder, nor whether a previously cached profile may be shown. `normal` has no stated applicability. | **Ambiguous** for both; contract **insufficient**. | The current state starts with `profile?.nickname ?? ""` (`Packages/FeatureProfile/Sources/FeatureProfile/Main/ProfileMainStore.swift:40-55`), and the coordinator supplies a last-known profile (`Packages/FeatureProfile/Sources/FeatureProfile/ProfileCoordinator.swift:73-85`). Loading does not clear this value (`ProfileMainStore.swift:108-117`); a failed refresh preserves it (`:124-130`). Thus even the repository can show an empty or cached name under S0, depending on history. Its current view has no secondary text (`ProfileMainContentView.swift:33-40,61-78`). |
| S1: profile loaded, `createdAt == nil` | I09/I10 specify destinations only. They do not say whether I01 uses nickname or whether I02 is absent, empty, a fixed phrase, or derived from another field. | **Repository-discoverable** for the current I01 implementation; **ambiguous** for contract I01 and I02, so contract **insufficient**. | `Profile` has `nickname` and optional `createdAt` (`Packages/Domain/Sources/Domain/Entities/Profile.swift:8-18`). On load, state receives `profile.nickname` and avatar color, but not `createdAt` (`ProfileMainStore.swift:119-122`); the view renders `Text(state.nickname)` (`ProfileMainContentView.swift:61-78`). There is no secondary text in that summary (`:33-40,61-78`). |
| S2: profile loaded, `createdAt != nil` | Same as S1. The contract does not mention `createdAt` or define any condition or formatter for I02. | **Repository-discoverable** for the current I01 implementation; **ambiguous** for contract I01 and I02, so contract **insufficient**. | `createdAt` exists in the domain model (`Profile.swift:12,14-18`), but the current state projects only nickname and avatar color (`ProfileMainStore.swift:20-25,47-55,119-122`). The same name view renders for either `createdAt` value (`ProfileMainContentView.swift:61-78`), and no secondary text is present. |

`repository-discoverable` above describes existing Team MINO behavior only. It is not a claim that the component contract orders that behavior. The target's MVI convention makes state the view input and routes loaded values through a response action (`.claude/docs/mvi-coordinator-di.md:67-69,96-123`), so implementing new state-sensitive text needs an explicit projection and rendering rule.

## Minimal missing information

1. Resolve `I09 displayNameSource` to an actual source or expression, including the S0 cached/loading/unavailable behavior, fallback, and whether I01 remains visible.
2. Resolve `I10 secondaryTextSource` to an actual source or expression. State whether I02 is shown in S0, S1, and S2; if it depends on `createdAt`, provide the nil rule, formatting/localization/time-zone rule, and sample expected outputs. If it is independent, name that dependency instead.
3. Define `I08 normal` and its relationship to the three scenarios, including whether loading and unavailable are distinct states and whether last-known data is eligible.

A **state list alone is not enough**: even adding `loading`, `unavailable`, and `loaded` would leave both binding outputs undefined. At minimum, supply a **binding-to-state relation** with the source expressions and per-state output/visibility/fallback. A **dependency graph** is additionally needed if `secondaryText` is a derived value (for example, from `createdAt`, display name, current date, or localization), to identify inputs and recomputation; the present packet does not establish such a dependency.

## Safe patch plan

No safe content patch is possible from this contract alone. A patch that uses nickname for I01, suppresses I02, or formats `createdAt` for I02 would silently choose product semantics. Once the missing rules are supplied, map the defined sources into the existing `ProfileMainState`/reducer (`ProfileMainStore.swift:20-55,101-130`), render I01/I02 in the profile summary (`ProfileMainContentView.swift:33-78`), and cover S0 with and without cached profile plus S1/S2 in focused tests. Preserve the target's state-driven view and response-action convention (`.claude/docs/mvi-coordinator-di.md:96-123`).

## Timing

- Start UTC: 2026-10-01T11:50:30Z
- End UTC: 2026-10-01T11:51:41Z
- Elapsed wall time: 71 seconds
