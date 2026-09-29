import Foundation
import XCTest
import HamiiCore
import HamiiApplication
import HamiiFormat
import HamiiGeneration

final class FormatV1LayerGoldenTests: XCTestCase {
    private func example() -> Layer {
        let text = Layer(id: EntityID("layer_text"), kind: .text, name: "Title", text: "Guest")
        var bound = text
        bound.textBinding = "user.name"
        bound.accessibilityLabel = "User name"
        // Format v1 accepts a cross-kind asset reference; preserve its bytes without granting it new UI semantics.
        bound.assetID = EntityID("asset_cross_kind")

        let image = Layer(id: EntityID("layer_image"), kind: .image, name: "Avatar", assetID: EntityID("asset_avatar"))
        var button = Layer(id: EntityID("layer_button"), kind: .button, name: "Edit", text: "Edit")
        button.emittedEvent = "editTapped"
        button.interactionID = EntityID("interaction_edit")
        var overlay = Layer(id: EntityID("layer_overlay"), kind: .overlay, name: "Overlay", children: [image, button])
        overlay.nativeIntent = "system.overlay"
        overlay.targetOverrides = ["swiftUI": "native"]

        let scroll = Layer(id: EntityID("layer_scroll"), kind: .scroll, name: "Scroll", children: [bound, overlay])
        let slot = Layer(id: EntityID("layer_slot"), kind: .text, name: "Detail", text: "Nested")
        let instance = ComponentInstance(definitionID: EntityID("component_card"), variantSelection: ["size": "large"], propertyValues: ["title": "Card"], slotContent: ["detail": [slot]], allowedOverrides: ["layer_slot.text": "Override"])
        let component = Layer(id: EntityID("layer_component"), kind: .componentInstance, name: "Card", component: instance)
        return Layer(id: EntityID("layer_root"), kind: .stack, name: "Root", children: [scroll, component], layout: Layout(axis: .vertical, spacingTokenID: EntityID("token_spacing"), paddingTokenID: EntityID("token_padding")))
    }

