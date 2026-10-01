import Darwin
import Foundation
import MachO
import XCTest
import HamiiApplication
import HamiiCore
@testable import HamiiFormat
@testable import HamiiIndex
@testable import HamiiMigrationRuntime
import HamiiMigrations

final class MigrationPublicationTests: XCTestCase {
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
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hamii-migration-publication-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: repositoryRoot.appendingPathComponent("Tests/Fixtures/format-v1-safe-project"), to: root)
        try Data(".hamii/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        _ = try git(root, "init", "-q")
        _ = try git(root, "checkout", "-q", "-b", "main")
        _ = try git(root, "add", ".")
        _ = try git(root, "-c", "user.name=Test", "-c", "user.email=test@localhost", "commit", "-q", "-m", "v1")
        return root
    }

    private func copyPrepared(_ template: URL) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hamii-migration-publication-copy-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: template, to: root)
        return root
    }

    private func git(_ root: URL, _ args: String...) throws -> String { try GitCommand.run(at: root, args) }

    private func oldClientToken(_ root: URL) throws -> ClientPrecondition {
        let repository = CanonicalRepository(root: root)
        return try WorktreeCoordinator(root: root).withReadyExclusive {
            try repository.clientPreconditionForCanonicalPaths(repository.canonicalJSONPaths())
        }
    }

    private func assertPendingGate(_ root: URL) throws {
        XCTAssertTrue(WorktreeCoordinator(root: root).migrationPublicationPending())
        XCTAssertThrowsError(try CanonicalRepository(root: root).observe()) { error in
            guard case CanonicalError.managedGitPending = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try CanonicalRepository(root: root).withCoordinatedSnapshot { $0 })
        let fake = ClientPrecondition("old")
        XCTAssertThrowsError(try ProjectService(repository: CanonicalRepository(root: root))
            .mutate(.createPage(name: "Blocked"), expectedState: fake, author: .human))
        XCTAssertThrowsError(try IndexQuerySession(projectRoot: root)
            .components(matching: "Badge", consumerScopeID: EntityID("scope_app")))
    }

    func testSuccessfulPublicationBindsCurrentSnapshotIndexAndInvalidatesClient() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try oldClientToken(root)
        let review = try MigrationCandidatePreparer().prepare(repository: root)
        let reviewPath = root.appendingPathComponent(".hamii/migration-reviews/\(review.reviewID).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: reviewPath.path))
        XCTAssertEqual(try MigrationReviewStore(root: root).loadComposed(review.reviewID).sourceCanonicalIdentity,
                       review.sourceCanonicalIdentity)
        let result = try MigrationPublisher(root: root, index: PublishedCanonicalIndex())
            .publish(reviewID: review.reviewID, confirmedSourceOID: review.sourceOID,
                     confirmedCandidateOID: review.candidateOID)
        XCTAssertEqual(result.candidateOID, review.candidateOID)
        XCTAssertEqual(try git(root, "rev-parse", "HEAD"), review.candidateOID)
        XCTAssertTrue(try git(root, "status", "--porcelain=v1", "--untracked-files=all").isEmpty)
        XCTAssertFalse(WorktreeCoordinator(root: root).migrationPublicationPending())
        XCTAssertTrue(FileManager.default.fileExists(atPath: reviewPath.path))
        let repository = CanonicalRepository(root: root)
        let observed = try repository.observe()
        XCTAssertNotEqual(observed.statePrecondition, old)
        let snapshot = try repository.withCoordinatedSnapshot { $0 }
        XCTAssertEqual(snapshot.identity.rawValue, review.validation.canonicalSnapshotIdentity)
        let generation = try PublishedCanonicalIndex().verifyPublished(at: root, snapshot: snapshot)
        XCTAssertEqual(generation.id.rawValue, result.indexGenerationID)
        XCTAssertEqual(generation.sourceGenerationBinding,
                       .bound(try CanonicalGenerationStore(root: root).requireMatchingStable(snapshot).generation))
        XCTAssertThrowsError(try ProjectService(repository: repository)
            .mutate(.createPage(name: "Stale"), expectedState: old, author: .human))
    }

    func testRawCanonicalByteIdentityMatchesCurrentSnapshotAlgorithm() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hamii-migration-identity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: repositoryRoot.appendingPathComponent("Samples/Starter"), to: root)
        let snapshot = try CanonicalRepository(root: root).withCoordinatedSnapshot { $0 }
        let files = try MigrationRepositoryInput.load(from: root)
        XCTAssertEqual(CanonicalByteIdentity.compute(files: files.files), snapshot.identity)
    }

    func testHistoricalGenerationMismatchAndCorruptionRejectBeforeCAS() throws {
        for scenario in ["mismatch", "corrupt"] {
            let root = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let review = try MigrationCandidatePreparer().prepare(repository: root)
            let generation = root.appendingPathComponent(".hamii/canonical-generation.json")
            if scenario == "mismatch" {
                _ = try CanonicalGenerationStore(root: root).bootstrapVerified(validatedIdentity:
                    CanonicalSnapshotIdentity(rawValue: String(repeating: "a", count: 64))!)
            } else {
                try Data("broken".utf8).write(to: generation)
            }
            XCTAssertThrowsError(try MigrationPublisher(root: root, index: PublishedCanonicalIndex())
                .publish(reviewID: review.reviewID, confirmedSourceOID: review.sourceOID,
                         confirmedCandidateOID: review.candidateOID), scenario)
            XCTAssertEqual(try git(root, "rev-parse", "HEAD"), review.sourceOID, scenario)
            XCTAssertFalse(WorktreeCoordinator(root: root).migrationPublicationPending(), scenario)
        }
    }

    func testMatchingHistoricalStableGenerationAdvancesToCandidate() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let review = try MigrationCandidatePreparer().prepare(repository: root)
        let source = try XCTUnwrap(CanonicalSnapshotIdentity(rawValue: review.sourceCanonicalIdentity))
        let before = try WorktreeCoordinator(root: root).withReadyExclusive {
            try CanonicalGenerationStore(root: root).bootstrapVerified(validatedIdentity: source)
        }
        _ = try MigrationPublisher(root: root, index: PublishedCanonicalIndex())
            .publish(reviewID: review.reviewID, confirmedSourceOID: review.sourceOID,
                     confirmedCandidateOID: review.candidateOID)
        let after = try CanonicalGenerationStore(root: root).readStable()
        XCTAssertEqual(after.generation.lineage, before.generation.lineage)
        XCTAssertEqual(after.generation.value, before.generation.value + 1)
        XCTAssertEqual(after.snapshotIdentity.rawValue, review.validation.canonicalSnapshotIdentity)
    }

    func testAllPendingPhasesFailClosedAndRecoverOldOrCandidate() throws {
        let template = try fixture()
        defer { try? FileManager.default.removeItem(at: template) }
        let review = try MigrationCandidatePreparer().prepare(repository: template)
        let steps: [MigrationPublicationStep] = [.pending, .beforeRefCAS, .afterRefCAS,
            .beforeMaterialization, .materialized, .beforeCanonicalValidation,
            .duringCanonicalValidation, .canonicalVerified,
            .beforeIndexBuild, .indexBuilt, .beforeIndexVerification, .indexPublished, .beforeGateRelease]
        for step in steps {
            let root = try copyPrepared(template)
            defer { try? FileManager.default.removeItem(at: root) }
            let old = try oldClientToken(root)
            let publisher = MigrationPublisher(root: root, index: PublishedCanonicalIndex()) { reached in
                if reached == step { throw Stopped() }
            }
            XCTAssertThrowsError(try publisher.publish(reviewID: review.reviewID,
                confirmedSourceOID: review.sourceOID, confirmedCandidateOID: review.candidateOID), "\(step)")
            try assertPendingGate(root)
            let beforeCAS = step == .pending || step == .beforeRefCAS
            XCTAssertEqual(try git(root, "rev-parse", "HEAD"), beforeCAS ? review.sourceOID : review.candidateOID)
            let reopened = MigrationPublisher(root: root, index: PublishedCanonicalIndex())
            let recovered = try reopened.recover()
            XCTAssertTrue(recovered.recovered)
            XCTAssertFalse(reopened.hasPendingPublication)
            XCTAssertEqual(try reopened.recover().canonicalSnapshotIdentity,
                           recovered.canonicalSnapshotIdentity)
            if beforeCAS {
                XCTAssertEqual(try git(root, "rev-parse", "HEAD"), review.sourceOID)
                XCTAssertThrowsError(try CanonicalRepository(root: root).observe()) // v1 remains historical
            } else {
                XCTAssertEqual(try git(root, "rev-parse", "HEAD"), review.candidateOID)
                let repository = CanonicalRepository(root: root)
                XCTAssertNotEqual(try repository.observe().statePrecondition, old)
                XCTAssertThrowsError(try ProjectService(repository: repository)
                    .mutate(.createPage(name: "Stale"), expectedState: old, author: .human))
            }
        }
    }

    func testPostCASIndexFailureDoesNotRollbackCanonicalAndCanRecover() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let review = try MigrationCandidatePreparer().prepare(repository: root)
        let publisher = MigrationPublisher(root: root, index: FailingIndex())
        XCTAssertThrowsError(try publisher.publish(reviewID: review.reviewID,
            confirmedSourceOID: review.sourceOID, confirmedCandidateOID: review.candidateOID))
        XCTAssertEqual(try git(root, "rev-parse", "HEAD"), review.candidateOID)
        try assertPendingGate(root)
        let recovered = try MigrationPublisher(root: root, index: PublishedCanonicalIndex()).recover()
        XCTAssertEqual(recovered.candidateOID, review.candidateOID)
        XCTAssertFalse(WorktreeCoordinator(root: root).migrationPublicationPending())
    }

    func testSourceMoveCanonicalByteChangeAndUnrecoveredJournalRejectBeforePending() throws {
        for scenario in ["sourceMove", "canonicalBytes", "journal"] {
            let root = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let review = try MigrationCandidatePreparer().prepare(repository: root)
            if scenario == "sourceMove" {
                try Data("external\n".utf8).write(to: root.appendingPathComponent("external.txt"))
                _ = try git(root, "add", "external.txt")
                _ = try git(root, "-c", "user.name=Test", "-c", "user.email=test@localhost",
                            "commit", "-q", "-m", "external")
            } else if scenario == "canonicalBytes" {
                let manifest = root.appendingPathComponent("hamii.json")
                var bytes = try Data(contentsOf: manifest)
                bytes.append(0x20)
                try bytes.write(to: manifest)
            } else {
                try Data().write(to: root.appendingPathComponent(".hamii/transaction.prepare"))
            }
            XCTAssertThrowsError(try MigrationPublisher(root: root, index: PublishedCanonicalIndex())
                .publish(reviewID: review.reviewID, confirmedSourceOID: review.sourceOID,
                         confirmedCandidateOID: review.candidateOID))
            XCTAssertFalse(WorktreeCoordinator(root: root).migrationPublicationPending())
        }
    }

    func testRawRefRaceBeforeCASFailsClosed() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let review = try MigrationCandidatePreparer().prepare(repository: root)
        let publisher = MigrationPublisher(root: root, index: PublishedCanonicalIndex()) { step in
            if step == .beforeRefCAS {
                let other = try self.git(root, "commit-tree", review.sourceTreeOID, "-p", review.sourceOID)
                _ = try self.git(root, "update-ref", review.sourceRef, other, review.sourceOID)
            }
        }
        XCTAssertThrowsError(try publisher.publish(reviewID: review.reviewID,
            confirmedSourceOID: review.sourceOID, confirmedCandidateOID: review.candidateOID))
        XCTAssertNotEqual(try git(root, "rev-parse", "HEAD"), review.candidateOID)
        try assertPendingGate(root)
        XCTAssertThrowsError(try MigrationPublisher(root: root, index: PublishedCanonicalIndex()).recover())
    }

    func testCLIPublishConfirmationAndStructuredRecovery() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let review = try MigrationCandidatePreparer().prepare(repository: root)
        let wrong = try cli(root, ["migrate", "publish", review.reviewID, review.sourceOID,
                                   String(repeating: "0", count: review.candidateOID.count)])
        XCTAssertEqual(wrong.status, 6)
        XCTAssertEqual(wrong.object["category"] as? String, "migration")
        XCTAssertFalse(WorktreeCoordinator(root: root).migrationPublicationPending())
        let published = try cli(root, ["migrate", "publish", review.reviewID, review.sourceOID, review.candidateOID])
        XCTAssertEqual(published.status, 0)
        XCTAssertEqual((published.object["migrationPublication"] as? [String: Any])?["candidateOID"] as? String,
                       review.candidateOID)
        let repeated = try cli(root, ["migrate", "recover"])
        XCTAssertEqual(repeated.status, 0)
        XCTAssertEqual((repeated.object["migrationPublication"] as? [String: Any])?["recovered"] as? Bool, true)

        let interrupted = try fixture()
        defer { try? FileManager.default.removeItem(at: interrupted) }
        let pendingReview = try MigrationCandidatePreparer().prepare(repository: interrupted)
        XCTAssertThrowsError(try MigrationPublisher(root: interrupted, index: PublishedCanonicalIndex()) { step in
            if step == .afterRefCAS { throw Stopped() }
        }.publish(reviewID: pendingReview.reviewID, confirmedSourceOID: pendingReview.sourceOID,
                  confirmedCandidateOID: pendingReview.candidateOID))
        let wrongRecovery = try cli(interrupted, ["git", "recover"])
        XCTAssertEqual(wrongRecovery.status, 7)
        XCTAssertEqual(wrongRecovery.object["category"] as? String, "transitionPending")
        let recovered = try cli(interrupted, ["migrate", "recover"])
        XCTAssertEqual(recovered.status, 0)
        XCTAssertEqual((recovered.object["migrationPublication"] as? [String: Any])?["candidateOID"] as? String,
                       pendingReview.candidateOID)
    }

    func testWrongConfirmationAndTamperedReviewRejectBeforePending() throws {
        let template = try fixture()
        defer { try? FileManager.default.removeItem(at: template) }
        let review = try MigrationCandidatePreparer().prepare(repository: template)
        for scenario in ["source", "candidate", "recordCandidate", "recordRef", "recordTree",
                         "recordIndex", "retention"] {
            let root = try copyPrepared(template)
            defer { try? FileManager.default.removeItem(at: root) }
            var source = review.sourceOID
            var candidate = review.candidateOID
            let recordURL = root.appendingPathComponent(".hamii/migration-reviews/\(review.reviewID).json")
            if scenario == "source" { source = String(repeating: "0", count: source.count) }
            if scenario == "candidate" { candidate = String(repeating: "0", count: candidate.count) }
            if scenario.hasPrefix("record") {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
                if scenario == "recordIndex" {
                    var index = try XCTUnwrap(object["indexValidation"] as? [String: Any])
                    index["sourceCanonicalIdentity"] = String(repeating: "0", count: 64)
                    object["indexValidation"] = index
                } else {
                    let field = scenario == "recordCandidate" ? "candidateOID" : scenario == "recordRef" ? "sourceRef" : "candidateTreeOID"
                    object[field] = scenario == "recordRef" ? "refs/heads/other" : String(repeating: "0", count: candidate.count)
                }
                try JSONSerialization.data(withJSONObject: object).write(to: recordURL)
            }
            if scenario == "retention" {
                _ = try git(root, "update-ref", review.retentionRef, review.sourceOID, review.candidateOID)
            }
            XCTAssertThrowsError(try MigrationPublisher(root: root, index: PublishedCanonicalIndex())
                .publish(reviewID: review.reviewID, confirmedSourceOID: source,
                         confirmedCandidateOID: candidate), scenario)
            XCTAssertFalse(WorktreeCoordinator(root: root).migrationPublicationPending(), scenario)
            XCTAssertEqual(try git(root, "rev-parse", "HEAD"), review.sourceOID, scenario)
        }
    }

    func testNeitherRefAndUnknownGitLockRemainGated() throws {
        let template = try fixture()
        defer { try? FileManager.default.removeItem(at: template) }
        let review = try MigrationCandidatePreparer().prepare(repository: template)
        for scenario in ["neither", "lock"] {
            let root = try copyPrepared(template)
            defer { try? FileManager.default.removeItem(at: root) }
            let publisher = MigrationPublisher(root: root, index: PublishedCanonicalIndex()) { step in
                if step == .pending { throw Stopped() }
            }
            XCTAssertThrowsError(try publisher.publish(reviewID: review.reviewID,
                confirmedSourceOID: review.sourceOID, confirmedCandidateOID: review.candidateOID))
            if scenario == "neither" {
                let other = try git(root, "commit-tree", review.sourceTreeOID, "-p", review.sourceOID)
                _ = try git(root, "update-ref", review.sourceRef, other, review.sourceOID)
            } else {
                try Data().write(to: root.appendingPathComponent(".git/index.lock"))
            }
            XCTAssertThrowsError(try MigrationPublisher(root: root, index: PublishedCanonicalIndex()).recover(), scenario)
            try assertPendingGate(root)
        }
    }

    func testSIGKILLAtProductionPublicationCheckpoints() throws {
        let template = try fixture()
        defer { try? FileManager.default.removeItem(at: template) }
        let review = try MigrationCandidatePreparer().prepare(repository: template)
        for stage in ["pending", "afterRefCAS", "indexDuringTransaction", "indexBeforePublish", "indexPublished"] {
            let root = try copyPrepared(template)
            defer { try? FileManager.default.removeItem(at: root) }
            let marker = root.appendingPathComponent(".hamii/test-writer-paused")
            let attempted = root.appendingPathComponent(".hamii/test-reader-attempted")
            let result = root.appendingPathComponent(".hamii/test-reader-result")
            let environment = ["HAMII_MIGRATION_TEST_ROOT": root.path,
                               "HAMII_MIGRATION_TEST_STAGE": stage,
                               "HAMII_MIGRATION_TEST_REVIEW": review.reviewID,
                               "HAMII_MIGRATION_TEST_SOURCE": review.sourceOID,
                               "HAMII_MIGRATION_TEST_CANDIDATE": review.candidateOID]
            let writer = try child("testMigrationWriterWorker", environment: environment)
            defer { if writer.isRunning { _ = kill(writer.processIdentifier, SIGKILL); writer.waitUntilExit() } }
            try awaitFile(marker, process: writer)
            let reader = try child("testMigrationReaderWorker", environment: environment.merging([
                "HAMII_MIGRATION_TEST_ATTEMPT": attempted.path,
                "HAMII_MIGRATION_TEST_RESULT": result.path
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
        }
    }

    func testMigrationWriterWorker() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rootPath = env["HAMII_MIGRATION_TEST_ROOT"],
              let stage = env["HAMII_MIGRATION_TEST_STAGE"],
              let review = env["HAMII_MIGRATION_TEST_REVIEW"],
              let source = env["HAMII_MIGRATION_TEST_SOURCE"],
              let candidate = env["HAMII_MIGRATION_TEST_CANDIDATE"] else { throw XCTSkip("Worker only") }
        let root = URL(fileURLWithPath: rootPath)
        func pause(_ label: String) -> Never {
            try! Data(label.utf8).write(to: root.appendingPathComponent(".hamii/test-writer-paused"))
            while true { Thread.sleep(forTimeInterval: 1) }
        }
        let index = PublishedCanonicalIndex { step in
            if stage == "indexBeforePublish", step == .beforePublish { pause(stage) }
            if stage == "indexDuringTransaction", step == .duringTransaction { pause(stage) }
        }
        let publisher = MigrationPublisher(root: root, index: index) { step in
            if String(describing: step) == stage {
                pause(stage)
            }
        }
        _ = try publisher.publish(reviewID: review, confirmedSourceOID: source, confirmedCandidateOID: candidate)
        XCTFail("Writer reached Ready without requested pause")
    }

    func testMigrationReaderWorker() throws {
        let env = ProcessInfo.processInfo.environment
        guard let root = env["HAMII_MIGRATION_TEST_ROOT"],
              let attempt = env["HAMII_MIGRATION_TEST_ATTEMPT"],
              let result = env["HAMII_MIGRATION_TEST_RESULT"] else { throw XCTSkip("Worker only") }
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
        process.arguments = ["-XCTest", "HamiiTests.MigrationPublicationTests/\(method)", bundle.path]
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

    private func cli(_ root: URL, _ arguments: [String]) throws -> (status: Int32, object: [String: Any]) {
        let executable = repositoryRoot.appendingPathComponent(".build/out/Products/Debug/hamii")
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--project", root.path] + arguments + ["--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let object = try JSONSerialization.jsonObject(with: output) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (process.terminationStatus, object)
    }
}
