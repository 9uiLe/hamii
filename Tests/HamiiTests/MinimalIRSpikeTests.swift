import Foundation
import XCTest
import HamiiCore

// Evidence-only candidate for adr/native-semantic-ir. This is not a persisted schema.
private struct ProbeDocument: Codable, Equatable {
    var scopes: [ArchitectureScope]
    var components: [ProbeComponent]
    var tokens: [DesignToken]
    var assets: [Asset]
    var screens: [ProbeScreen]
}

private struct ProbeComponent: Codable, Equatable {
    var id: EntityID
    var ownerScopeID: EntityID
    var variantAxes: [String: [String]]
    var propertyNames: [String]
    var slotNames: [String]
    var root: ProbeNode
}

private struct ProbeScreen: Codable, Equatable {
    var id: EntityID
    var scopeID: EntityID
    var root: ProbeNode
    var navigation: ProbeNavigation?
    var targetExtensions: [ProbeTargetExtension] = []
}

private enum ProbeNavigation: Codable, Equatable {
    case system(title: String, toolbar: [ProbeToolbarItem])
    case custom(layerID: EntityID)
}

private struct ProbeToolbarItem: Codable, Equatable {
    var id: EntityID
    var title: String
    var event: String
}

private struct ProbeNode: Codable, Equatable {
    var id: EntityID
    var name: String
    var payload: ProbePayload
    var effects: [ProbeEffect] = []
    var accessibilityLabel: String? = nil
}

private indirect enum ProbePayload: Codable, Equatable {
    case stack(axis: LayoutAxis, spacingTokenID: EntityID?, children: [ProbeNode])
    case scroll(content: ProbeNode)
    case text(ProbeText)
    case image(assetID: EntityID)
    case button(title: String, event: String)
    case overlay(children: [ProbeNode])
    case componentInstance(ProbeInstance)
}

private enum ProbeText: Codable, Equatable {
    case literal(String)
    case binding(path: String, fallback: String?)
}

private enum ProbeEffect: Codable, Equatable {
    case padding(tokenID: EntityID)
    case background(tokenID: EntityID)
}

private struct ProbeInstance: Codable, Equatable {
    var definitionID: EntityID
    var variants: [String: String]
    var properties: [String: String]
    var slots: [String: [ProbeNode]]
}

private struct ProbeTargetExtension: Codable, Equatable {
    var target: Framework
    var intent: ProbeTargetIntent
}

private enum ProbeTargetIntent: Codable, Equatable {
    case iOSSheetDetents([ProbeDetent])
}

private enum ProbeDetent: String, Codable { case medium, large }

// Escape hatches are outside portable payloads and unused by the corpus.
private struct ProbeNativeEscapeHatch: Codable, Equatable {
    var target: Framework
    var ownerID: EntityID
    var payloadVersion: Int
    var payload: String
}

