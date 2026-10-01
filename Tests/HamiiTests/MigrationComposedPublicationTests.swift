import Darwin
import Foundation
import MachO
import XCTest
import HamiiApplication
import HamiiCore
import HamiiMigrations
@testable import HamiiFormat
@testable import HamiiIndex
@testable import HamiiMigrationRuntime

final class MigrationComposedPublicationTests: XCTestCase {
    private struct Stopped: Error {}

    private struct FailingIndex: CanonicalIndexPublishing {
        let delegate = PublishedCanonicalIndex()
        func validateCandidate(at root: URL, snapshot: CanonicalSnapshot) throws {
            try delegate.validateCandidate(at: root, snapshot: snapshot)
        }
        func rebuildPublished(at root: URL, snapshot: CanonicalSnapshot) throws -> IndexGenerationDescriptor {
            throw IndexError.stale
        }
        func verifyPublished(at root: URL, snapshot: CanonicalSnapshot) throws -> IndexGenerationDescriptor {
            try delegate.verifyPublished(at: root, snapshot: snapshot)
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hamii-composed-publication-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: repositoryRoot
            .appendingPathComponent("Tests/Fixtures/format-v1-safe-project"), to: root)
        try Data(".hamii/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        _ = try git(root, "init", "-q")
        _ = try git(root, "checkout", "-q", "-b", "main")
        _ = try git(root, "add", ".")
        _ = try git(root, "-c", "user.name=Test", "-c", "user.email=test@localhost",
                    "commit", "-q", "-m", "v1")
        return root
    }

