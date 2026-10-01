Integrate the following ProfileHeader UI intent into the pinned external SwiftUI repository. Use only the repository convention and allowed paths below. This is one isolated Spike attempt. Do not infer the edit-profile destination: leave it explicit and unresolved. Do not alter the hamii repository, dependency manifests, or project settings. Keep the patch buildable and report every semantic item I01-I11 as mapped to an exact code location, explicitly unresolved, incorrect, or silently lost. Record any new presentation state as new code, never as existing repository data.

Repository profile:

- Source: <https://github.com/pointfreeco/swift-composable-architecture/tree/main/Examples/SyncUps> at `377da4061db10d26337a71bb279c506bb951f50f`.
- Host: `Examples/SyncUps/SyncUps/SyncUpsList.swift` within the app's native `NavigationStack` in `Examples/SyncUps/SyncUps/AppFeature.swift`.
- State/actions: `SyncUpsList.State` is `@ObservableState`, and UI actions enter `SyncUpsList.Action` through `store.send`. `AppFeature` scopes this feature. There is no profile domain in these inspected files. A fixture-owned presentation state can be added inside `SyncUpsList` for this experiment; it must not be described as existing product data.
- Event: add a reducer action for `I04` if the integration maps it to store wiring. `I11` remains unresolved; do not create a route, effect, or persistence API.
- Allowed edits: `Examples/SyncUps/SyncUps/SyncUpsList.swift` and, if needed, one new `Examples/SyncUps/SyncUps/ProfileHeader.swift` file. Avoid framework sources, package manifests, project settings, and assets.


Contract representation: screen
{
  "screen": "existing account/list screen",
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
  ],
  "stateNote": "I08 normal (the production IntegrationContract has no dedicated states field)",
  "unresolvedMappings": [
    "I11 editProfileDestination"
  ]
}

Canonical semantic fixture:
{
  "fixtureVersion": 1,
  "component": "ProfileHeader",
  "host": "existing native navigation screen",
  "intent": [
    { "id": "I01", "kind": "input", "name": "displayName", "type": "String", "meaning": "visible profile name, supplied by host state" },
    { "id": "I02", "kind": "input", "name": "secondaryText", "type": "String", "meaning": "visible secondary profile text, supplied by host state" },
    { "id": "I03", "kind": "asset", "name": "avatar", "type": "systemImage", "value": "person.crop.circle.fill" },
    { "id": "I04", "kind": "event", "name": "editProfile", "meaning": "user activates Edit profile" },
    { "id": "I05", "kind": "token", "name": "spacing.profileHeader", "value": 12, "unit": "pt" },
    { "id": "I06", "kind": "accessibility", "name": "avatarLabel", "value": "Profile avatar for {displayName}" },
    { "id": "I07", "kind": "nativeIntent", "name": "navigation.system", "meaning": "host uses native NavigationStack semantics" },
    { "id": "I08", "kind": "state", "name": "normal", "meaning": "display inputs and make Edit profile available" },
    { "id": "I09", "kind": "binding", "name": "displayNameSource", "target": "I01", "meaning": "host state changes refresh displayed name" },
    { "id": "I10", "kind": "binding", "name": "secondaryTextSource", "target": "I02", "meaning": "host state changes refresh displayed secondary text" },
    { "id": "I11", "kind": "repositoryMapping", "name": "editProfileDestination", "source": "I04", "status": "intentionallyUnknown", "meaning": "do not create a navigation route without target repository evidence" }
  ]
}


Deliver: patch, mapping table, unresolved mapping, build/test result, changed files/LOC, and correction candidates.
