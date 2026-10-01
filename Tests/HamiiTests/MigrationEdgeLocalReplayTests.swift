import Foundation
import XCTest
import HamiiFormat
import HamiiMigrations
@testable import HamiiMigrationRuntime

final class MigrationEdgeLocalReplayTests: XCTestCase {
    private var fixtureRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/format-v1-safe-project")
    }

    private func input() throws -> (MigrationFileSet, MigrationRoute, MigrationEdgeResolutionInput) {
        let files = try MigrationRepositoryInput.load(from: fixtureRoot)
        let route = try MigrationRegistry.route(from: 1, to: 2)
        let binding = MigrationResolutionSourceBinding(sourceOID: "source-oid",
            sourceCanonicalIdentity: CanonicalByteIdentity.compute(files: files.files).rawValue)
        let report = try MigrationRegistry.resolutionReport(files, sourceBinding: binding)
        XCTAssertTrue(report.items.isEmpty)
        let manifest = MigrationResolutionManifest(source: report.source, decisions: [])
        return (files, route, MigrationEdgeResolutionInput(edgeID: "1->2",
            manifest: manifest, sourceBinding: binding))
    }

    func testEdgeLocalResolutionMatchesExistingSingleEdgeReplay() throws {
        let (files, route, edgeInput) = try input()
        let local = try MigrationRouteReplay.run(files, route: route, edgeResolutions: [edgeInput])
        let legacy = try MigrationRouteReplay.run(files, route: route,
            resolution: edgeInput.manifest, sourceBinding: edgeInput.sourceBinding)
        XCTAssertEqual(local.finalFiles.files, legacy.finalFiles.files)
        XCTAssertEqual(local.receipts, legacy.receipts)
        XCTAssertEqual(local.receipts.map(\.edgeID), [edgeInput.edgeID])
        XCTAssertEqual(local.receipts[0].inputIdentity,
            edgeInput.sourceBinding.sourceCanonicalIdentity)
        XCTAssertEqual(local.singleEdgeCandidate?.resolutionDecisions, [])
    }

    func testUnknownAndDuplicateEdgeResolutionAreRejected() throws {
        let (files, route, input) = try input()
        let unknown = MigrationEdgeResolutionInput(edgeID: "2->3", manifest: input.manifest,
            sourceBinding: input.sourceBinding)
        XCTAssertThrowsError(try MigrationRouteReplay.run(files, route: route,
            edgeResolutions: [unknown])) { error in
            guard case MigrationResolutionFailure.invalidManifest = error else {
                return XCTFail("Expected invalidManifest, got \(error)")
            }
        }
        XCTAssertThrowsError(try MigrationRouteReplay.run(files, route: route,
            edgeResolutions: [input, input])) { error in
            guard case MigrationResolutionFailure.invalidManifest = error else {
                return XCTFail("Expected duplicate edge audit rejection, got \(error)")
            }
        }
    }

    func testVersionAndManifestBindingMismatchAreRejected() throws {
        let (files, route, input) = try input()
        let wrongVersion = MigrationResolutionSourceBinding(sourceOID: input.sourceBinding.sourceOID,
            sourceCanonicalIdentity: input.sourceBinding.sourceCanonicalIdentity,
            sourceFormatVersion: 2, targetFormatVersion: 3)
        let versionInput = MigrationEdgeResolutionInput(edgeID: input.edgeID,
            manifest: MigrationResolutionManifest(source: wrongVersion, decisions: []),
            sourceBinding: wrongVersion)
        XCTAssertThrowsError(try MigrationRouteReplay.run(files, route: route,
            edgeResolutions: [versionInput])) { error in
            guard case MigrationResolutionFailure.invalidManifest = error else {
                return XCTFail("Expected version mismatch rejection, got \(error)")
            }
        }
        let differentBinding = MigrationResolutionSourceBinding(sourceOID: "other-oid",
            sourceCanonicalIdentity: input.sourceBinding.sourceCanonicalIdentity)
        let mismatch = MigrationEdgeResolutionInput(edgeID: input.edgeID,
            manifest: input.manifest, sourceBinding: differentBinding)
        XCTAssertThrowsError(try MigrationRouteReplay.run(files, route: route,
            edgeResolutions: [mismatch])) { error in
            guard case MigrationResolutionFailure.invalidManifest = error else {
                return XCTFail("Expected manifest binding mismatch rejection, got \(error)")
            }
        }
    }

    func testEdgeResolutionMustBindExactInputBytes() throws {
        let (files, route, input) = try input()
        var changed = files.files
        changed["hamii.json"]?.append(0x20)
        XCTAssertThrowsError(try MigrationRouteReplay.run(MigrationFileSet(files: changed),
            route: route, edgeResolutions: [input])) { error in
            guard case MigrationResolutionFailure.staleSource = error else {
                return XCTFail("Expected staleSource, got \(error)")
            }
        }
    }

    func testNoOpRouteRejectsEdgeAuditAndUnpairedLegacyBinding() throws {
        let (files, route, input) = try input()
        let current = try MigrationRouteReplay.run(files, route: route).finalFiles
        let noOp = try MigrationRegistry.route(from: 2, to: 2)
        XCTAssertThrowsError(try MigrationRouteReplay.run(current, route: noOp,
            edgeResolutions: [input]))
        XCTAssertThrowsError(try MigrationRouteReplay.run(files, route: route,
            sourceBinding: input.sourceBinding))
    }
}
