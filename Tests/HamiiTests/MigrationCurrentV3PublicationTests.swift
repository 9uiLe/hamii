import Foundation
import XCTest
import HamiiCore
import HamiiMigrations
@testable import HamiiFormat
@testable import HamiiIndex
@testable import HamiiMigrationRuntime

final class MigrationCurrentV3PublicationTests: XCTestCase {
    private struct Stopped: Error {}

    private struct FailingIndex: CanonicalIndexPublishing {
        func validateCandidate(at root: URL, snapshot: CanonicalSnapshot) throws {
            try PublishedCanonicalIndex().validateCandidate(at: root, snapshot: snapshot)
        }
        func rebuildPublished(at root: URL, snapshot: CanonicalSnapshot) throws -> IndexGenerationDescriptor {
            throw IndexError.stale
        }
        func verifyPublished(at root: URL, snapshot: CanonicalSnapshot) throws -> IndexGenerationDescriptor {
            try PublishedCanonicalIndex().verifyPublished(at: root, snapshot: snapshot)
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func git(_ root: URL, _ args: String...) throws -> String {
        try GitCommand.run(at: root, args)
    }

    private func source(version: Int) throws -> URL {
        let path = version == 1 ? "Tests/Fixtures/format-v1-safe-project" :
            "Tests/Fixtures/format-v2-starter"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hamii-v3-publication-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: repositoryRoot.appendingPathComponent(path), to: root)
        try Data(".hamii/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        _ = try git(root, "init", "-q")
        _ = try git(root, "checkout", "-q", "-b", "main")
        _ = try git(root, "add", ".")
        _ = try git(root, "-c", "user.name=Test", "-c", "user.email=test@localhost",
                    "commit", "-q", "-m", "historical")
        return root
    }

    private func assertReadyCandidate(_ root: URL, review: MigrationComposedReviewPackage,
                                      indexID: String) throws {
        XCTAssertEqual(try git(root, "rev-parse", "HEAD"), review.candidateOID)
        XCTAssertFalse(WorktreeCoordinator(root: root).migrationPublicationPending())
        let snapshot = try CanonicalRepository(root: root).withCoordinatedSnapshot { $0 }
        XCTAssertEqual(snapshot.document.versions.document, 3)
        XCTAssertEqual(snapshot.identity.rawValue, review.validation.canonicalSnapshotIdentity)
        let index = try PublishedCanonicalIndex().verifyPublished(at: root, snapshot: snapshot)
        XCTAssertEqual(index.id.rawValue, indexID)
        XCTAssertEqual(index.sourceCanonicalIdentity, snapshot.identity)
        XCTAssertEqual(index.sourceGenerationBinding,
            .bound(try CanonicalGenerationStore(root: root).requireMatchingStable(snapshot).generation))
    }

    func testRealOneAndTwoEdgeCandidatesPublishOnlyFinalCurrentV3() throws {
        for version in [1, 2] {
            let root = try source(version: version)
            defer { try? FileManager.default.removeItem(at: root) }
            let review = try MigrationCandidatePreparer().prepareComposed(repository: root)
            XCTAssertEqual(review.receipts.map(\.edgeID), version == 1 ?
                ["1->2", "2->3"] : ["2->3"])
            let result = try MigrationPublisher(root: root, index: PublishedCanonicalIndex())
                .publish(reviewID: review.reviewID, confirmedSourceOID: review.sourceOID,
                         confirmedCandidateOID: review.candidateOID)
            XCTAssertEqual(result.canonicalSnapshotIdentity,
                           review.validation.canonicalSnapshotIdentity)
            try assertReadyCandidate(root, review: review, indexID: result.indexGenerationID)
            XCTAssertEqual(try MigrationPublisher(root: root, index: PublishedCanonicalIndex())
                .recover().indexGenerationID, result.indexGenerationID)
        }
    }

    func testRealRoutesRemainGatedAcrossOldAndCandidateRecoveryStops() throws {
        for version in [1, 2] {
            let template = try source(version: version)
            defer { try? FileManager.default.removeItem(at: template) }
            let review = try MigrationCandidatePreparer().prepareComposed(repository: template)
            for stop in [MigrationPublicationStep.pending, .afterRefCAS,
                         .beforeGateRelease] {
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("hamii-v3-stop-\(UUID().uuidString)")
                try FileManager.default.copyItem(at: template, to: root)
                defer { try? FileManager.default.removeItem(at: root) }
                let publisher = MigrationPublisher(root: root,
                    index: PublishedCanonicalIndex()) { step in
                    if step == stop { throw Stopped() }
                }
                XCTAssertThrowsError(try publisher.publish(reviewID: review.reviewID,
                    confirmedSourceOID: review.sourceOID,
                    confirmedCandidateOID: review.candidateOID), "\(version), \(stop)")
                XCTAssertTrue(publisher.hasPendingPublication)
                XCTAssertThrowsError(try CanonicalRepository(root: root).observe())
                let beforeCAS = stop == .pending
                XCTAssertEqual(try git(root, "rev-parse", "HEAD"),
                               beforeCAS ? review.sourceOID : review.candidateOID)
                let recovery = MigrationPublisher(root: root, index: PublishedCanonicalIndex())
                let result = try recovery.recover()
                XCTAssertTrue(result.recovered)
                XCTAssertFalse(recovery.hasPendingPublication)
                if beforeCAS {
                    XCTAssertEqual(result.indexGenerationID, "")
                    XCTAssertThrowsError(try CanonicalRepository(root: root).observe())
                } else {
                    try assertReadyCandidate(root, review: review,
                                             indexID: result.indexGenerationID)
                }
            }
        }
    }

    func testPostCASIndexFailureRollsForwardFromExactCurrentV3Candidate() throws {
        let root = try source(version: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        let review = try MigrationCandidatePreparer().prepareComposed(repository: root)
        XCTAssertThrowsError(try MigrationPublisher(root: root, index: FailingIndex())
            .publish(reviewID: review.reviewID, confirmedSourceOID: review.sourceOID,
                     confirmedCandidateOID: review.candidateOID))
        XCTAssertEqual(try git(root, "rev-parse", "HEAD"), review.candidateOID)
        XCTAssertTrue(WorktreeCoordinator(root: root).migrationPublicationPending())
        XCTAssertThrowsError(try CanonicalRepository(root: root).observe())
        let result = try MigrationPublisher(root: root, index: PublishedCanonicalIndex()).recover()
        try assertReadyCandidate(root, review: review, indexID: result.indexGenerationID)
    }
}
