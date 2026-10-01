import Foundation
import XCTest
@testable import HamiiMigrations

final class FormatV2MigrationEdgeTests: XCTestCase {
    private let edge = MigrationEdge(sourceVersion: 2, targetVersion: 3)

    private func starter() throws -> MigrationFileSet {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Samples/Starter")
        return try MigrationRepositoryInput.load(from: root)
    }

    private func object(_ bytes: Data?) throws -> [String: Any] {
        let bytes = try XCTUnwrap(bytes)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }

    private func encoded(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func testExactV2ToV3AddsOnlyEmptyScreenSemanticsAndDocumentMarkers() throws {
        let source = try starter()
        let analysis = try MigrationRegistry.analyzeEdge(source, edge: edge)
        XCTAssertTrue(analysis.automaticCandidateEligible)
        XCTAssertEqual(analysis.classification, .losslessWithNormalization)
        let candidate = try MigrationRegistry.applyEdge(source, edge: edge)
        XCTAssertEqual(candidate.edgePath, ["2->3"])
        XCTAssertEqual(candidate.classification, .losslessWithNormalization)
        XCTAssertTrue(candidate.resolutionDecisions.isEmpty)
        XCTAssertTrue(candidate.losses.isEmpty)
        XCTAssertTrue(candidate.remainingUnresolved.isEmpty)
        XCTAssertEqual(Set(candidate.files.files.keys), Set(source.files.keys))

        var oldManifest = try object(source.files["hamii.json"])
        var newManifest = try object(candidate.files.files["hamii.json"])
        XCTAssertEqual(oldManifest.removeValue(forKey: "formatVersion") as? Int, 2)
        XCTAssertEqual(newManifest.removeValue(forKey: "formatVersion") as? Int, 3)
        var oldVersions = try XCTUnwrap(oldManifest.removeValue(forKey: "versions") as? [String: Any])
        var newVersions = try XCTUnwrap(newManifest.removeValue(forKey: "versions") as? [String: Any])
        XCTAssertEqual(oldVersions.removeValue(forKey: "document") as? Int, 2)
        XCTAssertEqual(newVersions.removeValue(forKey: "document") as? Int, 3)
        XCTAssertTrue(NSDictionary(dictionary: oldVersions).isEqual(to: newVersions))
        XCTAssertTrue(NSDictionary(dictionary: oldManifest).isEqual(to: newManifest))

        for (path, oldBytes) in source.files {
            if path.hasPrefix("screens/") && path.hasSuffix(".json") {
                let oldScreen = try object(oldBytes)
                var newScreen = try object(candidate.files.files[path])
                XCTAssertNil(oldScreen["semantics"], path)
                let semantics = try XCTUnwrap(newScreen.removeValue(forKey: "semantics") as? [String: Any])
                XCTAssertEqual(Set(semantics.keys), ["sources", "outputs", "relations"])
                XCTAssertTrue(semantics.values.allSatisfy { ($0 as? [Any])?.isEmpty == true })
                XCTAssertTrue(NSDictionary(dictionary: oldScreen).isEqual(to: newScreen), path)
            } else if path != "hamii.json" {
                XCTAssertEqual(candidate.files.files[path], oldBytes, path)
            }
        }
        XCTAssertEqual(candidate.files.files["hamii-agent-profiles.json"], source.files["hamii-agent-profiles.json"])
        XCTAssertEqual(try MigrationRegistry.applyEdge(source, edge: edge).files.files, candidate.files.files)
        XCTAssertEqual(try MigrationRegistry.transform(source, to: 3).files.files, candidate.files.files)
    }

    func testMixedMarkersAndPreexistingSemanticsFailClosed() throws {
        let original = try starter().files
        for (format, document) in [(1, 1), (3, 3), (2, 3), (3, 2)] {
            var files = original
            var manifest = try object(files["hamii.json"])
            var versions = try XCTUnwrap(manifest["versions"] as? [String: Any])
            manifest["formatVersion"] = format
            versions["document"] = document
            manifest["versions"] = versions
            files["hamii.json"] = try encoded(manifest)
            XCTAssertThrowsError(try MigrationRegistry.analyzeEdge(MigrationFileSet(files: files), edge: edge), "\(format)/\(document)")
            XCTAssertThrowsError(try MigrationRegistry.applyEdge(MigrationFileSet(files: files), edge: edge), "\(format)/\(document)")
        }
        let preexistingSemantics: [Any] = [["sources": [], "outputs": [], "relations": []] as [String: [Any]], NSNull()]
        for value in preexistingSemantics {
            var files = original
            let path = try XCTUnwrap(files.keys.first { $0.hasPrefix("screens/") && $0.hasSuffix(".json") })
            var screen = try object(files[path])
            screen["semantics"] = value
            files[path] = try encoded(screen)
            XCTAssertThrowsError(try MigrationRegistry.applyEdge(MigrationFileSet(files: files), edge: edge))
        }
    }

    func testMultiEdgeTransformRemainsRuntimeResponsibility() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/format-v1-safe-project")
        let source = try MigrationRepositoryInput.load(from: fixture)
        XCTAssertEqual(try MigrationRegistry.route(from: 1, to: 3).edgePath, ["1->2", "2->3"])
        XCTAssertThrowsError(try MigrationRegistry.transform(source, to: 3))
        XCTAssertThrowsError(try MigrationRegistry.applyEdge(source, edge: edge))
    }
}
