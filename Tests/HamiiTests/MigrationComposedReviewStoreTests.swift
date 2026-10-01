import Foundation
import XCTest
import HamiiMigrations
@testable import HamiiMigrationRuntime

final class MigrationComposedReviewStoreTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hamii-composed-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func package(audit: Bool = false) -> MigrationComposedReviewPackage {
        let source = String(repeating: "a", count: 64)
        let intermediate = String(repeating: "b", count: 64)
        let final = String(repeating: "c", count: 64)
        let id = UUID().uuidString.lowercased()
        let binding = MigrationResolutionSourceBinding(sourceOID: String(repeating: "1", count: 40),
            sourceCanonicalIdentity: source)
        let manifest = MigrationResolutionManifest(source: binding, decisions: [])
        let receipts = [
            MigrationEdgeReceipt(edge: MigrationEdge(sourceVersion: 1, targetVersion: 2),
                inputIdentity: source, outputIdentity: intermediate,
                classification: .losslessWithNormalization, resolutionDecisions: [], losses: []),
            MigrationEdgeReceipt(edge: MigrationEdge(sourceVersion: 2, targetVersion: 3),
                inputIdentity: intermediate, outputIdentity: final,
                classification: .lossless, resolutionDecisions: [], losses: [])
        ]
        return MigrationComposedReviewPackage(recordFormatVersion: 3, reviewID: id,
            sourceRef: "refs/heads/main", sourceOID: binding.sourceOID,
            sourceTreeOID: String(repeating: "2", count: 40), sourceCanonicalRevision: "test-revision",
            sourceCanonicalIdentity: source, sourceFormatVersion: 1, targetFormatVersion: 3,
            sourceDocumentRevision: 7, candidateDocumentRevision: 7,
            classification: .losslessWithNormalization, receipts: receipts,
            edgeResolutionAudits: audit ? [MigrationComposedEdgeResolutionAudit(edgeID: "1->2",
                manifest: manifest, decisions: [], losses: [])] : [],
            candidateOID: String(repeating: "3", count: 40),
            candidateTreeOID: String(repeating: "4", count: 40),
            retentionRef: "refs/hamii/migration-candidates/\(id)",
            changedPaths: ["hamii.json", "screens/main.json"],
            diffNameStatus: "M\thamii.json", diffStat: "hamii.json | 2 +",
            validation: MigrationValidationResult(currentFormat: 3,
                canonicalSnapshotIdentity: final, documentID: "document", documentRevision: 7),
            indexValidation: MigrationIndexValidationResult(sourceCanonicalIdentity: final,
                indexGenerationID: "index-generation", canonicalRevision: "test-revision"))
    }

    private func path(_ root: URL, _ reviewID: String) -> URL {
        root.appendingPathComponent(".hamii/migration-reviews/\(reviewID).json")
    }

    func testSortedRoundTripAndVersionDispatch() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = package(audit: true)
        let store = MigrationReviewStore(root: root)
        try store.writeComposed(input)
        XCTAssertEqual(try store.recordVersion(input.reviewID), 3)
        let loaded = try store.loadComposedWithBytes(input.reviewID)
        XCTAssertEqual(loaded.review.receipts, input.receipts)
        XCTAssertEqual(loaded.review.edgeResolutionAudits.count, 1)
        XCTAssertEqual(loaded.review.validation.canonicalSnapshotIdentity,
                       input.validation.canonicalSnapshotIdentity)
        XCTAssertEqual(loaded.bytes, try store.loadRawBytes(input.reviewID))
        XCTAssertThrowsError(try store.load(input.reviewID), "Legacy reader must reject composed record")
        guard case .composed(let dispatched) = try store.loadStored(input.reviewID) else {
            return XCTFail("Composed review must dispatch to v3")
        }
        XCTAssertEqual(dispatched.reviewID, input.reviewID)
        XCTAssertThrowsError(try store.writeComposed(input), "A review is write-once evidence")
    }

    func testRejectsUnknownMissingAndDuplicateKeysAtEveryDepth() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = package(audit: true)
        let store = MigrationReviewStore(root: root)
        try store.writeComposed(input)
        let original = try store.loadRawBytes(input.reviewID)
        let reviewPath = path(root, input.reviewID)
        let string = try XCTUnwrap(String(data: original, encoding: .utf8))
        let mutations = [
            string.replacingOccurrences(of: "\"recordFormatVersion\":3", with: "\"recordFormatVersion\":3,\"recordFormatVersion\":2"),
            string.replacingOccurrences(of: "\"recordFormatVersion\":3", with: "\"recordFormatVersion\":3,\"unknown\":true"),
            string.replacingOccurrences(of: "\"recordFormatVersion\":3,", with: ""),
            string.replacingOccurrences(of: "\"edgeID\":\"1->2\"", with: "\"edgeID\":\"1->2\",\"edgeID\":\"1->2\""),
            string.replacingOccurrences(of: "\"edgeID\":\"1->2\"", with: "\"edgeID\":\"1->2\",\"unknown\":true"),
            string.replacingOccurrences(of: "\"currentFormat\":3", with: "\"currentFormat\":3,\"unknown\":true"),
            string.replacingOccurrences(of: "\"formatVersion\":1", with: "\"formatVersion\":1,\"unknown\":true"),
            string.replacingOccurrences(of: "\"sourceOID\":\"\(input.sourceOID)\"", with: "\"sourceOID\":\"\(input.sourceOID)\",\"unknown\":true")
        ]
        for (offset, mutated) in mutations.enumerated() {
            XCTAssertNotEqual(mutated, string, "Mutation \(offset) must exercise a real key")
            try Data(mutated.utf8).write(to: reviewPath)
            XCTAssertThrowsError(try store.loadComposed(input.reviewID), "Mutation \(offset) must fail closed")
            if offset == 0 {
                XCTAssertThrowsError(try store.recordVersion(input.reviewID),
                                     "Duplicate dispatch key must never select a review protocol")
            }
        }
    }

    func testRejectsBrokenReceiptChainAndAuditBinding() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = package(audit: true)
        let store = MigrationReviewStore(root: root)
        try store.writeComposed(input)
        let original = try store.loadRawBytes(input.reviewID)
        let reviewPath = path(root, input.reviewID)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        for key in ["inputIdentity", "edgeID", "outputIdentity"] {
            var changed = raw
            var receipts = try XCTUnwrap(changed["receipts"] as? [[String: Any]])
            receipts[1][key] = key == "edgeID" ? "9->10" : String(repeating: "d", count: 64)
            changed["receipts"] = receipts
            try JSONSerialization.data(withJSONObject: changed).write(to: reviewPath)
            XCTAssertThrowsError(try store.loadComposed(input.reviewID), "\(key) must bind the ordered route")
        }
        var changed = raw
        var audits = try XCTUnwrap(changed["edgeResolutionAudits"] as? [[String: Any]])
        audits[0]["edgeID"] = "2->3"
        changed["edgeResolutionAudits"] = audits
        try JSONSerialization.data(withJSONObject: changed).write(to: reviewPath)
        XCTAssertThrowsError(try store.loadComposed(input.reviewID), "Edge-local resolution cannot move to another edge")
    }
}
