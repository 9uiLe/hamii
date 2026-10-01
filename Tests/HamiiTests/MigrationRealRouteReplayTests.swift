import Foundation
import XCTest
import HamiiCore
import HamiiFormat
import HamiiMigrations
@testable import HamiiMigrationRuntime

final class MigrationRealRouteReplayTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func v1() throws -> MigrationFileSet {
        try MigrationRepositoryInput.load(from: repositoryRoot
            .appendingPathComponent("Tests/Fixtures/format-v1-safe-project"))
    }

    private func v2() throws -> MigrationFileSet {
        try MigrationRepositoryInput.load(from: repositoryRoot.appendingPathComponent("Samples/Starter"))
    }

    private func assertChain(_ replay: MigrationRouteReplayResult, source: MigrationFileSet,
                             route: MigrationRoute) throws {
        XCTAssertEqual(replay.receipts.map(\.edgeID), route.edgePath)
        XCTAssertEqual(replay.receipts.first?.inputIdentity,
                       CanonicalByteIdentity.compute(files: source.files).rawValue)
        XCTAssertEqual(replay.receipts.last?.outputIdentity,
                       CanonicalByteIdentity.compute(files: replay.finalFiles.files).rawValue)
        try MigrationReceiptChain.validate(replay.receipts, for: route,
            sourceIdentity: CanonicalByteIdentity.compute(files: source.files).rawValue,
            finalIdentity: CanonicalByteIdentity.compute(files: replay.finalFiles.files).rawValue)
        let document = try CanonicalDocumentV3Codec.decode(files: replay.finalFiles.files)
        XCTAssertFalse(DocumentValidator.validate(document).contains { $0.severity == .error })
        XCTAssertTrue(document.screens.allSatisfy {
            $0.semantics?.sources.isEmpty == true &&
            $0.semantics?.outputs.isEmpty == true &&
            $0.semantics?.relations.isEmpty == true
        })
    }

    func testRealV2ToV3ReplayHasExactReceiptAndStrictTargetValidation() throws {
        let original = try v2()
        let route = try MigrationRegistry.route(from: 2, to: 3)
        let first = try MigrationRouteReplay.run(original, route: route)
        let second = try MigrationRouteReplay.run(original, route: route)
        try assertChain(first, source: original, route: route)
        XCTAssertEqual(first.receipts.count, 1)
        XCTAssertEqual(first.receipts, second.receipts)
        XCTAssertEqual(first.finalFiles.files, second.finalFiles.files)
        XCTAssertEqual(first.receipts[0].classification, .losslessWithNormalization)
        XCTAssertTrue(first.receipts[0].resolutionDecisions.isEmpty)
        XCTAssertTrue(first.receipts[0].losses.isEmpty)
        XCTAssertEqual(first.singleEdgeCandidate?.edgePath, ["2->3"])
    }

    func testRealV2ToV3ReplayRequiresStrictCodecAndSemanticValidation() throws {
        let original = try v2()
        let route = try MigrationRegistry.route(from: 2, to: 3)
        let screenPath = try XCTUnwrap(original.files.keys.first { $0.hasPrefix("screens/") })

        func changedScreen(_ edit: (inout [String: Any]) -> Void) throws -> MigrationFileSet {
            var files = original.files
            var screen = try XCTUnwrap(JSONSerialization.jsonObject(with:
                XCTUnwrap(files[screenPath])) as? [String: Any])
            edit(&screen)
            files[screenPath] = try JSONSerialization.data(withJSONObject: screen, options: [.sortedKeys])
            return MigrationFileSet(files: files)
        }

        let unknownField = try changedScreen { $0["unknownFutureField"] = true }
        XCTAssertThrowsError(try MigrationRouteReplay.run(unknownField, route: route))

        let missingScope = try changedScreen { $0["scopeID"] = ["rawValue": "missing_scope"] }
        XCTAssertThrowsError(try MigrationRouteReplay.run(missingScope, route: route)) { error in
            guard case MigrationEdgeFailure.invalidInput(let detail) = error else {
                return XCTFail("Expected semantic validation failure, got \(error)")
            }
            XCTAssertTrue(detail.contains("screen.scope"), detail)
        }
    }

    func testRealV1ToV3ReplayUsesOrderedReceiptsAndPreservesUnrelatedSecondEdgeBytes() throws {
        let original = try v1()
        let route = try MigrationRegistry.route(from: 1, to: 3)
        let intermediate = try MigrationRegistry.transform(original, to: 2)
        let replay = try MigrationRouteReplay.run(original, route: route)
        try assertChain(replay, source: original, route: route)
        XCTAssertEqual(replay.receipts.count, 2)
        XCTAssertEqual(replay.receipts[0].outputIdentity, replay.receipts[1].inputIdentity)
        XCTAssertEqual(replay.receipts[0].outputIdentity,
                       CanonicalByteIdentity.compute(files: intermediate.files.files).rawValue)
        XCTAssertNil(replay.singleEdgeCandidate)
        for (path, bytes) in intermediate.files.files where
            path != "hamii.json" && !path.hasPrefix("screens/") {
            XCTAssertEqual(replay.finalFiles.files[path], bytes, path)
        }
    }

    func testHumanV1DecisionStaysOnFirstReceiptAndCannotBindToSecondEdge() throws {
        var raw = try v1().files
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with:
            XCTUnwrap(raw["hamii.json"])) as? [String: Any])
        var declarations = try XCTUnwrap(manifest["capabilityDeclarations"] as? [[String: Any]])
        var duplicate = try XCTUnwrap(declarations.first)
        duplicate["support"] = "portable"
        duplicate["reason"] = "second historical declaration"
        declarations.append(duplicate)
        manifest["capabilityDeclarations"] = declarations
        raw["hamii.json"] = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])

        let source = MigrationFileSet(files: raw)
        let binding = MigrationResolutionSourceBinding(sourceOID: "fixture-oid",
            sourceCanonicalIdentity: CanonicalByteIdentity.compute(files: raw).rawValue)
        let report = try MigrationRegistry.resolutionReport(source, sourceBinding: binding)
        XCTAssertFalse(report.items.isEmpty)
        let decision = MigrationResolutionManifest(source: report.source,
            decisions: try report.items.map { item in
                MigrationResolutionDecision(item: item.id,
                    selectedCandidateID: try XCTUnwrap(item.choices.first).id)
            })
        let firstEdgeInput = MigrationEdgeResolutionInput(edgeID: "1->2",
            manifest: decision, sourceBinding: binding)
        let route = try MigrationRegistry.route(from: 1, to: 3)
        let replay = try MigrationRouteReplay.run(source, route: route,
            edgeResolutions: [firstEdgeInput])
        try assertChain(replay, source: source, route: route)
        XCTAssertEqual(replay.receipts[0].classification, .potentiallyLossy)
        XCTAssertEqual(replay.receipts[0].resolutionDecisions, decision.decisions)
        XCTAssertFalse(replay.receipts[0].losses.isEmpty)
        XCTAssertEqual(replay.receipts[1].classification, .losslessWithNormalization)
        XCTAssertTrue(replay.receipts[1].resolutionDecisions.isEmpty)
        XCTAssertTrue(replay.receipts[1].losses.isEmpty)

        let wrongEdgeInput = MigrationEdgeResolutionInput(edgeID: "2->3",
            manifest: decision, sourceBinding: binding)
        XCTAssertThrowsError(try MigrationRouteReplay.run(source, route: route,
            edgeResolutions: [wrongEdgeInput])) { error in
            guard case MigrationResolutionFailure.invalidManifest = error else {
                return XCTFail("Expected edge-local resolution rejection, got \(error)")
            }
        }
    }
}