    private func copyPrepared(_ template: URL) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hamii-composed-publication-copy-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: template, to: root)
        return root
    }

    private func git(_ root: URL, _ args: String...) throws -> String {
        try GitCommand.run(at: root, args)
    }

    private func assertPendingGate(_ root: URL) throws {
        XCTAssertTrue(WorktreeCoordinator(root: root).migrationPublicationPending())
        XCTAssertThrowsError(try CanonicalRepository(root: root).observe())
        XCTAssertThrowsError(try IndexQuerySession(projectRoot: root)
            .components(matching: "Badge", consumerScopeID: EntityID("scope_app")))
    }

    func testComposedRecordUsesRealEdgeAndPublishesWithPendingVersionTwo() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let review = try MigrationCandidatePreparer().prepareComposed(repository: root)
        XCTAssertEqual(review.recordFormatVersion, 3)
        XCTAssertEqual(review.receipts.map(\.edgeID), ["1->2"])
        XCTAssertEqual(try MigrationReviewStore(root: root).recordVersion(review.reviewID), 3)
        let reviewPath = root.appendingPathComponent(".hamii/migration-reviews/\(review.reviewID).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: reviewPath.path))
        let publisher = MigrationPublisher(root: root, index: PublishedCanonicalIndex()) { step in
            if step == .pending { throw Stopped() }
        }
        XCTAssertThrowsError(try publisher.publish(reviewID: review.reviewID,
            confirmedSourceOID: review.sourceOID, confirmedCandidateOID: review.candidateOID))
        try assertPendingGate(root)
        let pending = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: root.appendingPathComponent(".hamii/migration-publication.pending.json"))) as? [String: Any])
        XCTAssertEqual(pending["formatVersion"] as? Int, 2)
        XCTAssertEqual(pending["reviewRecordFormatVersion"] as? Int, 3)
        XCTAssertEqual(pending["expectedSourceOID"] as? String, review.sourceOID)
        XCTAssertEqual(pending["candidateOID"] as? String, review.candidateOID)
        let result = try MigrationPublisher(root: root, index: PublishedCanonicalIndex()).recover()
        XCTAssertEqual(result.candidateOID, review.sourceOID) // pre-CAS abort
        XCTAssertFalse(WorktreeCoordinator(root: root).migrationPublicationPending())
        XCTAssertThrowsError(try CanonicalRepository(root: root).observe()) // historical source

        let completed = try MigrationPublisher(root: root, index: PublishedCanonicalIndex())
            .publish(reviewID: review.reviewID, confirmedSourceOID: review.sourceOID,
                     confirmedCandidateOID: review.candidateOID)
        XCTAssertEqual(try git(root, "rev-parse", "HEAD"), review.candidateOID)
        XCTAssertEqual(completed.canonicalSnapshotIdentity, review.validation.canonicalSnapshotIdentity)
        XCTAssertNotNil(try MigrationReviewStore(root: root).loadComposed(review.reviewID))
        XCTAssertFalse(WorktreeCoordinator(root: root).migrationPublicationPending())
        XCTAssertEqual(try MigrationPublisher(root: root, index: PublishedCanonicalIndex())
            .recover().indexGenerationID, completed.indexGenerationID)
    }

    func testComposedPendingStopsRecoverOnlyOldOrValidatedFinalCandidate() throws {
        let template = try fixture()
        defer { try? FileManager.default.removeItem(at: template) }
        let review = try MigrationCandidatePreparer().prepareComposed(repository: template)
        let steps: [MigrationPublicationStep] = [.pending, .beforeRefCAS, .afterRefCAS,
            .beforeMaterialization, .materialized, .beforeCanonicalValidation,
            .duringCanonicalValidation, .canonicalVerified, .beforeIndexBuild,
            .indexBuilt, .beforeIndexVerification, .indexPublished, .beforeGateRelease]
        for step in steps {
            let root = try copyPrepared(template)
            defer { try? FileManager.default.removeItem(at: root) }
            let publisher = MigrationPublisher(root: root, index: PublishedCanonicalIndex()) { reached in
                if reached == step { throw Stopped() }
            }
            XCTAssertThrowsError(try publisher.publish(reviewID: review.reviewID,
                confirmedSourceOID: review.sourceOID, confirmedCandidateOID: review.candidateOID), "\(step)")
            try assertPendingGate(root)
            let beforeCAS = step == .pending || step == .beforeRefCAS
            XCTAssertEqual(try git(root, "rev-parse", "HEAD"),
                           beforeCAS ? review.sourceOID : review.candidateOID, "\(step)")
            let recovery = MigrationPublisher(root: root, index: PublishedCanonicalIndex())
            let result = try recovery.recover()
            XCTAssertTrue(result.recovered, "\(step)")
            XCTAssertFalse(recovery.hasPendingPublication, "\(step)")
            XCTAssertEqual(try recovery.recover().indexGenerationID, result.indexGenerationID,
                           "Recovery must not publish a second Index generation: \(step)")
            if beforeCAS {
                XCTAssertEqual(try git(root, "rev-parse", "HEAD"), review.sourceOID)
                XCTAssertThrowsError(try CanonicalRepository(root: root).observe())
            } else {
                XCTAssertEqual(try git(root, "rev-parse", "HEAD"), review.candidateOID)
                let snapshot = try CanonicalRepository(root: root).withCoordinatedSnapshot { $0 }
                XCTAssertEqual(snapshot.identity.rawValue, review.validation.canonicalSnapshotIdentity)
                XCTAssertEqual(try PublishedCanonicalIndex().verifyPublished(at: root, snapshot: snapshot)
                    .id.rawValue, result.indexGenerationID)
            }
        }
    }

    func testComposedPendingTamperCannotMisclassifyHeadOrReleaseGate() throws {
        let template = try fixture()
        defer { try? FileManager.default.removeItem(at: template) }
        let review = try MigrationCandidatePreparer().prepareComposed(repository: template)
        for scenario in ["oldOIDAsCandidate", "candidateOIDAsOld", "digest", "reviewBytes",
                         "reviewMissing", "retentionMissing"] {
            let root = try copyPrepared(template)
            defer { try? FileManager.default.removeItem(at: root) }
            let beforeCAS = scenario == "oldOIDAsCandidate"
            let publisher = MigrationPublisher(root: root, index: PublishedCanonicalIndex()) { reached in
                if reached == (beforeCAS ? .pending : .afterRefCAS) { throw Stopped() }
            }
            XCTAssertThrowsError(try publisher.publish(reviewID: review.reviewID,
                confirmedSourceOID: review.sourceOID, confirmedCandidateOID: review.candidateOID), scenario)
            let pendingURL = root.appendingPathComponent(".hamii/migration-publication.pending.json")
            let reviewURL = root.appendingPathComponent(".hamii/migration-reviews/\(review.reviewID).json")
            if scenario == "oldOIDAsCandidate" || scenario == "candidateOIDAsOld" || scenario == "digest" {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: pendingURL))
                    as? [String: Any])
                if scenario == "oldOIDAsCandidate" { object["candidateOID"] = review.sourceOID }
                if scenario == "candidateOIDAsOld" { object["expectedSourceOID"] = review.candidateOID }
                if scenario == "digest" { object["reviewSHA256"] = String(repeating: "0", count: 64) }
                try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: pendingURL)
            } else if scenario == "reviewBytes" {
                var bytes = try Data(contentsOf: reviewURL)
                bytes.append(0x20)
                try bytes.write(to: reviewURL)
            } else if scenario == "reviewMissing" {
                try FileManager.default.removeItem(at: reviewURL)
            } else {
                _ = try git(root, "update-ref", "-d", review.retentionRef, review.candidateOID)
            }
            let head = try git(root, "rev-parse", "HEAD")
            XCTAssertThrowsError(try MigrationPublisher(root: root, index: PublishedCanonicalIndex())
                .recover(), scenario)
            XCTAssertEqual(try git(root, "rev-parse", "HEAD"), head, scenario)
            try assertPendingGate(root)
        }
    }

    func testComposedPostCASDirtyWorktreeAndIndexFailureRecoverFromImmutableCandidate() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let review = try MigrationCandidatePreparer().prepareComposed(repository: root)
        XCTAssertThrowsError(try MigrationPublisher(root: root, index: FailingIndex())
            .publish(reviewID: review.reviewID, confirmedSourceOID: review.sourceOID,
                     confirmedCandidateOID: review.candidateOID))
        XCTAssertEqual(try git(root, "rev-parse", "HEAD"), review.candidateOID)
        try assertPendingGate(root)
        let manifestURL = root.appendingPathComponent("hamii.json")
        var dirty = try Data(contentsOf: manifestURL)
        dirty.append(0x20)
        try dirty.write(to: manifestURL)
        let recovered = try MigrationPublisher(root: root, index: PublishedCanonicalIndex()).recover()
        XCTAssertEqual(recovered.candidateOID, review.candidateOID)
        XCTAssertFalse(WorktreeCoordinator(root: root).migrationPublicationPending())
        XCTAssertTrue(try git(root, "status", "--porcelain=v1", "--untracked-files=all").isEmpty)
        XCTAssertEqual(try CanonicalRepository(root: root).withCoordinatedSnapshot { $0 }
            .identity.rawValue, review.validation.canonicalSnapshotIdentity)
    }

    func testComposedReviewTamperRejectsBeforePending() throws {
        let template = try fixture()
        defer { try? FileManager.default.removeItem(at: template) }
        let review = try MigrationCandidatePreparer().prepareComposed(repository: template)
        for scenario in ["sourceTree", "candidateTree", "changedPaths", "diffNameStatus",
                         "diffStat", "indexRevision", "receiptClassification"] {
            let root = try copyPrepared(template)
            defer { try? FileManager.default.removeItem(at: root) }
            let reviewURL = root.appendingPathComponent(".hamii/migration-reviews/\(review.reviewID).json")
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: reviewURL))
                as? [String: Any])
            switch scenario {
            case "sourceTree": object["sourceTreeOID"] = String(repeating: "0", count: review.sourceTreeOID.count)
            case "candidateTree": object["candidateTreeOID"] = String(repeating: "0", count: review.candidateTreeOID.count)
            case "changedPaths": object["changedPaths"] = ["bogus.json"]
            case "diffNameStatus": object["diffNameStatus"] = "M\twrong.json"
            case "diffStat": object["diffStat"] = "wrong.json | 1 +"
            case "indexRevision":
                var index = try XCTUnwrap(object["indexValidation"] as? [String: Any])
                index["canonicalRevision"] = String(repeating: "0", count: 64)
                object["indexValidation"] = index
            default:
                var receipts = try XCTUnwrap(object["receipts"] as? [[String: Any]])
                receipts[0]["classification"] = "potentiallyLossy"
                object["classification"] = "potentiallyLossy"
                object["receipts"] = receipts
            }
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: reviewURL)
            XCTAssertThrowsError(try MigrationPublisher(root: root, index: PublishedCanonicalIndex())
                .publish(reviewID: review.reviewID, confirmedSourceOID: review.sourceOID,
                         confirmedCandidateOID: review.candidateOID), scenario)
            XCTAssertEqual(try git(root, "rev-parse", "HEAD"), review.sourceOID, scenario)
            XCTAssertFalse(WorktreeCoordinator(root: root).migrationPublicationPending(), scenario)
        }
    }

    func testComposedUnknownHeadStaysGated() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let review = try MigrationCandidatePreparer().prepareComposed(repository: root)
        XCTAssertThrowsError(try MigrationPublisher(root: root, index: PublishedCanonicalIndex()) { step in
            if step == .pending { throw Stopped() }
        }.publish(reviewID: review.reviewID, confirmedSourceOID: review.sourceOID,
                  confirmedCandidateOID: review.candidateOID))
        let other = try git(root, "commit-tree", review.sourceTreeOID, "-p", review.sourceOID)
        _ = try git(root, "update-ref", review.sourceRef, other, review.sourceOID)
        XCTAssertThrowsError(try MigrationPublisher(root: root, index: PublishedCanonicalIndex()).recover())
        try assertPendingGate(root)
    }

    func testComposedHumanResolutionAuditPublishesExactReplay() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifestURL = root.appendingPathComponent("hamii.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
            as? [String: Any])
        var declarations = try XCTUnwrap(manifest["capabilityDeclarations"] as? [[String: Any]])
        var duplicate = try XCTUnwrap(declarations.first)
        duplicate["support"] = "portable"
        duplicate["reason"] = "second historical declaration"
        declarations.append(duplicate)
        manifest["capabilityDeclarations"] = declarations
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL)
        _ = try git(root, "add", "hamii.json")
        _ = try git(root, "-c", "user.name=Test", "-c", "user.email=test@localhost",
                    "commit", "-q", "-m", "ambiguous v1")
        let report = try MigrationCandidatePreparer().resolutionReport(repository: root)
        XCTAssertFalse(report.items.isEmpty)
        let resolution = MigrationResolutionManifest(source: report.source,
            decisions: try report.items.map {
                MigrationResolutionDecision(item: $0.id,
                    selectedCandidateID: try XCTUnwrap($0.choices.first).id)
            })
        let review = try MigrationCandidatePreparer().prepareComposed(repository: root, resolution: resolution)
        XCTAssertEqual(review.edgeResolutionAudits.map(\.edgeID), ["1->2"])
        XCTAssertEqual(review.receipts[0].resolutionDecisions, review.edgeResolutionAudits[0].decisions)
        XCTAssertEqual(review.receipts[0].losses, review.edgeResolutionAudits[0].losses)
        let result = try MigrationPublisher(root: root, index: PublishedCanonicalIndex())
            .publish(reviewID: review.reviewID, confirmedSourceOID: review.sourceOID,
                     confirmedCandidateOID: review.candidateOID)
        XCTAssertEqual(result.candidateOID, review.candidateOID)
        XCTAssertEqual(try MigrationReviewStore(root: root).loadComposed(review.reviewID).receipts,
                       review.receipts)
    }

    func testDuplicateReviewVersionCannotFallBackToLegacyPublisher() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let review = try MigrationCandidatePreparer().prepare(repository: root)
        XCTAssertEqual(review.recordFormatVersion, 1)
        let reviewURL = root.appendingPathComponent(".hamii/migration-reviews/\(review.reviewID).json")
        let original = try String(contentsOf: reviewURL, encoding: .utf8)
        let tampered = original.replacingOccurrences(of: "\"recordFormatVersion\":1",
            with: "\"recordFormatVersion\":1,\"recordFormatVersion\":1")
        XCTAssertNotEqual(original, tampered)
        try Data(tampered.utf8).write(to: reviewURL)
        XCTAssertThrowsError(try MigrationPublisher(root: root, index: PublishedCanonicalIndex())
            .publish(reviewID: review.reviewID, confirmedSourceOID: review.sourceOID,
                     confirmedCandidateOID: review.candidateOID))
        XCTAssertEqual(try git(root, "rev-parse", "HEAD"), review.sourceOID)
        XCTAssertFalse(WorktreeCoordinator(root: root).migrationPublicationPending())
    }

    func testComposedSIGKILLKeepsReaderGatedUntilRecovery() throws {
        let template = try fixture()
        defer { try? FileManager.default.removeItem(at: template) }
        let review = try MigrationCandidatePreparer().prepareComposed(repository: template)
        for stage in ["pending", "afterRefCAS", "indexDuringTransaction", "indexBeforePublish", "indexPublished"] {
            let root = try copyPrepared(template)
            defer { try? FileManager.default.removeItem(at: root) }
            let marker = root.appendingPathComponent(".hamii/test-composed-writer-paused")
            let attempted = root.appendingPathComponent(".hamii/test-composed-reader-attempted")
            let result = root.appendingPathComponent(".hamii/test-composed-reader-result")
            let environment = ["HAMII_COMPOSED_TEST_ROOT": root.path,
                               "HAMII_COMPOSED_TEST_STAGE": stage,
                               "HAMII_COMPOSED_TEST_REVIEW": review.reviewID,
                               "HAMII_COMPOSED_TEST_SOURCE": review.sourceOID,
                               "HAMII_COMPOSED_TEST_CANDIDATE": review.candidateOID]
            let writer = try child("testComposedWriterWorker", environment: environment)
            defer { if writer.isRunning { _ = kill(writer.processIdentifier, SIGKILL); writer.waitUntilExit() } }
            try awaitFile(marker, process: writer)
            let reader = try child("testComposedReaderWorker", environment: environment.merging([
                "HAMII_COMPOSED_TEST_ATTEMPT": attempted.path,
                "HAMII_COMPOSED_TEST_RESULT": result.path
            ]) { _, new in new })
            defer { if reader.isRunning { _ = kill(reader.processIdentifier, SIGKILL); reader.waitUntilExit() } }
            try awaitFile(attempted, process: reader)
            Thread.sleep(forTimeInterval: 0.12)
            XCTAssertFalse(FileManager.default.fileExists(atPath: result.path), stage)
            XCTAssertEqual(kill(writer.processIdentifier, SIGKILL), 0, stage)
            writer.waitUntilExit()
            XCTAssertEqual(writer.terminationStatus, SIGKILL, stage)
            try awaitFile(result, process: reader)
            reader.waitUntilExit()
            XCTAssertEqual(reader.terminationStatus, 0, stage)
            XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), "pending", stage)
            try assertPendingGate(root)
            let recovered = try MigrationPublisher(root: root, index: PublishedCanonicalIndex()).recover()
            XCTAssertTrue(recovered.recovered, stage)
            XCTAssertFalse(WorktreeCoordinator(root: root).migrationPublicationPending(), stage)
            XCTAssertEqual(try git(root, "rev-parse", "HEAD"),
                           stage == "pending" ? review.sourceOID : review.candidateOID, stage)
            XCTAssertEqual(try MigrationPublisher(root: root, index: PublishedCanonicalIndex())
                .recover().indexGenerationID, recovered.indexGenerationID, stage)
        }
    }

    func testComposedWriterWorker() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rootPath = env["HAMII_COMPOSED_TEST_ROOT"],
              let stage = env["HAMII_COMPOSED_TEST_STAGE"],
              let review = env["HAMII_COMPOSED_TEST_REVIEW"],
              let source = env["HAMII_COMPOSED_TEST_SOURCE"],
              let candidate = env["HAMII_COMPOSED_TEST_CANDIDATE"] else { throw XCTSkip("Worker only") }
        let root = URL(fileURLWithPath: rootPath)
        func pause(_ label: String) -> Never {
            try! Data(label.utf8).write(to: root.appendingPathComponent(".hamii/test-composed-writer-paused"))
            while true { Thread.sleep(forTimeInterval: 1) }
        }
        let index = PublishedCanonicalIndex { step in
            if stage == "indexBeforePublish", step == .beforePublish { pause(stage) }
            if stage == "indexDuringTransaction", step == .duringTransaction { pause(stage) }
        }
        let publisher = MigrationPublisher(root: root, index: index) { step in
            if String(describing: step) == stage { pause(stage) }
        }
        _ = try publisher.publish(reviewID: review, confirmedSourceOID: source,
                                  confirmedCandidateOID: candidate)
        XCTFail("Writer reached Ready without requested pause")
    }

    func testComposedReaderWorker() throws {
        let env = ProcessInfo.processInfo.environment
        guard let root = env["HAMII_COMPOSED_TEST_ROOT"],
              let attempt = env["HAMII_COMPOSED_TEST_ATTEMPT"],
              let result = env["HAMII_COMPOSED_TEST_RESULT"] else { throw XCTSkip("Worker only") }
        try Data().write(to: URL(fileURLWithPath: attempt))
        let value: String
        do {
            _ = try WorktreeCoordinator(root: URL(fileURLWithPath: root)).withReadyExclusive { true }
            value = "ready"
        } catch CanonicalError.managedGitPending {
            value = "pending"
        }
        try Data(value.utf8).write(to: URL(fileURLWithPath: result))
    }

    private func child(_ method: String, environment: [String: String]) throws -> Process {
        let bundle = Bundle(for: Self.self).bundleURL
        let executable = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-XCTest", "HamiiTests.MigrationComposedPublicationTests/\(method)", bundle.path]
        var childEnvironment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        for imageIndex in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(imageIndex) else { continue }
            let path = String(cString: name)
            if path.hasSuffix("/libTesting.dylib") {
                childEnvironment["DYLD_LIBRARY_PATH"] = URL(fileURLWithPath: path).deletingLastPathComponent().path
                break
            }
        }
        process.environment = childEnvironment
        process.standardOutput = Pipe()
        process.standardError = process.standardOutput
        try process.run()
        return process
    }

    private func awaitFile(_ url: URL, process: Process) throws {
        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: url.path) && process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("Worker did not reach \(url.lastPathComponent)")
            throw CocoaError(.fileReadUnknown)
        }
    }
}
