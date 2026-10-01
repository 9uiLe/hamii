import XCTest
@testable import HamiiMigrations

final class MigrationRouteTests: XCTestCase {
    func testInstalledAdjacentRoutesAndInvalidCatalogs() throws {
        let edge = MigrationEdge(sourceVersion: 1, targetVersion: 2)
        let next = MigrationEdge(sourceVersion: 2, targetVersion: 3)
        XCTAssertEqual(try MigrationRegistry.route(from: 1).edges, [edge, next])
        XCTAssertEqual(try MigrationRegistry.route(from: 1).edgePath, ["1->2", "2->3"])
        XCTAssertEqual(try MigrationRegistry.route(from: 2).edges, [next])
        XCTAssertEqual(try MigrationRegistry.route(from: 2, to: 3).edges, [next])
        XCTAssertEqual(try MigrationRegistry.route(from: 1, to: 3).edges, [edge, next])
        XCTAssertEqual(MigrationRegistry.currentDocumentFormatVersion, 3)
        XCTAssertEqual(MigrationPreflight.currentDocumentFormatVersion, 3)
        XCTAssertThrowsError(try MigrationRouteResolver.resolve(from: 1, to: 2, catalog: []))
        for catalog in [
            [edge, edge],
            [MigrationEdge(sourceVersion: 1, targetVersion: 3)],
            [MigrationEdge(sourceVersion: 2, targetVersion: 1)],
            [MigrationEdge(sourceVersion: 2, targetVersion: 2)]
        ] {
            XCTAssertThrowsError(try MigrationRouteResolver.resolve(from: 1, to: 2, catalog: catalog)) {
                guard case MigrationEdgeFailure.invalidCatalog = $0 else {
                    return XCTFail("Expected invalid-catalog failure, got \($0)")
                }
            }
        }
        XCTAssertThrowsError(try MigrationRouteResolver.resolve(from: 2, to: 1, catalog: [edge]))
    }

    func testReceiptChainRequiresExactOrderedRouteAndEndpoints() throws {
        let route = try MigrationRouteResolver.resolve(from: 1, to: 3,
            catalog: [.init(sourceVersion: 1, targetVersion: 2), .init(sourceVersion: 2, targetVersion: 3)])
        let first = MigrationEdgeReceipt(edge: route.edges[0], inputIdentity: "source",
            outputIdentity: "intermediate", classification: .losslessWithNormalization,
            resolutionDecisions: [], losses: [])
        let second = MigrationEdgeReceipt(edge: route.edges[1], inputIdentity: "intermediate",
            outputIdentity: "final", classification: .lossless,
            resolutionDecisions: [], losses: [])
        XCTAssertNoThrow(try MigrationReceiptChain.validate([first, second], for: route,
            sourceIdentity: "source", finalIdentity: "final"))
        XCTAssertThrowsError(try MigrationReceiptChain.validate([second, first], for: route,
            sourceIdentity: "source", finalIdentity: "final"))
        XCTAssertThrowsError(try MigrationReceiptChain.validate([first], for: route,
            sourceIdentity: "source", finalIdentity: "final"))
        XCTAssertThrowsError(try MigrationReceiptChain.validate([first, second], for: route,
            sourceIdentity: "other source", finalIdentity: "final"))
        XCTAssertThrowsError(try MigrationReceiptChain.validate([first, second], for: route,
            sourceIdentity: "source", finalIdentity: "other final"))
        let brokenJoin = MigrationEdgeReceipt(edge: route.edges[1], inputIdentity: "other intermediate",
            outputIdentity: "final", classification: .lossless,
            resolutionDecisions: [], losses: [])
        XCTAssertThrowsError(try MigrationReceiptChain.validate([first, brokenJoin], for: route,
            sourceIdentity: "source", finalIdentity: "final"))

        let noOp = try MigrationRegistry.route(from: 3)
        XCTAssertNoThrow(try MigrationReceiptChain.validate([], for: noOp,
            sourceIdentity: "same", finalIdentity: "same"))
        XCTAssertThrowsError(try MigrationReceiptChain.validate([], for: noOp,
            sourceIdentity: "before", finalIdentity: "after"))
    }
}
