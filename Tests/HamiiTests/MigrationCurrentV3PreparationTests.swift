import Foundation
import XCTest
import HamiiCore
import HamiiMigrations
@testable import HamiiFormat
@testable import HamiiMigrationRuntime

final class MigrationCurrentV3PreparationTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func git(_ root: URL, _ args: String...) throws -> String {
        try GitCommand.run(at: root, args)
    }

    private func source(version: Int) throws -> URL {
        let fixture = version == 1 ? "Tests/Fixtures/format-v1-safe-project" :
            "Tests/Fixtures/format-v2-starter"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hamii-current-v3-prepare-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: repositoryRoot.appendingPathComponent(fixture), to: root)
        try Data(".hamii/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        _ = try git(root, "init", "-q")
        _ = try git(root, "checkout", "-q", "-b", "main")
        _ = try git(root, "add", ".")
        _ = try git(root, "-c", "user.name=Test", "-c", "user.email=test@localhost",
            "commit", "-q", "-m", "historical")
        return root
    }

    func testPrepareBothHistoricalRoutesToStoredCurrentV3Review() throws {
        for version in [1, 2] {
            let root = try source(version: version)
            defer { try? FileManager.default.removeItem(at: root) }
            let originalOID = try git(root, "rev-parse", "HEAD")
            let originalFiles = try MigrationRepositoryInput.load(from: root)
            let originalIdentity = CanonicalByteIdentity.compute(files: originalFiles.files).rawValue
            let plan = try MigrationPreflight.plan(repository: root)
            XCTAssertEqual(plan.sourceDocumentFormatVersion, version)
            XCTAssertEqual(plan.targetDocumentFormatVersion, 3)
            XCTAssertEqual(plan.state, "migrationAvailable")

            let review = try MigrationCandidatePreparer().prepare(repository: root)
            let stored = try MigrationReviewStore(root: root).loadComposed(review.reviewID)
            let expectedPath = version == 1 ? ["1->2", "2->3"] : ["2->3"]
            XCTAssertEqual(review.recordFormatVersion, 3)
            XCTAssertEqual(review.sourceFormatVersion, version)
            XCTAssertEqual(review.targetFormatVersion, 3)
            XCTAssertEqual(review.validation.currentFormat, 3)
            XCTAssertEqual(review.edgePath, expectedPath)
            XCTAssertEqual(review.receipts.map(\.edgeID), expectedPath)
            XCTAssertEqual(review.receipts, stored.receipts)
            XCTAssertEqual(review.sourceCanonicalIdentity, originalIdentity)
            XCTAssertEqual(review.receipts.first?.inputIdentity, originalIdentity)
            XCTAssertEqual(review.receipts.last?.outputIdentity,
                review.validation.canonicalSnapshotIdentity)
            XCTAssertEqual(review.edgeResolutionAudits.count, 0)
            XCTAssertNil(review.resolutionAudit)
            XCTAssertEqual(try MigrationReviewStore(root: root).recordVersion(review.reviewID), 3)
            XCTAssertEqual(try git(root, "rev-parse", "HEAD"), originalOID)
            XCTAssertEqual(try git(root, "rev-parse", review.retentionRef), review.candidateOID)
            XCTAssertEqual(try git(root, "status", "--porcelain=v1", "--untracked-files=all"), "")
            XCTAssertThrowsError(try MigrationReviewStore(root: root).load(review.reviewID))
        }
    }

    func testV1ResolutionAuditBelongsToFirstReceiptOnly() throws {
        let root = try source(version: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("screens/screen_main.json")
        var screen = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var layer = try XCTUnwrap(screen["root"] as? [String: Any])
        layer["assetID"] = ["rawValue": "asset_symbol"]
        screen["root"] = layer
        try JSONSerialization.data(withJSONObject: screen).write(to: path)
        _ = try git(root, "add", "screens/screen_main.json")
        _ = try git(root, "-c", "user.name=Test", "-c", "user.email=test@localhost",
            "commit", "-q", "-m", "historical residual")

        let preparer = MigrationCandidatePreparer()
        let report = try preparer.resolutionReport(repository: root)
        let decisions = try report.items.map { item in
            MigrationResolutionDecision(item: item.id,
                selectedCandidateID: try XCTUnwrap(item.choices.first).id)
        }
        let resolution = MigrationResolutionManifest(source: report.source, decisions: decisions)
        let review = try preparer.prepare(repository: root, resolution: resolution)
        XCTAssertEqual(review.edgePath, ["1->2", "2->3"])
        XCTAssertEqual(review.classification, .potentiallyLossy)
        XCTAssertEqual(review.edgeResolutionAudits.map(\.edgeID), ["1->2"])
        XCTAssertEqual(review.edgeResolutionAudits[0].decisions, decisions)
        XCTAssertEqual(review.edgeResolutionAudits[0].losses, review.receipts[0].losses)
        XCTAssertFalse(review.receipts[0].losses.isEmpty)
        XCTAssertTrue(review.receipts[1].resolutionDecisions.isEmpty)
        XCTAssertTrue(review.receipts[1].losses.isEmpty)
        XCTAssertEqual(review.resolutionAudit?.losses, review.receipts[0].losses)
        let stored = try MigrationReviewStore(root: root).loadComposed(review.reviewID)
        XCTAssertEqual(stored.edgeResolutionAudits.map(\.edgeID), ["1->2"])
    }
}
