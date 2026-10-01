import Foundation
import XCTest
import HamiiCore
import HamiiFormat
import HamiiIndex
import HamiiMigrations
@testable import HamiiMigrationRuntime

final class MigrationResolutionRuntimeTests: XCTestCase {
    private typealias Object = [String: Any]
    private struct Stopped: Error {}
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private func git(_ root: URL, _ args: String...) throws -> String { try GitCommand.run(at: root, args) }

    private func edit(_ root: URL, _ path: String, _ body: (inout Object) throws -> Void) throws {
        let url = root.appendingPathComponent(path)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? Object)
        try body(&object)
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: url)
    }

    private func fixture(_ kind: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hamii-resolution-runtime-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: repositoryRoot.appendingPathComponent("Tests/Fixtures/format-v1-safe-project"), to: root)
        try Data(".hamii/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        if kind == "distinct" || kind == "equivalent" || kind == "partial" {
            try edit(root, "hamii.json") { manifest in
                var values = try XCTUnwrap(manifest["capabilityDeclarations"] as? [Object])
                var duplicate = values[0]
                if kind != "equivalent" { duplicate["support"] = "portable"; duplicate["reason"] = "second support" }
                values.append(duplicate)
                if kind == "partial" {
                    values.append(["targetID": ["rawValue": "target_ios"], "key": ["rawValue": "future.capability"],
                                   "support": "exact", "reason": "unknown"])
                }
                manifest["capabilityDeclarations"] = values
            }
        }
        if kind == "residual" || kind == "twoResiduals" {
            try edit(root, "screens/screen_main.json") { screen in
                var layer = try XCTUnwrap(screen["root"] as? Object)
                var children = try XCTUnwrap(layer["children"] as? [Object])
                var scroll = children[0]
                var descendants = try XCTUnwrap(scroll["children"] as? [Object])
                descendants[0]["assetID"] = ["rawValue": "asset_symbol"]
                scroll["children"] = descendants
                children[0] = scroll
                if kind == "twoResiduals" { children[1]["assetID"] = ["rawValue": "asset_symbol"] }
                layer["children"] = children
                screen["root"] = layer
            }
        }
        _ = try git(root, "init", "-q")
        _ = try git(root, "checkout", "-q", "-b", "main")
        _ = try git(root, "add", ".")
        _ = try git(root, "-c", "user.name=Test", "-c", "user.email=test@localhost", "commit", "-q", "-m", "v1")
        return root
    }

    private func manifest(_ report: MigrationResolutionReport) -> MigrationResolutionManifest {
        MigrationResolutionManifest(source: report.source,
            decisions: report.items.compactMap { item in
                item.choices.first.map { MigrationResolutionDecision(item: item.id, selectedCandidateID: $0.id) }
            })
    }

    func testSourceBoundReportPrepareAndPublishedLossAudit() throws {
        for (kind, expectedClass, lossCount) in [
            ("distinct", MigrationClassification.potentiallyLossy, 1),
            ("equivalent", .losslessWithNormalization, 0),
            ("residual", .potentiallyLossy, 1),
            ("twoResiduals", .potentiallyLossy, 2)
        ] {
            let root = try fixture(kind)
            defer { try? FileManager.default.removeItem(at: root) }
            let preparer = MigrationCandidatePreparer()
            let report = try preparer.resolutionReport(repository: root)
            XCTAssertEqual(report.source.sourceOID, try git(root, "rev-parse", "HEAD"))
            XCTAssertEqual(report.source.sourceCanonicalIdentity,
                CanonicalByteIdentity.compute(files: try MigrationRepositoryInput.load(from: root).files).rawValue)
            XCTAssertEqual(report.items.count, kind == "twoResiduals" ? 2 : 1)
            XCTAssertTrue(report.items.allSatisfy { !$0.choices.isEmpty })
            let resolution = manifest(report)
            let review = try preparer.prepare(repository: root, resolution: resolution)
            XCTAssertEqual(review.recordFormatVersion, 3)
            XCTAssertEqual(review.sourceFormatVersion, 1)
            XCTAssertEqual(review.targetFormatVersion, 3)
            XCTAssertEqual(review.edgePath, ["1->2", "2->3"])
            XCTAssertEqual(review.classification, expectedClass)
            XCTAssertEqual(review.resolutionAudit?.decisions, resolution.decisions)
            XCTAssertEqual(review.resolutionAudit?.losses.count, lossCount)
            XCTAssertEqual(review.edgeResolutionAudits.map(\.edgeID), ["1->2"])
            XCTAssertEqual(review.receipts[0].resolutionDecisions, resolution.decisions)
            XCTAssertEqual(review.receipts[0].losses.count, lossCount)
            XCTAssertTrue(review.receipts[1].resolutionDecisions.isEmpty)
            XCTAssertTrue(review.receipts[1].losses.isEmpty)
            XCTAssertEqual(try git(root, "rev-parse", "HEAD"), report.source.sourceOID)
            let reviewPath = root.appendingPathComponent(".hamii/migration-reviews/\(review.reviewID).json")
            XCTAssertTrue(FileManager.default.fileExists(atPath: reviewPath.path))
            XCTAssertEqual(try MigrationReviewStore(root: root).recordVersion(review.reviewID), 3)
            let published = try MigrationPublisher(root: root, index: PublishedCanonicalIndex())
                .publish(reviewID: review.reviewID, confirmedSourceOID: review.sourceOID,
                         confirmedCandidateOID: review.candidateOID)
            XCTAssertEqual(published.candidateOID, review.candidateOID)
            XCTAssertFalse(WorktreeCoordinator(root: root).migrationPublicationPending())
            XCTAssertTrue(FileManager.default.fileExists(atPath: reviewPath.path), "Loss audit must survive publication")
            let retained = try MigrationReviewStore(root: root).loadComposed(review.reviewID)
            XCTAssertEqual(retained.edgeResolutionAudits.first?.losses, review.resolutionAudit?.losses)
            XCTAssertEqual(retained.receipts, review.receipts)
            let snapshot = try CanonicalRepository(root: root).withCoordinatedSnapshot { $0 }
            XCTAssertEqual(snapshot.identity.rawValue, review.validation.canonicalSnapshotIdentity)
            let index = try PublishedCanonicalIndex().verifyPublished(at: root, snapshot: snapshot)
            XCTAssertEqual(index.id.rawValue, published.indexGenerationID)
        }
    }

    func testReportAndPrepareRejectDirtyDetachedPartialAndStaleSource() throws {
        let root = try fixture("partial")
        defer { try? FileManager.default.removeItem(at: root) }
        let preparer = MigrationCandidatePreparer()
        let report = try preparer.resolutionReport(repository: root)
        XCTAssertEqual(report.items.count, 2)
        XCTAssertEqual(report.items.filter { $0.choices.isEmpty }.count, 1)
        XCTAssertThrowsError(try preparer.prepare(repository: root, resolution: manifest(report)))
        XCTAssertTrue(try git(root, "for-each-ref", "--format=%(refname)",
            "refs/hamii/migration-candidates").isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".hamii/migration-reviews").path))
        try Data("dirty\n".utf8).write(to: root.appendingPathComponent("untracked.txt"))
        XCTAssertThrowsError(try preparer.resolutionReport(repository: root))
        try FileManager.default.removeItem(at: root.appendingPathComponent("untracked.txt"))
        _ = try git(root, "checkout", "--detach", "-q")
        XCTAssertThrowsError(try preparer.resolutionReport(repository: root))

        let other = try fixture("distinct")
        defer { try? FileManager.default.removeItem(at: other) }
        let old = try preparer.resolutionReport(repository: other)
        try edit(other, "pages/page_main.json") { $0["name"] = "Changed source" }
        _ = try git(other, "add", "pages/page_main.json")
        _ = try git(other, "-c", "user.name=Test", "-c", "user.email=test@localhost", "commit", "-q", "-m", "external")
        XCTAssertThrowsError(try preparer.prepare(repository: other, resolution: manifest(old)))
    }

    func testNestedUnknownCanonicalPathIsVisibleAndHasNoChoice() throws {
        let root = try fixture("safe")
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("tokens/nested/unknown.json")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: nested)
        _ = try git(root, "add", "tokens/nested/unknown.json")
        _ = try git(root, "-c", "user.name=Test", "-c", "user.email=test@localhost", "commit", "-q", "-m", "unknown canonical path")
        let captured = try MigrationRepositoryInput.load(from: root)
        XCTAssertEqual(captured.files["tokens/nested/unknown.json"], Data("{}\n".utf8))
        let preparer = MigrationCandidatePreparer()
        let report = try preparer.resolutionReport(repository: root)
        XCTAssertEqual(report.items.map { $0.diagnostic.code }, ["path.unknown"])
        XCTAssertTrue(report.items[0].choices.isEmpty)
        XCTAssertThrowsError(try preparer.prepare(repository: root, resolution: manifest(report)))
        XCTAssertTrue(try git(root, "for-each-ref", "--format=%(refname)",
            "refs/hamii/migration-candidates").isEmpty)
    }

    func testTamperedResolutionReviewRejectsBeforePendingGate() throws {
        let root = try fixture("distinct")
        defer { try? FileManager.default.removeItem(at: root) }
        let preparer = MigrationCandidatePreparer()
        let review = try preparer.prepare(repository: root,
            resolution: manifest(preparer.resolutionReport(repository: root)))
        let reviewPath = root.appendingPathComponent(".hamii/migration-reviews/\(review.reviewID).json")
        let original = try Data(contentsOf: reviewPath)
        for tamper in ["removeLoss", "changeValue", "choice", "classification", "removeManifest", "sourceBinding", "unknownManifestField", "edgeID"] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? Object)
            var audits = try XCTUnwrap(json["edgeResolutionAudits"] as? [Object])
            var audit = try XCTUnwrap(audits.first)
            switch tamper {
            case "removeLoss": audit["losses"] = [Object]()
            case "changeValue":
                var losses = try XCTUnwrap(audit["losses"] as? [Object])
                losses[0]["historicalValue"] = "hidden"
                audit["losses"] = losses
            case "choice":
                var decisions = try XCTUnwrap(audit["decisions"] as? [Object])
                decisions[0]["selectedCandidateID"] = "injected"
                audit["decisions"] = decisions
            case "classification": json["classification"] = "losslessWithNormalization"
            case "removeManifest": audit.removeValue(forKey: "manifest")
            case "sourceBinding":
                var resolution = try XCTUnwrap(audit["manifest"] as? Object)
                resolution["sourceCanonicalIdentity"] = String(repeating: "0", count: 64)
                audit["manifest"] = resolution
            case "unknownManifestField":
                var resolution = try XCTUnwrap(audit["manifest"] as? Object)
                resolution["jsonPath"] = "hamii.json"
                audit["manifest"] = resolution
            case "edgeID": audit["edgeID"] = "2->3"
            default: XCTFail("Unknown tamper")
            }
            audits[0] = audit
            json["edgeResolutionAudits"] = audits
            try JSONSerialization.data(withJSONObject: json).write(to: reviewPath)
            XCTAssertThrowsError(try MigrationPublisher(root: root, index: PublishedCanonicalIndex())
                .publish(reviewID: review.reviewID, confirmedSourceOID: review.sourceOID,
                         confirmedCandidateOID: review.candidateOID), tamper)
            XCTAssertEqual(try git(root, "rev-parse", "HEAD"), review.sourceOID, tamper)
            XCTAssertFalse(WorktreeCoordinator(root: root).migrationPublicationPending(), tamper)
            try original.write(to: reviewPath)
        }
    }

    func testAutomaticReviewUsesComposedRecordAndCanPublish() throws {
        let root = try fixture("safe")
        defer { try? FileManager.default.removeItem(at: root) }
        let review = try MigrationCandidatePreparer().prepare(repository: root)
        XCTAssertEqual(review.recordFormatVersion, 3)
        XCTAssertEqual(review.edgePath, ["1->2", "2->3"])
        XCTAssertNil(review.resolutionAudit)
        XCTAssertTrue(review.edgeResolutionAudits.isEmpty)
        XCTAssertEqual(try MigrationReviewStore(root: root).recordVersion(review.reviewID), 3)
        _ = try MigrationPublisher(root: root, index: PublishedCanonicalIndex())
            .publish(reviewID: review.reviewID, confirmedSourceOID: review.sourceOID,
                     confirmedCandidateOID: review.candidateOID)
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            root.appendingPathComponent(".hamii/migration-reviews/\(review.reviewID).json").path))
        XCTAssertEqual(try MigrationReviewStore(root: root).loadComposed(review.reviewID).receipts,
            review.receipts)
    }

    func testResolvedPublicationRecoversAfterRefCASAndRetainsAudit() throws {
        let root = try fixture("residual")
        defer { try? FileManager.default.removeItem(at: root) }
        let preparer = MigrationCandidatePreparer()
        let review = try preparer.prepare(repository: root,
            resolution: manifest(preparer.resolutionReport(repository: root)))
        let publisher = MigrationPublisher(root: root, index: PublishedCanonicalIndex()) { step in
            if case .afterRefCAS = step { throw Stopped() }
        }
        XCTAssertThrowsError(try publisher.publish(reviewID: review.reviewID,
            confirmedSourceOID: review.sourceOID, confirmedCandidateOID: review.candidateOID))
        XCTAssertTrue(WorktreeCoordinator(root: root).migrationPublicationPending())
        XCTAssertEqual(try git(root, "rev-parse", "HEAD"), review.candidateOID)
        let result = try MigrationPublisher(root: root, index: PublishedCanonicalIndex()).recover()
        XCTAssertTrue(result.recovered)
        XCTAssertFalse(WorktreeCoordinator(root: root).migrationPublicationPending())
        XCTAssertEqual(try MigrationReviewStore(root: root).loadComposed(review.reviewID)
            .edgeResolutionAudits.first?.losses.count, 1)
        let snapshot = try CanonicalRepository(root: root).withCoordinatedSnapshot { $0 }
        XCTAssertEqual(try PublishedCanonicalIndex().verifyPublished(at: root, snapshot: snapshot).id.rawValue,
            result.indexGenerationID)
    }
}
