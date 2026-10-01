import Foundation
import XCTest
import HamiiFormat
import HamiiMigrations
@testable import HamiiMigrationRuntime

final class MigrationRouteReplayTests: XCTestCase {
    private var fixtureRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/format-v1-safe-project")
    }

    private func source() throws -> MigrationFileSet {
        try MigrationRepositoryInput.load(from: fixtureRoot)
    }

    private func assertSameOneEdgeResult(_ replay: MigrationRouteReplayResult,
                                         as direct: MigrationCandidate,
                                         original: MigrationFileSet) throws {
        let candidate = try XCTUnwrap(replay.singleEdgeCandidate)
        XCTAssertEqual(replay.finalFiles.files, direct.files.files)
        XCTAssertEqual(candidate.edgePath, direct.edgePath)
        XCTAssertEqual(candidate.classification, direct.classification)
        XCTAssertEqual(candidate.resolutionDecisions, direct.resolutionDecisions)
        XCTAssertEqual(candidate.losses, direct.losses)
        XCTAssertEqual(candidate.diagnostics.map(\.code), direct.diagnostics.map(\.code))
        XCTAssertEqual(replay.receipts.count, 1)
        let receipt = try XCTUnwrap(replay.receipts.first)
        XCTAssertEqual(receipt.edgeID, "1->2")
        XCTAssertEqual(receipt.inputIdentity, CanonicalByteIdentity.compute(files: original.files).rawValue)
        XCTAssertEqual(receipt.outputIdentity, CanonicalByteIdentity.compute(files: direct.files.files).rawValue)
        XCTAssertEqual(receipt.classification, direct.classification)
        XCTAssertEqual(receipt.resolutionDecisions, direct.resolutionDecisions)
        XCTAssertEqual(receipt.losses, direct.losses)
        try MigrationReceiptChain.validate(replay.receipts,
            for: MigrationRegistry.route(from: 1, to: 2),
            sourceIdentity: receipt.inputIdentity, finalIdentity: receipt.outputIdentity)
    }

    func testAutomaticOneEdgeReplayMatchesDirectTransformAndRejectsTamperedBytes() throws {
        let original = try source()
        let route = try MigrationRegistry.route(from: 1, to: 2)
        let direct = try MigrationRegistry.transform(original)
        let first = try MigrationRouteReplay.run(original, route: route)
        let second = try MigrationRouteReplay.run(original, route: route)
        try assertSameOneEdgeResult(first, as: direct, original: original)
        XCTAssertEqual(first.finalFiles.files, second.finalFiles.files)
        XCTAssertEqual(first.receipts, second.receipts)

        var tampered = first.finalFiles.files
        tampered["hamii.json"]?.append(0x20)
        XCTAssertThrowsError(try MigrationReceiptChain.validate(first.receipts, for: route,
            sourceIdentity: CanonicalByteIdentity.compute(files: original.files).rawValue,
            finalIdentity: CanonicalByteIdentity.compute(files: tampered).rawValue))

        var changedSource = original.files
        changedSource["hamii.json"]?.append(0x20)
        let changed = try MigrationRouteReplay.run(MigrationFileSet(files: changedSource), route: route)
        XCTAssertNotEqual(changed.receipts[0].inputIdentity, first.receipts[0].inputIdentity)
        XCTAssertThrowsError(try MigrationReceiptChain.validate(changed.receipts, for: route,
            sourceIdentity: first.receipts[0].inputIdentity,
            finalIdentity: changed.receipts[0].outputIdentity))
    }

    func testHumanResolutionReplayKeepsEdgeLocalClassificationDecisionsAndLosses() throws {
        var original = try source().files
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with:
            XCTUnwrap(original["hamii.json"])) as? [String: Any])
        var declarations = try XCTUnwrap(manifest["capabilityDeclarations"] as? [[String: Any]])
        var duplicate = try XCTUnwrap(declarations.first)
        duplicate["support"] = "portable"
        duplicate["reason"] = "second historical declaration"
        declarations.append(duplicate)
        manifest["capabilityDeclarations"] = declarations
        original["hamii.json"] = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        let files = MigrationFileSet(files: original)
        let binding = MigrationResolutionSourceBinding(sourceOID: "fixture-oid",
            sourceCanonicalIdentity: CanonicalByteIdentity.compute(files: original).rawValue)
        let report = try MigrationRegistry.resolutionReport(files, sourceBinding: binding)
        XCTAssertFalse(report.items.isEmpty)
        let resolution = MigrationResolutionManifest(source: report.source,
            decisions: try report.items.map { item in
                MigrationResolutionDecision(item: item.id,
                    selectedCandidateID: try XCTUnwrap(item.choices.first).id)
            })
        let direct = try MigrationRegistry.transform(files, applying: resolution,
            actualSourceBinding: binding)
        let route = try MigrationRegistry.route(from: 1, to: 2)
        let replay = try MigrationRouteReplay.run(files, route: route,
            resolution: resolution, sourceBinding: binding)
        try assertSameOneEdgeResult(replay, as: direct, original: files)
        XCTAssertEqual(replay.receipts[0].classification, .potentiallyLossy)
        XCTAssertEqual(replay.receipts[0].losses.count, 1)

        let current = direct.files
        let noOp = try MigrationRegistry.route(from: 2, to: 2)
        XCTAssertThrowsError(try MigrationRouteReplay.run(current, route: noOp,
            resolution: resolution, sourceBinding: binding))
        XCTAssertThrowsError(try MigrationRouteReplay.run(files, route: noOp))
    }
}
