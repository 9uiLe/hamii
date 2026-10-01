# Fixed repository profiles for the six attempts

## Food Truck

- Source: <https://github.com/apple/sample-food-truck> at `3954a769e99f3cc53297d94f2b960ceb2665b3d6`.
- Host: `App/Account/AccountView.swift`. `AccountView` reads `@EnvironmentObject AccountStore`, observes `FoodTruckModel`, and is placed under the native `NavigationStack` in `App/Navigation/ContentView.swift`.
- Data: `FoodTruckKit/Sources/Account/AccountStore.swift` exposes `@Published currentUser`; `FoodTruckKit/Sources/Account/User.swift` has `.authenticated(username:)`. The username is a grounded display-name source. No existing secondary-text or avatar profile data was found in those files. A repository-owned presentation value may be added for secondary text and the explicit system image may be used for avatar; count these as new integration code, not discovered repository data.
- Event: `AccountView` uses local view actions and direct store calls. No existing edit-profile destination was found in the inspected account view. `I11` remains unresolved; do not create a route.
- Allowed edits: `App/Account/AccountView.swift` and, if needed, one new `App/Account/ProfileHeader.swift` file. Avoid `FoodTruckKit` domain changes, authentication behavior, project settings, and asset binaries.

## SyncUps

- Source: <https://github.com/pointfreeco/swift-composable-architecture/tree/main/Examples/SyncUps> at `377da4061db10d26337a71bb279c506bb951f50f`.
- Host: `Examples/SyncUps/SyncUps/SyncUpsList.swift` within the app's native `NavigationStack` in `Examples/SyncUps/SyncUps/AppFeature.swift`.
- State/actions: `SyncUpsList.State` is `@ObservableState`, and UI actions enter `SyncUpsList.Action` through `store.send`. `AppFeature` scopes this feature. There is no profile domain in these inspected files. A fixture-owned presentation state can be added inside `SyncUpsList` for this experiment; it must not be described as existing product data.
- Event: add a reducer action for `I04` if the integration maps it to store wiring. `I11` remains unresolved; do not create a route, effect, or persistence API.
- Allowed edits: `Examples/SyncUps/SyncUps/SyncUpsList.swift` and, if needed, one new `Examples/SyncUps/SyncUps/ProfileHeader.swift` file. Avoid framework sources, package manifests, project settings, and assets.

Both targets use the same `profile-header-fixture.json`. `contract-shapes.json` changes only how that intent is presented. Any attempt that needs an extra target file must record the reason and count it as a scope change. `Package.resolved` changes from Xcode resolution are environment artifacts and are not part of the semantic patch.