private enum ProbeValidator {
    static func violations(_ document: ProbeDocument) -> [String] {
        let componentMap = Dictionary(document.components.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let scopeIDs = Set(document.scopes.map(\.id))
        let tokenMap = Dictionary(document.tokens.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let assetIDs = Set(document.assets.map(\.id))
        var result: [String] = []
        var ids = Set<EntityID>()
        func id(_ value: EntityID) {
            if !ids.insert(value).inserted { result.append("duplicateID") }
        }
        func node(_ value: ProbeNode) {
            id(value.id)
            switch value.payload {
            case .stack(_, let token, let children):
                if let token, tokenMap[token]?.kind != .spacing { result.append("invalidSpacingToken") }
                children.forEach(node)
            case .scroll(let content): node(content)
            case .text(let text):
                if case .binding(let path, _) = text, path.isEmpty { result.append("emptyBinding") }
            case .image(let assetID):
                if !assetIDs.contains(assetID) { result.append("missingAsset") }
            case .button(let title, let event):
                if title.isEmpty || event.isEmpty { result.append("invalidButton") }
                if value.accessibilityLabel == nil && title.isEmpty { result.append("missingLabel") }
            case .overlay(let children): children.forEach(node)
            case .componentInstance(let instance):
                guard let definition = componentMap[instance.definitionID] else {
                    result.append("missingDefinition")
                    return
                }
                for (axis, variant) in instance.variants where !(definition.variantAxes[axis] ?? []).contains(variant) {
                    result.append("unknownVariant")
                }
                for name in instance.properties.keys where !definition.propertyNames.contains(name) {
                    result.append("unknownProperty")
                }
                for name in instance.slots.keys where !definition.slotNames.contains(name) {
                    result.append("unknownSlot")
                }
                for children in instance.slots.values { children.forEach(node) }
            }
            for effect in value.effects {
                let token: EntityID
                let requiredKind: TokenKind
                switch effect {
                case .padding(let id): token = id; requiredKind = .spacing
                case .background(let id): token = id; requiredKind = .color
                }
                if tokenMap[token]?.kind != requiredKind { result.append("invalidEffectToken") }
            }
        }
        for scope in document.scopes { id(scope.id) }
        for token in document.tokens { id(token.id) }
        for asset in document.assets { id(asset.id) }
        for component in document.components {
            id(component.id)
            if !scopeIDs.contains(component.ownerScopeID) { result.append("missingComponentScope") }
            node(component.root)
        }
        for screen in document.screens {
            id(screen.id)
            if !scopeIDs.contains(screen.scopeID) { result.append("missingScreenScope") }
            node(screen.root)
            if case .system(_, let toolbar) = screen.navigation {
                for item in toolbar {
                    id(item.id)
                    if item.title.isEmpty || item.event.isEmpty { result.append("invalidToolbarItem") }
                }
            }
            for ext in screen.targetExtensions {
                switch ext.intent {
                case .iOSSheetDetents:
                    if ext.target != .swiftUI && ext.target != .uiKit { result.append("wrongTarget") }
                }
            }
        }
        return result
    }
}

final class MinimalIRSpikeTests: XCTestCase {
    private let scope = EntityID("scope_app")
    private let spacing = EntityID("token_spacing")
    private let color = EntityID("token_color")
    private let symbol = EntityID("asset_symbol")

    private func node(_ id: String, _ payload: ProbePayload, effects: [ProbeEffect] = []) -> ProbeNode {
        ProbeNode(id: EntityID(id), name: id, payload: payload, effects: effects)
    }

    private func fixture(_ name: String) -> ProbeDocument {
        let scopes = [ArchitectureScope(id: scope, name: "App", parentID: nil)]
        let tokens = [
            DesignToken(id: spacing, name: "spacing.md", kind: .spacing, ownerScopeID: scope, value: .literal("16")),
            DesignToken(id: color, name: "color.surface", kind: .color, ownerScopeID: scope, value: .literal("#FFFFFF"))
        ]
        let assets = [Asset(id: symbol, name: "person", ownerScopeID: scope, mediaType: "image/system", source: .system(name: "person"))]
        var components: [ProbeComponent] = []
        let root: ProbeNode
        var navigation: ProbeNavigation?
        var extensions: [ProbeTargetExtension] = []
        switch name {
        case "portable":
            var edit = node("edit", .button(title: "Edit", event: "editTapped"))
            edit.accessibilityLabel = "Edit profile"
            let content = node("content", .stack(axis: .vertical, spacingTokenID: spacing, children: [
                node("greeting", .text(.binding(path: "user.name", fallback: "Guest"))),
                node("avatar", .image(assetID: symbol)),
                edit
            ]))
            root = node("portable_root", .scroll(content: content), effects: [.padding(tokenID: spacing), .background(tokenID: color)])
        case "navigation":
            root = node("navigation_root", .scroll(content: node("navigation_text", .text(.literal("Catalog")))))
            navigation = .system(title: "Catalog", toolbar: [ProbeToolbarItem(id: EntityID("toolbar_add"), title: "Add", event: "addTapped")])
        case "component":
            let nested = ProbeComponent(id: EntityID("component_badge"), ownerScopeID: scope, variantAxes: [:], propertyNames: [], slotNames: [], root: node("badge_root", .text(.literal("Badge"))))
            let card = ProbeComponent(id: EntityID("component_card"), ownerScopeID: scope, variantAxes: ["size": ["small", "large"]], propertyNames: ["title"], slotNames: ["detail"], root: node("card_root", .stack(axis: .vertical, spacingTokenID: spacing, children: [
                node("nested_badge", .componentInstance(ProbeInstance(definitionID: nested.id, variants: [:], properties: [:], slots: [:])))
            ])))
            components = [nested, card]
            root = node("card_instance", .componentInstance(ProbeInstance(definitionID: card.id, variants: ["size": "large"], properties: ["title": "Profile"], slots: ["detail": [node("slot_text", .text(.literal("Details")))]])))
        case "divergent":
            root = node("divergent_root", .overlay(children: [node("sheet_content", .text(.literal("Details")))]))
            extensions = [ProbeTargetExtension(target: .swiftUI, intent: .iOSSheetDetents([.medium, .large]))]
        default: fatalError("Unknown corpus fixture")
        }
        return ProbeDocument(scopes: scopes, components: components, tokens: tokens, assets: assets, screens: [ProbeScreen(id: EntityID("screen_\(name)"), scopeID: scope, root: root, navigation: navigation, targetExtensions: extensions)])
    }

    func testFourTypedFixturesRoundTripWithoutChangingStableIDsOrOrdering() throws {
        for name in ["portable", "navigation", "component", "divergent"] {
            let original = fixture(name)
            XCTAssertEqual(ProbeValidator.violations(original), [], name)
            let decoded = try JSONDecoder().decode(ProbeDocument.self, from: JSONEncoder().encode(original))
            XCTAssertEqual(decoded, original, name)
            XCTAssertEqual(decoded.screens.map(\.id), original.screens.map(\.id), name)
            XCTAssertEqual(decoded.components.map(\.id), original.components.map(\.id), name)
            XCTAssertEqual(decoded.screens.first?.root.id, original.screens.first?.root.id, name)
        }
    }

    func testOrderedEffectsAreSemanticallyDifferentAndSurviveRoundTrip() throws {
        var first = fixture("portable")
        var reversed = first
        reversed.screens[0].root.effects.reverse()
        XCTAssertNotEqual(first, reversed)
        XCTAssertNotEqual(try JSONEncoder().encode(first), try JSONEncoder().encode(reversed))
        first = try JSONDecoder().decode(ProbeDocument.self, from: JSONEncoder().encode(first))
        reversed = try JSONDecoder().decode(ProbeDocument.self, from: JSONEncoder().encode(reversed))
        XCTAssertEqual(first.screens[0].root.effects, [.padding(tokenID: spacing), .background(tokenID: color)])
        XCTAssertEqual(reversed.screens[0].root.effects, [.background(tokenID: color), .padding(tokenID: spacing)])
    }

    func testTypedPayloadExcludesCrossKindFieldsAndValidatorRejectsInvalidReferences() {
        var document = fixture("portable")
        document.screens[0].root.payload = .image(assetID: EntityID("missing"))
        XCTAssertEqual(ProbeValidator.violations(document), ["missingAsset"])
        document = fixture("portable")
        document.screens[0].root.payload = .button(title: "Save", event: "")
        XCTAssertEqual(ProbeValidator.violations(document), ["invalidButton"])
        document = fixture("component")
        document.screens[0].root.payload = .componentInstance(ProbeInstance(definitionID: EntityID("missing"), variants: [:], properties: [:], slots: [:]))
        XCTAssertEqual(ProbeValidator.violations(document), ["missingDefinition"])
        document = fixture("navigation")
        document.screens[0].navigation = .system(title: "Catalog", toolbar: [ProbeToolbarItem(id: EntityID("bad_item"), title: "Add", event: "")])
        XCTAssertEqual(ProbeValidator.violations(document), ["invalidToolbarItem"])
        document = fixture("divergent")
        document.screens[0].targetExtensions = [ProbeTargetExtension(target: .jetpackCompose, intent: .iOSSheetDetents([.medium]))]
        XCTAssertEqual(ProbeValidator.violations(document), ["wrongTarget"])
        // A Scroll payload owns exactly one content node; a second structural root
        // cannot be constructed without switching to a different typed payload.
    }

    func testCurrentLayerValidationAcceptsUnrelatedOptionalPayloads() {
        var current = Document(name: "Current shape")
        let app = current.scopes[0].id
        current.assets = [Asset(id: symbol, name: "person", ownerScopeID: app, mediaType: "image/system", source: .system(name: "person"))]
        func accepted(_ layer: Layer, _ label: String) {
            current.screens = [Screen(id: EntityID("screen_current"), name: "Current", scopeID: app, root: layer)]
            XCTAssertTrue(DocumentValidator.validate(current).isEmpty, label)
        }
        accepted(Layer(id: EntityID("text_layer"), kind: .text, name: "Text", text: "Hello", assetID: symbol), "Text accepts an Image-only payload")
        accepted(Layer(id: EntityID("button_layer"), kind: .button, name: "Button", text: "Save"), "Button accepts no event")
        accepted(Layer(id: EntityID("scroll_layer"), kind: .scroll, name: "Scroll", children: [
            Layer(id: EntityID("child_one"), kind: .text, name: "One", text: "One"),
            Layer(id: EntityID("child_two"), kind: .text, name: "Two", text: "Two")
        ]), "Scroll accepts multiple structural roots")
        var override = Layer(id: EntityID("override_layer"), kind: .text, name: "Text", text: "Hello")
        override.targetOverrides = ["unknown.target": "untyped value"]
        accepted(override, "Target override accepts an unknown target")
    }

    func testCurrentShapeCanStoreFourCorpusFixturesButRequiresBagsForTwoIntents() throws {
        for name in ["portable", "navigation", "component", "divergent"] {
            var current = Document(name: name)
            let app = current.scopes[0].id
            let space = DesignToken(id: spacing, name: "spacing.md", kind: .spacing, ownerScopeID: app, value: .literal("16"))
            current.tokens = [space]
            current.assets = [Asset(id: symbol, name: "person", ownerScopeID: app, mediaType: "image/system", source: .system(name: "person"))]
            let root: Layer
            var navigation: NavigationConfiguration?
            switch name {
            case "portable":
                var text = Layer(id: EntityID("current_text"), kind: .text, name: "Greeting", text: "Guest")
                text.textBinding = "user.name"
                let image = Layer(id: EntityID("current_image"), kind: .image, name: "Avatar", assetID: symbol)
                var button = Layer(id: EntityID("current_button"), kind: .button, name: "Edit", text: "Edit")
                button.emittedEvent = "editTapped"
                button.accessibilityLabel = "Edit profile"
                let stack = Layer(id: EntityID("current_stack"), kind: .stack, name: "Content", children: [text, image, button], layout: Layout(axis: .vertical, spacingTokenID: spacing))
                var scroll = Layer(id: EntityID("current_scroll"), kind: .scroll, name: "Scroll", children: [stack])
                scroll.layout.paddingTokenID = spacing
                scroll.nativeIntent = "background(color.surface) after padding(spacing.md)"
                root = scroll
            case "navigation":
                root = Layer(id: EntityID("current_nav_root"), kind: .scroll, name: "Scroll", children: [Layer(id: EntityID("current_nav_text"), kind: .text, name: "Title", text: "Catalog")])
                navigation = .system(SystemNavigation(title: "Catalog", toolbarItems: [SystemToolbarItem(id: EntityID("current_toolbar"), title: "Add", emittedEvent: "addTapped")]))
            case "component":
                let badge = ComponentDefinition(id: EntityID("current_badge"), name: "Badge", ownerScopeID: app, root: Layer(id: EntityID("current_badge_root"), kind: .text, name: "Badge", text: "Badge"))
                let nested = Layer(id: EntityID("current_nested"), kind: .componentInstance, name: "Nested", component: ComponentInstance(definitionID: badge.id))
                let title = Layer(id: EntityID("current_card_title"), kind: .text, name: "Title", text: "Card")
                let slot = Layer(id: EntityID("current_card_slot"), kind: .stack, name: "Detail")
                var card = ComponentDefinition(id: EntityID("current_card"), name: "Card", ownerScopeID: app, root: Layer(id: EntityID("current_card_root"), kind: .stack, name: "Card", children: [title, nested, slot]))
                card.api.properties = [ComponentProperty(name: "title", kind: .text, targetPath: "current_card_title.text")]
                card.api.slots = [ComponentSlot(name: "detail", targetLayerID: slot.id)]
                card.variants = [ComponentVariant(id: EntityID("current_card_variant"), axis: "size", value: "large")]
                current.components = [badge, card]
                root = Layer(id: EntityID("current_card_instance"), kind: .componentInstance, name: "Card", component: ComponentInstance(definitionID: card.id, variantSelection: ["size": "large"], propertyValues: ["title": "Profile"], slotContent: ["detail": [Layer(id: EntityID("current_slot_text"), kind: .text, name: "Detail", text: "Details")]]))
            case "divergent":
                var overlay = Layer(id: EntityID("current_overlay"), kind: .overlay, name: "Overlay", children: [Layer(id: EntityID("current_sheet_text"), kind: .text, name: "Details", text: "Details")])
                overlay.targetOverrides = ["swiftUI.presentationDetents": "medium,large"]
                root = overlay
            default: fatalError("Unknown corpus fixture")
            }
            var screen = Screen(id: EntityID("current_screen_\(name)"), name: name, scopeID: app, root: root)
            screen.navigation = navigation
            current.screens = [screen]
            XCTAssertTrue(DocumentValidator.validate(current).isEmpty, name)
            XCTAssertEqual(try JSONDecoder().decode(Document.self, from: JSONEncoder().encode(current)), current, name)
            if name == "portable" { XCTAssertNotNil(current.screens[0].root.nativeIntent) }
            if name == "divergent" { XCTAssertFalse(current.screens[0].root.targetOverrides.isEmpty) }
        }
    }
}
