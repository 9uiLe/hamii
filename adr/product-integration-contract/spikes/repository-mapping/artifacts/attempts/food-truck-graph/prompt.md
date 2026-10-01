Integrate the following ProfileHeader UI intent into the pinned external SwiftUI repository. Use only the repository convention and allowed paths below. This is one isolated Spike attempt. Do not infer the edit-profile destination: leave it explicit and unresolved. Do not alter the hamii repository, dependency manifests, or project settings. Keep the patch buildable and report every semantic item I01-I11 as mapped to an exact code location, explicitly unresolved, incorrect, or silently lost. Record any new presentation state as new code, never as existing repository data.

Repository profile:

- Source: <https://github.com/apple/sample-food-truck> at `3954a769e99f3cc53297d94f2b960ceb2665b3d6`.
- Host: `App/Account/AccountView.swift`. `AccountView` reads `@EnvironmentObject AccountStore`, observes `FoodTruckModel`, and is placed under the native `NavigationStack` in `App/Navigation/ContentView.swift`.
- Data: `FoodTruckKit/Sources/Account/AccountStore.swift` exposes `@Published currentUser`; `FoodTruckKit/Sources/Account/User.swift` has `.authenticated(username:)`. The username is a grounded display-name source. No existing secondary-text or avatar profile data was found in those files. A repository-owned presentation value may be added for secondary text and the explicit system image may be used for avatar; count these as new integration code, not discovered repository data.
- Event: `AccountView` uses local view actions and direct store calls. No existing edit-profile destination was found in the inspected account view. `I11` remains unresolved; do not create a route.
- Allowed edits: `App/Account/AccountView.swift` and, if needed, one new `App/Account/ProfileHeader.swift` file. Avoid `FoodTruckKit` domain changes, authentication behavior, project settings, and asset binaries.


Contract representation: graph
{
  "nodes": [
    "I01 displayName",
    "I02 secondaryText",
    "I03 avatar",
    "I04 editProfile",
    "I05 spacing.profileHeader",
    "I06 avatarLabel",
    "I07 navigation.system",
    "I08 normal",
    "I09 displayNameSource",
    "I10 secondaryTextSource",
    "I11 editProfileDestination: unresolved"
  ],
  "edges": [
    "I09 -> I01",
    "I10 -> I02",
    "I01 -> I06",
    "I03 -> I06",
    "I08 -> I01",
    "I08 -> I02",
    "I08 -> I03",
    "I08 -> I04",
    "I04 -> I11",
    "ProfileHeader -> I07"
  ],
  "values": {
    "I03": "person.crop.circle.fill",
    "I05": "12 pt",
    "I06": "Profile avatar for {displayName}"
  }
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
