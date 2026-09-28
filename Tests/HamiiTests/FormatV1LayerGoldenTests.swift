import Foundation
import XCTest
import HamiiCore

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
}
