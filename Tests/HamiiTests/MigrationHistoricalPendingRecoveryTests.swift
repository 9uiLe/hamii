import CryptoKit
import Foundation
import XCTest
import HamiiCore
import HamiiMigrations
@testable import HamiiFormat
@testable import HamiiIndex
@testable import HamiiMigrationRuntime

final class MigrationHistoricalPendingRecoveryTests: XCTestCase {
    private enum RecordKind: Equatable { case legacy, composed }
    private struct Stopped: Error {}

    private struct Fixture {
        let root: URL
        let reviewID: String
        let sourceRef: String
        let sourceOID: String
        let candidateOID: String
        let sourceIdentity: String
        let candidateIdentity: String
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func git(_ root: URL, _ args: String...) throws -> String {
        try GitCommand.run(at: root, args)
    }

    private func manifest(_ files: MigrationFileSet) throws -> (id: String, revision: Int) {
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with:
            XCTUnwrap(files.files["hamii.json"])) as? [String: Any])
        let id = try XCTUnwrap(raw["id"] as? [String: String])
        return (try XCTUnwrap(id["rawValue"]), try XCTUnwrap(raw["revision"] as? Int))
    }

    /// Constructs a historical reviewed v1→2 publication without exposing a
    /// v2 writer in the Current-v3 production API.
    private func fixture(_ kind: RecordKind, afterCAS: Bool) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hamii-historical-pending-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: repositoryRoot
            .appendingPathComponent("Tests/Fixtures/format-v1-safe-project"), to: root)
        try Data(".hamii/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        _ = try git(root, "init", "-q")
        _ = try git(root, "checkout", "-q", "-b", "main")
        _ = try git(root, "add", ".")
        _ = try git(root, "-c", "user.name=Test", "-c", "user.email=test@localhost",
                    "commit", "-q", "-m", "v1")
        let sourceRef = try git(root, "symbolic-ref", "--quiet", "HEAD")
        let sourceOID = try git(root, "rev-parse", "HEAD")
        let sourceTree = try git(root, "rev-parse", "HEAD^{tree}")
        let sourceRevision = try GitCanonicalRevisionCalculator().current(at: root).rawValue
        let original = try MigrationRepositoryInput.load(from: root)
        let old = try manifest(original)
        let sourceIdentity = CanonicalByteIdentity.compute(files: original.files).rawValue
        let route = try MigrationRegistry.route(from: 1, to: 2)
        let replay = try MigrationRouteReplay.run(original, route: route)
        let candidateIdentity = CanonicalByteIdentity.compute(files: replay.finalFiles.files).rawValue

        let detached = FileManager.default.temporaryDirectory
            .appendingPathComponent("hamii-historical-candidate-\(UUID().uuidString)")
        defer {
            _ = try? git(root, "worktree", "remove", "--force", detached.path)
            try? FileManager.default.removeItem(at: detached)
        }
        _ = try git(root, "worktree", "add", "--detach", detached.path, sourceOID)
        let changedPaths = Set(original.files.keys).union(replay.finalFiles.files.keys)
            .filter { original.files[$0] != replay.finalFiles.files[$0] }.sorted()
        for path in changedPaths {
            try XCTUnwrap(replay.finalFiles.files[path]).write(
                to: detached.appendingPathComponent(path), options: .atomic)
        }
        _ = try GitCommand.run(at: detached, ["add", "--"] + changedPaths)
        _ = try git(detached, "-c", "user.name=hamii", "-c", "user.email=hamii@localhost",
                    "-c", "core.hooksPath=/dev/null", "commit", "--no-gpg-sign", "-q", "-m", "v1 to v2")
        let candidateOID = try git(detached, "rev-parse", "HEAD")
        let candidateTree = try git(detached, "rev-parse", "HEAD^{tree}")
        let candidateRevision = try GitCanonicalRevisionCalculator().current(at: detached).rawValue
        let committed = try MigrationRepositoryInput.load(from: detached)
        XCTAssertEqual(committed.files, replay.finalFiles.files)
        let new = try manifest(committed)
        let reviewID = UUID().uuidString.lowercased()
        let retentionRef = "refs/hamii/migration-candidates/\(reviewID)"
        _ = try git(root, "update-ref", retentionRef, candidateOID)
        let nameStatus = try git(root, "diff", "--name-status", sourceOID, candidateOID)
        let diffStat = try git(root, "diff", "--stat", sourceOID, candidateOID)
        let validation = MigrationValidationResult(currentFormat: 2,
            canonicalSnapshotIdentity: candidateIdentity,
            documentID: new.id, documentRevision: new.revision)
        let indexValidation = MigrationIndexValidationResult(
            sourceCanonicalIdentity: candidateIdentity,
            indexGenerationID: UUID().uuidString.lowercased(),
            canonicalRevision: candidateRevision)
        let store = MigrationReviewStore(root: root)
        switch kind {
        case .legacy:
            try store.write(MigrationReviewPackage(recordFormatVersion: 1, reviewID: reviewID,
                sourceRef: sourceRef, sourceOID: sourceOID, sourceTreeOID: sourceTree,
                sourceCanonicalRevision: sourceRevision, sourceCanonicalIdentity: sourceIdentity,
                sourceFormatVersion: 1, targetFormatVersion: 2,
                sourceDocumentRevision: old.revision, candidateDocumentRevision: new.revision,
                classification: .losslessWithNormalization, edgePath: ["1->2"],
                candidateOID: candidateOID, candidateTreeOID: candidateTree,
                retentionRef: retentionRef, changedPaths: changedPaths,
                diffNameStatus: nameStatus, diffStat: diffStat,
                validation: validation, indexValidation: indexValidation,
                resolutionAudit: nil))
        case .composed:
            try store.writeComposed(MigrationComposedReviewPackage(recordFormatVersion: 3,
                reviewID: reviewID, sourceRef: sourceRef, sourceOID: sourceOID,
                sourceTreeOID: sourceTree, sourceCanonicalRevision: sourceRevision,
                sourceCanonicalIdentity: sourceIdentity,
                sourceFormatVersion: 1, targetFormatVersion: 2,
                sourceDocumentRevision: old.revision, candidateDocumentRevision: new.revision,
                classification: .losslessWithNormalization, receipts: replay.receipts,
                edgeResolutionAudits: [], candidateOID: candidateOID,
                candidateTreeOID: candidateTree, retentionRef: retentionRef,
                changedPaths: changedPaths, diffNameStatus: nameStatus, diffStat: diffStat,
                validation: validation, indexValidation: indexValidation))
        }
        let operationID = UUID()
        var pending: [String: Any] = [
            "formatVersion": kind == .legacy ? 1 : 2,
            "publicationID": UUID().uuidString,
            "reviewID": reviewID,
            "sourceRef": sourceRef,
            "expectedSourceOID": sourceOID,
            "candidateOID": candidateOID,
            "operationID": operationID.uuidString,
            "phase": afterCAS ? "refPublished" : "pending"
        ]
        if kind == .legacy {
            pending.merge([
                "sourceTreeOID": sourceTree,
                "sourceCanonicalRevision": sourceRevision,
                "sourceCanonicalIdentity": sourceIdentity,
                "sourceDocumentRevision": old.revision,
                "candidateTreeOID": candidateTree,
                "candidateCanonicalIdentity": candidateIdentity,
                "candidateDocumentID": new.id,
                "candidateDocumentRevision": new.revision,
                "retentionRef": retentionRef
            ]) { _, new in new }
        } else {
            let bytes = try store.loadRawBytes(reviewID)
            pending["reviewRecordFormatVersion"] = 3
            pending["reviewSHA256"] = SHA256.hash(data: bytes)
                .map { String(format: "%02x", $0) }.joined()
        }
        try WorktreeCoordinator(root: root).withExclusive {
            let generation = try CanonicalGenerationStore(root: root).bootstrapVerified(
                validatedIdentity: CanonicalSnapshotIdentity(rawValue: sourceIdentity)!)
            try WorktreeCoordinator(root: root).beginMigrationPublication(
                JSONSerialization.data(withJSONObject: pending, options: [.sortedKeys]))
            _ = try CanonicalGenerationStore(root: root).beginPending(old: generation,
                expectedNewIdentity: CanonicalSnapshotIdentity(rawValue: candidateIdentity),
                operationID: operationID)
        }
        if afterCAS { _ = try git(root, "update-ref", sourceRef, candidateOID, sourceOID) }
        return Fixture(root: root, reviewID: reviewID, sourceRef: sourceRef,
            sourceOID: sourceOID, candidateOID: candidateOID,
            sourceIdentity: sourceIdentity, candidateIdentity: candidateIdentity)
    }

    func testHistoricalPendingRecordsRecoverOldAndCandidateWithoutV2Index() throws {
        for kind in [RecordKind.legacy, .composed] {
            for afterCAS in [false, true] {
                let value = try fixture(kind, afterCAS: afterCAS)
                defer { try? FileManager.default.removeItem(at: value.root) }
                let publisher = MigrationPublisher(root: value.root, index: PublishedCanonicalIndex())
                XCTAssertTrue(publisher.hasPendingPublication)
                XCTAssertThrowsError(try CanonicalRepository(root: value.root).observe())
                let recovered = try publisher.recover()
                XCTAssertTrue(recovered.recovered)
                XCTAssertEqual(recovered.indexGenerationID, "")
                XCTAssertEqual(recovered.candidateOID,
                               afterCAS ? value.candidateOID : value.sourceOID)
                XCTAssertEqual(try git(value.root, "rev-parse", "HEAD"), recovered.candidateOID)
                XCTAssertFalse(publisher.hasPendingPublication)
                XCTAssertEqual(try CanonicalGenerationStore(root: value.root).readStable()
                    .snapshotIdentity.rawValue,
                    afterCAS ? value.candidateIdentity : value.sourceIdentity)
                let repeated = try publisher.recover()
                XCTAssertEqual(repeated.canonicalSnapshotIdentity,
                               recovered.canonicalSnapshotIdentity)
                XCTAssertEqual(repeated.indexGenerationID, "")
                XCTAssertThrowsError(try CanonicalRepository(root: value.root).observe())
                if afterCAS {
                    let plan = try MigrationPreflight.plan(repository: value.root)
                    XCTAssertEqual(plan.sourceDocumentFormatVersion, 2)
                    XCTAssertEqual(plan.targetDocumentFormatVersion, 3)
                }
            }
        }
    }

    func testFreshHistoricalReviewCannotPublishV2AfterCurrentV3Cutover() throws {
        for kind in [RecordKind.legacy, .composed] {
            let value = try fixture(kind, afterCAS: false)
            defer { try? FileManager.default.removeItem(at: value.root) }
            let publisher = MigrationPublisher(root: value.root, index: PublishedCanonicalIndex())
            _ = try publisher.recover() // pre-CAS abort keeps the old review for inspection
            XCTAssertThrowsError(try publisher.publish(reviewID: value.reviewID,
                confirmedSourceOID: value.sourceOID, confirmedCandidateOID: value.candidateOID)) { error in
                guard case MigrationPublicationError.historicalReviewRequiresReprepare = error else {
                    return XCTFail("Expected reprepare guidance, got \(error)")
                }
                XCTAssertTrue(String(describing: error).contains("prepare a new Current-format review"))
            }
            XCTAssertEqual(try git(value.root, "rev-parse", "HEAD"), value.sourceOID)
            XCTAssertFalse(publisher.hasPendingPublication)
        }
    }

    func testHistoricalCandidateRecoveryStopsRemainGatedUntilExactReplayCompletes() throws {
        for kind in [RecordKind.legacy, .composed] {
            for stop in [MigrationPublicationStep.beforeMaterialization,
                         .duringCanonicalValidation, .beforeGateRelease] {
                let value = try fixture(kind, afterCAS: true)
                defer { try? FileManager.default.removeItem(at: value.root) }
                let stopped = MigrationPublisher(root: value.root,
                    index: PublishedCanonicalIndex()) { step in
                    if step == stop { throw Stopped() }
                }
                XCTAssertThrowsError(try stopped.recover(), "\(kind), \(stop)")
                XCTAssertTrue(stopped.hasPendingPublication)
                XCTAssertThrowsError(try CanonicalRepository(root: value.root).observe())
                let recovered = try MigrationPublisher(root: value.root,
                    index: PublishedCanonicalIndex()).recover()
                XCTAssertEqual(recovered.candidateOID, value.candidateOID)
                XCTAssertEqual(recovered.canonicalSnapshotIdentity, value.candidateIdentity)
                XCTAssertEqual(recovered.indexGenerationID, "")
                XCTAssertFalse(WorktreeCoordinator(root: value.root).migrationPublicationPending())
            }
        }
    }

    func testMissingRetainedHistoricalCandidateKeepsPendingGate() throws {
        for kind in [RecordKind.legacy, .composed] {
            let value = try fixture(kind, afterCAS: true)
            defer { try? FileManager.default.removeItem(at: value.root) }
            _ = try git(value.root, "update-ref", "-d",
                        "refs/hamii/migration-candidates/\(value.reviewID)", value.candidateOID)
            XCTAssertThrowsError(try MigrationPublisher(root: value.root,
                index: PublishedCanonicalIndex()).recover())
            XCTAssertTrue(WorktreeCoordinator(root: value.root).migrationPublicationPending())
            XCTAssertThrowsError(try CanonicalRepository(root: value.root).observe())
        }
    }
}
