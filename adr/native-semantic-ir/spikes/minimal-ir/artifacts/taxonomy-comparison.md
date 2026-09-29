# Minimal IR corpus comparison

Evidence scope: test-only Swift model in the frozen `MinimalIRSpikeTests.swift` source in this Spike artifact directory, five focused XCTest cases, and [corpus-matrix.json](corpus-matrix.json). The matrix is an **IR planning** loss report, not a claim that current Preview or generators implement these mappings. No framework source was generated or executed.

## Corpus and representation

| Fixture | Required intent | Current `Layer` / `Screen` | Test-only typed candidate |
| --- | --- | --- | --- |
| Portable content | Stack, Scroll, binding with fallback, system asset, Button event, spacing token, accessibility label | Typed fields and separate Token/Asset refs | Payload cases and separate refs |
| Portable content | Padding followed by background | `Layout.paddingTokenID` plus `nativeIntent` string; order is not a typed relation | Ordered `ProbeEffect` array |
| System navigation | Title, toolbar action, scroll content | `Screen.navigation` is typed and separate from root | Typed screen system semantics remain separate |
| Reusable component | Definition, nested instance, variant, property, slot | Separate `ComponentDefinition` graph and `ComponentInstance` ref | Separate graph with typed instance payload |
| Target divergent | Portable overlay plus SwiftUI sheet detents | Overlay is typed; detents require `targetOverrides` string | Overlay payload plus explicit SwiftUI target extension; other targets report loss |

The machine-readable corpus has **17 required semantic intents**: 15 are represented by typed current fields or domain graphs, and 2 require generic strings. The candidate represents all 17 with typed payload, typed ordered effect, typed screen semantics, separate graph, or an explicit target extension. One corpus intent uses a target extension. It uses no native escape hatch. These counts concern the selected corpus only.

## Invalid-state pressure

Four malformed current states pass `DocumentValidator`: Text with an image-only asset field, Button without an event, Scroll with two structural roots, and an unknown target key in `targetOverrides`. Current validation correctly rejects some other invalid states, including missing Component instance data and an empty toolbar event; this Spike does not claim the current validator is generally absent. The typed prototype makes cross-kind payload and multiple Scroll roots unconstructable in its type model. Its focused validator rejects missing asset/Component references, empty Button/toolbar events, and an iOS-only extension assigned to Jetpack Compose. This is five runtime rejection probes plus two type-shape exclusions, not a complete validity proof.

## Ordering and stable identity

The prototype stores padding and background as an ordered list. A→B and B→A encode differently; both round-trip with their order intact. Four fixtures round-trip with semantic equality and stable Screen/Component/root node IDs. The probe does not exercise production Canonical serialization, migration, editor mutation, or target lowering, so those remain implementation questions. It also does not assert JSON byte identity.

## System Navigation and Toolbar ownership

Ordinary visual nodes make the bar appear to be content inside the root tree. That loses its separate lifecycle and platform ownership. The current `Screen.navigation` and candidate screen system semantics keep the content root distinct. This matches Apple’s [SwiftUI navigation structure](https://developer.apple.com/documentation/swiftui/understanding-the-navigation-stack) and UIKit’s [navigation controller ownership of navigation bar and toolbar](https://developer.apple.com/documentation/uikit/uinavigationcontroller). Compose [TopAppBar is a composable placed in Scaffold](https://developer.android.com/develop/ui/compose/components/app-bars), so mapping an Apple system bar to it is an **approximation**, not a proven exact translation. Compose Multiplatform [navigation uses a separate navigation library](https://kotlinlang.org/docs/multiplatform/compose-navigation-routing.html). The same screen-level intent can be planned for all targets while recording that ownership differs.

Custom navigation remains an ordinary Layer tree referenced by the screen. No candidate stores a system bar as a free-positioned rectangle.

## Target lowering and explicit loss

`corpus-matrix.json` reports a value for SwiftUI, UIKit, Jetpack Compose, and Compose Multiplatform for every intent. Apple system-image identity has no supplied Android mapping, so the Android targets are `unsupported` in this corpus. The SwiftUI sheet-detent extension is `targetSpecific`; UIKit and both Compose targets are `unsupported` by this **candidate**, even though UIKit has a [sheet detent API](https://developer.apple.com/documentation/uikit/uisheetpresentationcontroller) and SwiftUI has [`presentationDetents`](https://developer.apple.com/documentation/swiftui/view/presentationdetents%28_%3A%29). A future UIKit mapping requires its own explicit extension rather than interpreting a SwiftUI key. Android [ModalBottomSheet](https://developer.android.com/develop/ui/compose/quick-guides/content/create-bottom-sheet) does not itself establish equivalence with this Apple detent configuration.

Bindings and event handlers are represented in IR but marked `externalIntegrationRequired` for production wiring. Modifier order matters in [Jetpack Compose](https://developer.android.com/develop/ui/compose/modifiers), which supports preserving an ordered effect sequence rather than flattening it. All unsupported and approximate cells are explicit; silent-loss count is zero **for the classification table**. Runtime lowering equivalence is untested.

## Candidate boundary and remaining risks

A small typed payload shape can preserve current stable IDs and the separate Scope/Component/Token/Asset graphs. The smallest demonstrated additions are ordered effects and a versioned, target-qualified extension. `ProbeNativeEscapeHatch` illustrates an isolated boundary with target, semantic owner, and payload version; no fixture uses it. A production escape hatch, ownership validation, broader presentation semantics, and exact framework capability sets remain unresolved. The candidate's `iOSSheetDetents` case is a deliberately narrow probe, not a selected production API.

The semantic units passed to `adr/capability-contract` should be node kind, binding/event support, ordered effect kind, system navigation/toolbar, system asset mapping, and target extension. This Spike does not decide capability registry granularity.

## Outcome

The typed candidate passes the selected corpus and validation gates, while the current model needs strings for two intents and accepts four malformed optional-field combinations. This supports a typed-payload direction for a **focused ADR decision**, but it is not production implementation evidence. In particular, target lowering and migration still need design after that decision.
