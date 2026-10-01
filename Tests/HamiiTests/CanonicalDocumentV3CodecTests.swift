import Foundation
import CryptoKit
import XCTest
import HamiiCore
@testable import HamiiFormat

final class CanonicalDocumentV3CodecTests: XCTestCase {
    private func fixture() -> Document {
        var document = Document(name: "Semantic candidate")
        document.versions.document = 3
        let label = Layer(id: EntityID("label"), name: "Label",
                          payload: .text(.init(value: "Preview", binding: "user.name")))
        var screen = Screen(id: EntityID("screen"), name: "Screen",
                            scopeID: document.scopes[0].id, root: label)
        screen.semantics = ScreenSemantics(
            sources: [.init(key: .init("user.name"), valueKind: .text)],
            outputs: [.init(key: .init("title"), anchor: .direct(layerID: label.id, property: .text),
                            binding: "user.name")],
            relations: [.init(output: .init("title"), source: .init("user.name"),
                              visibleWhen: .always, whenNil: .needsResolution)])
        document.screens = [screen]
        return document
    }

    private func modified(_ files: [String: Data], path: String,
                          _ edit: (inout [String: Any]) -> Void) throws -> [String: Data] {
        var files = files
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(files[path])) as? [String: Any])
        edit(&object)
        files[path] = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return files
    }

    func testV3RoundTripAndStrictSemanticFields() throws {
        let document = fixture()
        let files = try CanonicalDocumentV3Codec.encode(document: document)
        XCTAssertEqual(try CanonicalDocumentV3Codec.decode(files: files), document)
        let screenPath = "screens/screen.json"
        let screen = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(files[screenPath])) as? [String: Any])
        let semantics = try XCTUnwrap(screen["semantics"] as? [String: Any])
        XCTAssertEqual(Set(semantics.keys), ["sources", "outputs", "relations"])
        let anchor = try XCTUnwrap((semantics["outputs"] as? [[String: Any]])?.first?["anchor"] as? [String: Any])
        XCTAssertEqual(anchor["kind"] as? String, "direct")

        let extra = try modified(files, path: screenPath) { screen in
            var semantics = screen["semantics"] as! [String: Any]
            var outputs = semantics["outputs"] as! [[String: Any]]
            outputs[0]["unexpected"] = true
            semantics["outputs"] = outputs
            screen["semantics"] = semantics
        }
        XCTAssertThrowsError(try CanonicalDocumentV3Codec.decode(files: extra))

        let missing = try modified(files, path: screenPath) { screen in
            var semantics = screen["semantics"] as! [String: Any]
            semantics.removeValue(forKey: "relations")
            screen["semantics"] = semantics
        }
        XCTAssertThrowsError(try CanonicalDocumentV3Codec.decode(files: missing))

        let unknownKind = try modified(files, path: screenPath) { screen in
            var semantics = screen["semantics"] as! [String: Any]
            var outputs = semantics["outputs"] as! [[String: Any]]
            var anchor = outputs[0]["anchor"] as! [String: Any]
            anchor["kind"] = "unsupported"
            outputs[0]["anchor"] = anchor
            semantics["outputs"] = outputs
            screen["semantics"] = semantics
        }
        XCTAssertThrowsError(try CanonicalDocumentV3Codec.decode(files: unknownKind))

        let missingSemantics = try modified(files, path: screenPath) { $0.removeValue(forKey: "semantics") }
        XCTAssertThrowsError(try CanonicalDocumentV3Codec.decode(files: missingSemantics))

        let unexpectedScreenField = try modified(files, path: screenPath) { $0["unexpected"] = "lost" }
        XCTAssertThrowsError(try CanonicalDocumentV3Codec.decode(files: unexpectedScreenField))

        let unexpectedAnchorField = try modified(files, path: screenPath) { screen in
            var semantics = screen["semantics"] as! [String: Any]
            var outputs = semantics["outputs"] as! [[String: Any]]
            var anchor = outputs[0]["anchor"] as! [String: Any]
            anchor["unexpected"] = true
            outputs[0]["anchor"] = anchor
            semantics["outputs"] = outputs
            screen["semantics"] = semantics
        }
        XCTAssertThrowsError(try CanonicalDocumentV3Codec.decode(files: unexpectedAnchorField))

        let missingAnchorProperty = try modified(files, path: screenPath) { screen in
            var semantics = screen["semantics"] as! [String: Any]
            var outputs = semantics["outputs"] as! [[String: Any]]
            var anchor = outputs[0]["anchor"] as! [String: Any]
            anchor.removeValue(forKey: "property")
            outputs[0]["anchor"] = anchor
            semantics["outputs"] = outputs
            screen["semantics"] = semantics
        }
        XCTAssertThrowsError(try CanonicalDocumentV3Codec.decode(files: missingAnchorProperty))
    }

    func testV3RejectsMarkerMismatchAndUnknownManifestFields() throws {
        let files = try CanonicalDocumentV3Codec.encode(document: fixture())
        let mismatched = try modified(files, path: "hamii.json") { $0["formatVersion"] = 2 }
        XCTAssertThrowsError(try CanonicalDocumentV3Codec.decode(files: mismatched))
        let mixedVersions = try modified(files, path: "hamii.json") { manifest in
            var versions = manifest["versions"] as! [String: Any]
            versions["document"] = 2
            manifest["versions"] = versions
        }
        XCTAssertThrowsError(try CanonicalDocumentV3Codec.decode(files: mixedVersions))
        let unknown = try modified(files, path: "hamii.json") { $0["legacy"] = true }
        XCTAssertThrowsError(try CanonicalDocumentV3Codec.decode(files: unknown))
        let missing = try modified(files, path: "hamii.json") { $0.removeValue(forKey: "versions") }
        XCTAssertThrowsError(try CanonicalDocumentV3Codec.decode(files: missing))
    }

    func testV3OccurrenceFrameShapeRejectsUnknownAndMissingFields() throws {
        var document = fixture()
        document.screens[0].semantics.outputs[0].anchor = .component(path: [
            .init(instanceLayerID: EntityID("instance"), expectedDefinitionID: EntityID("definition"),
                  layerPath: [EntityID("root"), EntityID("instance")])
        ], layerID: EntityID("label"), property: .text)
        let files = try CanonicalDocumentV3Codec.encode(document: document)
        XCTAssertEqual(try CanonicalDocumentV3Codec.decode(files: files), document)
        let path = "screens/screen.json"

        func changingFrame(_ edit: (inout [String: Any]) -> Void) throws -> [String: Data] {
            try modified(files, path: path) { screen in
                var semantics = screen["semantics"] as! [String: Any]
                var outputs = semantics["outputs"] as! [[String: Any]]
                var anchor = outputs[0]["anchor"] as! [String: Any]
                var frames = anchor["path"] as! [[String: Any]]
                edit(&frames[0])
                anchor["path"] = frames
                outputs[0]["anchor"] = anchor
                semantics["outputs"] = outputs
                screen["semantics"] = semantics
            }
        }
        XCTAssertThrowsError(try CanonicalDocumentV3Codec.decode(files: changingFrame { $0["unknown"] = true }))
        XCTAssertThrowsError(try CanonicalDocumentV3Codec.decode(files: changingFrame {
            $0.removeValue(forKey: "expectedDefinitionID")
        }))
    }

    func testCurrentScreenRequiresSemanticsAndRepositoryRejectsV2() throws {
        let historical = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/format-v2-starter")
        let screenPath = "screens/screen_9369ecd6-58a4-47e1-a455-2c62eee99a4d.json"
        let bytes = try Data(contentsOf: historical.appendingPathComponent(screenPath))
        XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                       "dc5d3a880f267d5ed6ebd31dd66807f4835771cab7b0fc2c99b75cf8a408c273")
        XCTAssertThrowsError(try JSONDecoder().decode(Screen.self, from: bytes))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hamii-v2-semantic-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: historical, to: root)
        XCTAssertThrowsError(try CanonicalRepository(root: root).load()) { error in
            guard case CanonicalError.unsupportedFormat(2) = error else {
                return XCTFail("Expected unsupportedFormat(2), got \(error)")
            }
        }
    }

    func testCurrentRepositoryWritesStrictV3ScreensAndRejectsMissingSemantics() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hamii-current-v3-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CanonicalRepository(root: root)
        let created = try repository.create(name: "Current v3")
        XCTAssertEqual(created.versions.document, 3)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: root.appendingPathComponent("hamii.json"))) as? [String: Any])
        XCTAssertEqual(manifest["formatVersion"] as? Int, 3)

        var updated = created
        updated.revision += 1
        updated.screens = [Screen(id: EntityID("screen_current"), name: "Current",
            scopeID: created.scopes[0].id,
            root: Layer(id: EntityID("root_current"), kind: .stack, name: "Root"))]
        try repository.save(updated, expected: created)
        XCTAssertEqual(try repository.load(), updated)
        let screenPath = root.appendingPathComponent("screens/screen_current.json")
        let screenBytes = try Data(contentsOf: screenPath)
        let screen = try XCTUnwrap(JSONSerialization.jsonObject(with: screenBytes) as? [String: Any])
        let semantics = try XCTUnwrap(screen["semantics"] as? [String: Any])
        XCTAssertEqual(Set(semantics.keys), ["sources", "outputs", "relations"])

        var missing = screen
        missing.removeValue(forKey: "semantics")
        try JSONSerialization.data(withJSONObject: missing).write(to: screenPath)
        XCTAssertThrowsError(try repository.load())
    }
}
