import Foundation
import XCTest
import HamiiCore
@testable import HamiiFormat
import HamiiMigrations
@testable import HamiiMigrationRuntime

/// Historical v2 is handled by migration machinery; the Current reader accepts v3.
/// These tests exercise exact captured bytes and real replay.
final class RealFormatV2ToV3AcceptanceTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func starter() throws -> MigrationFileSet {
        try MigrationRepositoryInput.load(from: repositoryRoot.appendingPathComponent("Tests/Fixtures/format-v2-starter"))
    }

    private func historical() throws -> MigrationFileSet {
        try MigrationRepositoryInput.load(from: repositoryRoot.appendingPathComponent("Tests/Fixtures/format-v1-safe-project"))
    }

    private func object(_ bytes: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(bytes)) as? [String: Any])
    }

    private func rewritten(_ files: MigrationFileSet, path: String,
                           _ edit: (inout [String: Any]) throws -> Void) throws -> MigrationFileSet {
        var all = files.files
        var value = try object(all[path])
        try edit(&value)
        all[path] = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return MigrationFileSet(files: all)
    }

    private func screenPaths(_ files: MigrationFileSet) -> [String] {
        files.files.keys.filter { $0.hasPrefix("screens/") && $0.hasSuffix(".json") }.sorted()
    }

    private func direct(_ files: MigrationFileSet) throws -> MigrationCandidate {
        try MigrationRegistry.applyEdge(files, edge: MigrationEdge(sourceVersion: 2, targetVersion: 3))
    }

    func testRawEdgeChangesOnlyDocumentMarkersAndAddsEmptySemantics() throws {
        let initial = try starter()
        let screen = try XCTUnwrap(screenPaths(initial).first)
        // An existing binding must remain a binding; migration must not invent
        // SemanticSource, SemanticOutput, or SemanticRelation records from it.
        let source = try rewritten(initial, path: screen) { value in
            var root = try XCTUnwrap(value["root"] as? [String: Any])
            var children = try XCTUnwrap(root["children"] as? [[String: Any]])
            children[0]["textBinding"] = "user.name"
            root["children"] = children
            value["root"] = root
        }
        let first = try direct(source)
        let second = try direct(source)
        XCTAssertEqual(first.files.files, second.files.files)
        XCTAssertEqual(first.edgePath, ["2->3"])
        XCTAssertEqual(first.classification, .losslessWithNormalization)
        XCTAssertTrue(first.diagnostics.isEmpty)
        XCTAssertTrue(first.resolutionDecisions.isEmpty)
        XCTAssertTrue(first.losses.isEmpty)
        XCTAssertTrue(first.remainingUnresolved.isEmpty)
        XCTAssertEqual(first.files.files.keys.sorted(), source.files.keys.sorted())

        let beforeManifest = try object(source.files["hamii.json"])
        let afterManifest = try object(first.files.files["hamii.json"])
        var expectedManifest = beforeManifest
        expectedManifest["formatVersion"] = 3
        var versions = try XCTUnwrap(expectedManifest["versions"] as? [String: Any])
        let originalIntegration = versions["integrationProfile"] as? Int
        versions["document"] = 3
        expectedManifest["versions"] = versions
        XCTAssertTrue(NSDictionary(dictionary: afterManifest).isEqual(to: expectedManifest))
        XCTAssertEqual((afterManifest["versions"] as? [String: Any])?["integrationProfile"] as? Int,
                       originalIntegration)
        for (path, bytes) in source.files where path != "hamii.json" && !screenPaths(source).contains(path) {
            XCTAssertEqual(first.files.files[path], bytes, path)
        }
        XCTAssertEqual(first.files.files["hamii-agent-profiles.json"], source.files["hamii-agent-profiles.json"])
        for path in screenPaths(source) {
            var expectedScreen = try object(source.files[path])
            expectedScreen["semantics"] = ["sources": [], "outputs": [], "relations": []] as [String: Any]
            let actualScreen = try object(first.files.files[path])
            XCTAssertTrue(NSDictionary(dictionary: actualScreen).isEqual(to: expectedScreen), path)
            let semantics = try XCTUnwrap(actualScreen["semantics"] as? [String: Any])
            XCTAssertEqual(Set(semantics.keys), ["sources", "outputs", "relations"])
            for key in ["sources", "outputs", "relations"] {
                XCTAssertTrue((semantics[key] as? [Any])?.isEmpty == true, "\(path): \(key)")
            }
        }
        let decoded = try CanonicalDocumentV3Codec.decode(files: first.files.files)
        XCTAssertTrue(DocumentValidator.validate(decoded).filter { $0.severity == .error }.isEmpty)
    }

    func testEdgeRejectsMixedMarkersOtherVersionsAndPreexistingSemantics() throws {
        let source = try starter()
        for (format, document) in [(2, 1), (1, 2), (1, 1), (3, 3), (3, 2), (2, 3)] {
            let changed = try rewritten(source, path: "hamii.json") { manifest in
                manifest["formatVersion"] = format
                var versions = try XCTUnwrap(manifest["versions"] as? [String: Any])
                versions["document"] = document
                manifest["versions"] = versions
            }
            let captured = changed.files
            XCTAssertThrowsError(try direct(changed), "\(format)/\(document)")
            XCTAssertEqual(changed.files, captured)
        }
        let screen = try XCTUnwrap(screenPaths(source).first)
        let semanticsCases: [[String: Any]] = [
            ["sources": [], "outputs": [], "relations": []],
            ["sources": [["key": ["rawValue": "user.name"], "valueKind": "text"]],
             "outputs": [], "relations": []]
        ]
        for semantics in semanticsCases {
            let changed = try rewritten(source, path: screen) { $0["semantics"] = semantics }
            let captured = changed.files
            XCTAssertThrowsError(try direct(changed), "Existing semantics must not be overwritten")
            XCTAssertEqual(changed.files, captured)
        }
    }

    func testRealReplayProducesExactChainedReceiptsForBothRoutes() throws {
        let v1 = try historical()
        let v2 = try MigrationRegistry.transform(v1, to: 2)
        let oneRoute = try MigrationRegistry.route(from: 2, to: 3)
        let one = try MigrationRouteReplay.run(v2.files, route: oneRoute)
        XCTAssertEqual(one.receipts.map(\.edgeID), ["2->3"])
        XCTAssertEqual(one.receipts[0].inputIdentity,
                       CanonicalByteIdentity.compute(files: v2.files.files).rawValue)
        XCTAssertEqual(one.receipts[0].outputIdentity,
                       CanonicalByteIdentity.compute(files: one.finalFiles.files).rawValue)
        XCTAssertEqual(one.receipts[0].classification, .losslessWithNormalization)
        XCTAssertTrue(one.receipts[0].resolutionDecisions.isEmpty)
        XCTAssertTrue(one.receipts[0].losses.isEmpty)
        try MigrationReceiptChain.validate(one.receipts, for: oneRoute,
            sourceIdentity: one.receipts[0].inputIdentity, finalIdentity: one.receipts[0].outputIdentity)

        let composedRoute = try MigrationRegistry.route(from: 1, to: 3)
        XCTAssertEqual(composedRoute.edgePath, ["1->2", "2->3"])
        let composed = try MigrationRouteReplay.run(v1, route: composedRoute)
        XCTAssertEqual(composed.receipts.map(\.edgeID), composedRoute.edgePath)
        XCTAssertEqual(composed.receipts[0].outputIdentity, composed.receipts[1].inputIdentity)
        XCTAssertEqual(composed.receipts[0].inputIdentity,
                       CanonicalByteIdentity.compute(files: v1.files).rawValue)
        XCTAssertEqual(composed.receipts[1].outputIdentity,
                       CanonicalByteIdentity.compute(files: composed.finalFiles.files).rawValue)
        XCTAssertEqual(composed.finalFiles.files, one.finalFiles.files)
        try MigrationReceiptChain.validate(composed.receipts, for: composedRoute,
            sourceIdentity: composed.receipts[0].inputIdentity,
            finalIdentity: composed.receipts[1].outputIdentity)
    }

    func testStrictTargetRejectsMissingUnknownAndSemanticallyInvalidSemantics() throws {
        let source = try starter()
        let final = try direct(source).files
        let path = try XCTUnwrap(screenPaths(final).first)
        let missing = try rewritten(final, path: path) { $0.removeValue(forKey: "semantics") }
        XCTAssertThrowsError(try CanonicalDocumentV3Codec.decode(files: missing.files))
        let unknown = try rewritten(final, path: path) { value in
            var semantics = try XCTUnwrap(value["semantics"] as? [String: Any])
            semantics["unreviewed"] = []
            value["semantics"] = semantics
        }
        XCTAssertThrowsError(try CanonicalDocumentV3Codec.decode(files: unknown.files))
        let invalidAnchor = try rewritten(final, path: path) { value in
            var semantics = try XCTUnwrap(value["semantics"] as? [String: Any])
            semantics["outputs"] = [[
                "key": "name",
                "anchor": ["kind": "direct", "layerID": ["rawValue": "missing_layer"], "property": "text"],
                "binding": "user.name"
            ]]
            value["semantics"] = semantics
        }
        let decoded = try CanonicalDocumentV3Codec.decode(files: invalidAnchor.files)
        XCTAssertTrue(DocumentValidator.validate(decoded).contains { $0.rule == "semantics.anchor" })
    }

    func testCurrentV3DefaultsAndHistoricalV2Boundary() throws {
        XCTAssertEqual(MigrationRegistry.currentDocumentFormatVersion, 3)
        XCTAssertEqual(MigrationPreflight.currentDocumentFormatVersion, 3)
        XCTAssertEqual(try MigrationRegistry.route(from: 1).edgePath, ["1->2", "2->3"])
        let sample = repositoryRoot.appendingPathComponent("Samples/Starter")
        let plan = try MigrationPreflight.plan(repository: sample)
        XCTAssertEqual(plan.state, "current")
        XCTAssertEqual(plan.targetDocumentFormatVersion, 3)
        XCTAssertEqual(try CanonicalRepository(root: sample).load().versions.document, 3)
        let historicalV2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("hamii-v2-current-boundary-\(UUID().uuidString)")
        try FileManager.default.copyItem(
            at: repositoryRoot.appendingPathComponent("Tests/Fixtures/format-v2-starter"), to: historicalV2)
        defer { try? FileManager.default.removeItem(at: historicalV2) }
        XCTAssertThrowsError(try CanonicalRepository(root: historicalV2).load()) { error in
            guard case CanonicalError.unsupportedFormat(2) = error else {
                return XCTFail("Expected unsupportedFormat(2), got \(error)")
            }
        }
        XCTAssertEqual(try MigrationPreflight.plan(repository: historicalV2).state, "migrationAvailable")
    }
}