    private func encoded(_ layer: Layer) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        var bytes = try encoder.encode(layer)
        bytes.append(0x0A)
        return bytes
    }

    func testFormatV1LayerBytesAndRoundTrip() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/format-v1-layer.json")
        let actual = try encoded(example())
        let original = try Data(contentsOf: fixture)
        XCTAssertEqual(actual, original)
        let decoded = try JSONDecoder().decode(Layer.self, from: original)
        XCTAssertEqual(try encoded(decoded), original)
        XCTAssertEqual(decoded, example())
        XCTAssertEqual(decoded.payload, .stack)
        guard case .scroll = decoded.children[0].payload,
              case .text(let bound) = decoded.children[0].children[0].payload,
              case .componentInstance(let component) = decoded.children[1].payload else {
            return XCTFail("The Format v1 node kinds must decode to their typed payloads")
        }
        XCTAssertEqual(decoded.children[0].children.count, 2)
        XCTAssertEqual(bound.value, "Guest")
        XCTAssertEqual(bound.binding, "user.name")
        XCTAssertEqual(decoded.children[0].children[0].assetID, EntityID("asset_cross_kind"))
        XCTAssertEqual(component.instance?.slotContent["detail"]?.first?.text, "Nested")
    }

    func testStarterScreenShardBytesRemainUnchanged() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("Samples/Starter/screens")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let original = try Data(contentsOf: file)
            let screen = try JSONDecoder().decode(Screen.self, from: original)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            var actual = try encoder.encode(screen)
            actual.append(0x0A)
            XCTAssertEqual(actual, original, file.lastPathComponent)
        }
    }

    func testFormatV1ValidationRulesKeepTheirEntityAndSeverity() throws {
        var document = Document(name: "Format v1 diagnostics")
        let scope = try XCTUnwrap(document.scopes.first?.id)
        var text = Layer(id: EntityID("layer_missing_text"), name: "Text", payload: .text(TextLayerPayload(binding: "")))
        text.assetID = EntityID("asset_missing")
        var button = Layer(id: EntityID("layer_missing_button"), name: "Button", payload: .button(ButtonLayerPayload(emittedEvent: "")))
        button.accessibilityLabel = nil
        let image = Layer(id: EntityID("layer_missing_image"), name: "Image", payload: .image(ImageLayerPayload()))
        let instance = Layer(id: EntityID("layer_missing_instance"), name: "Instance", payload: .componentInstance(ComponentInstanceLayerPayload()))
        let root = Layer(id: EntityID("layer_root"), name: "Root", payload: .scroll, children: [text, button, image, instance])
        document.screens = [Screen(id: EntityID("screen_probe"), name: "Probe", scopeID: scope, root: root)]

        let actual = DocumentValidator.validate(document).map { "\($0.rule):\($0.severity.rawValue):\($0.entityID?.rawValue ?? "none")" }
        XCTAssertEqual(actual, [
            "layer.textRequired:error:layer_missing_text",
            "binding.empty:error:layer_missing_text",
            "asset.missing:error:layer_missing_text",
            "layer.textRequired:error:layer_missing_button",
            "event.empty:error:layer_missing_button",
            "accessibility.controlLabel:error:layer_missing_button",
            "layer.assetRequired:error:layer_missing_image",
            "component.instanceRequired:error:layer_missing_instance"
        ])
    }

    func testPreRefactorProjectKeepsCanonicalBytesIdentityAndNoOpObservation() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/format-v1-project")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: fixture, to: root)
        let paths = [
            "hamii.json", "hamii-agent-profiles.json", "scopes/scope_app.json",
            "screens/screen_main.json", "components/component_badge.json",
            "components/component_leaf.json", "assets/asset_symbol.json"
        ]
        func bytes() throws -> [String: Data] {
            try Dictionary(uniqueKeysWithValues: paths.map { ($0, try Data(contentsOf: root.appendingPathComponent($0))) })
        }
        let original = try bytes()
        let repository = CanonicalRepository(root: root)
        let service = ProjectService(repository: repository)
        let observed = try service.observe()
        let snapshot = try repository.withCoordinatedSnapshot { $0 }
        XCTAssertEqual(snapshot.identity.rawValue, "e0bb7311812a2a4f194456cced0f1cbfb73fd59b3570fc3f4e04672c560c3d9a")
        XCTAssertEqual(snapshot.document, observed.document)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        func encoded<T: Encodable>(_ value: T) throws -> Data {
            var data = try encoder.encode(value)
            data.append(0x0A)
            return data
        }
        XCTAssertEqual(try encoded(snapshot.document.screens[0]), original["screens/screen_main.json"])
        for component in snapshot.document.components {
            XCTAssertEqual(try encoded(component), original["components/\(component.id.rawValue).json"])
        }
        let badge = try XCTUnwrap(snapshot.document.components.first { $0.id == EntityID("component_badge") })
        XCTAssertEqual(badge.root.children.last?.component?.definitionID, EntityID("component_leaf"))

        let generationBefore = try CanonicalGenerationStore(root: root).readStable()
        let result = try service.mutate(
            .setText(screenID: EntityID("screen_main"), layerID: EntityID("layer_title"), text: "Welcome"),
            expectedState: observed.statePrecondition, author: .human
        )
        XCTAssertTrue(result.patches.isEmpty)
        XCTAssertEqual(result.statePrecondition, observed.statePrecondition)
        XCTAssertEqual(try bytes(), original)
        XCTAssertEqual(try repository.withCoordinatedSnapshot { $0.identity }, snapshot.identity)
        XCTAssertEqual(try CanonicalGenerationStore(root: root).readStable(), generationBefore)
    }

    func testGeneratorOutputForAllSupportedFormatV1LayerKinds() throws {
        var document = Document(name: "Generator parity")
        let scope = try XCTUnwrap(document.scopes.first?.id)
        let target = Target(id: EntityID("target_swiftui"), platform: .macOS, framework: .swiftUI)
        document.targets = [target]
        document.capabilityDeclarations = [
            CapabilityKeys.legacyStack, CapabilityKeys.legacyOverlay, CapabilityKeys.legacyScroll,
            CapabilityKeys.legacyText, CapabilityKeys.legacyButton, CapabilityKeys.legacyImage,
            CapabilityKeys.legacyInstance, CapabilityKeys.systemAssetMapping
        ].map { CapabilityDeclaration(targetID: target.id, key: $0, support: .exact) }
        let asset = Asset(id: EntityID("asset_star"), name: "Star", ownerScopeID: scope,
            mediaType: "image/system", source: .system(name: "star"))
        document.assets = [asset]
        let definition = ComponentDefinition(id: EntityID("component_badge"), name: "Badge", ownerScopeID: scope,
            root: Layer(id: EntityID("layer_badge"), name: "Badge", payload: .text(TextLayerPayload(value: "Badge"))))
        document.components = [definition]
        let overlay = Layer(id: EntityID("layer_overlay"), name: "Overlay", payload: .overlay,
            children: [Layer(id: EntityID("layer_overlay_text"), name: "Text", payload: .text(TextLayerPayload(value: "Overlay")))])
        let scroll = Layer(id: EntityID("layer_scroll"), name: "Scroll", payload: .scroll, children: [
            Layer(id: EntityID("layer_button"), name: "Button", payload: .button(ButtonLayerPayload(label: "Go"))),
            Layer(id: EntityID("layer_image"), name: "Image", payload: .image(ImageLayerPayload(assetID: asset.id)))
        ])
        let instance = Layer(id: EntityID("layer_instance"), name: "Instance",
            payload: .componentInstance(ComponentInstanceLayerPayload(instance: ComponentInstance(definitionID: definition.id))))
        let root = Layer(id: EntityID("layer_root"), name: "Root", payload: .stack,
            children: [overlay, scroll, instance])
        let screen = Screen(id: EntityID("screen_generation"), name: "Generation", scopeID: scope, root: root)
        document.screens = [screen]

        let source = try SwiftUIGenerator.generate(document: document, screenID: screen.id, targetID: target.id).source
        XCTAssertEqual(source, "import SwiftUI\n\nstruct HamiiScreen_screen_generation: View {\n    var body: some View {\n        VStack {\n            ZStack {\n                Text(\"Overlay\")\n            }\n            ScrollView {\n                Button(\"Go\") { }\n                Image(systemName: \"star\")\n            }\n            Text(\"Badge\")\n        }\n    }\n}\n")
    }
}
