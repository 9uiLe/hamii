import Darwin
import Foundation
import MachO
import SQLite3
import XCTest
import HamiiApplication
import HamiiCore
@testable import HamiiFormat
@testable import HamiiIndex

final class ValidatedMergePublicationTests: XCTestCase {
    private struct Stopped: Error {}

    private struct FailingIndex: CanonicalIndexPublishing {
        let delegate = PublishedCanonicalIndex()
        func validateCandidate(at root: URL, snapshot: CanonicalSnapshot) throws { try delegate.validateCandidate(at: root, snapshot: snapshot) }
        func rebuildPublished(at root: URL, snapshot: CanonicalSnapshot) throws -> IndexGenerationDescriptor { throw IndexError.stale }
        func verifyPublished(at root: URL, snapshot: CanonicalSnapshot) throws -> IndexGenerationDescriptor {
            try delegate.verifyPublished(at: root, snapshot: snapshot)
        }
    }

    private struct Fixture {
        let root: URL
        let main: String
        let oldHead: String
        let otherHead: String
        let oldState: ClientPrecondition
        let documentID: EntityID
        let scopeID: EntityID
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hamii-publish-test-\(UUID().uuidString)", isDirectory: true)
        let repository = CanonicalRepository(root: root)
        let created = try repository.create(name: "Publish")
        try Data(".hamii/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try git(root, "init", "-q")
        try git(root, "config", "user.name", "hamii test")
        try git(root, "config", "user.email", "hamii-test@example.invalid")
        let service = ProjectService(repository: repository)
        _ = try service.mutate(.createComponent(name: "Button", scopeID: created.scopes[0].id),
                               expectedState: service.observe().statePrecondition, author: .human)
        try commit(root, "base")
        let main = try git(root, "branch", "--show-current")
        try git(root, "branch", "other")
        _ = try ManagedGit(root: root).switchBranch("other", expectedState: repository.observe().statePrecondition)
        _ = try service.mutate(.createPage(name: "Other"), expectedState: service.observe().statePrecondition, author: .human)
        try commit(root, "other page")
        let otherHead = try git(root, "rev-parse", "HEAD")
        _ = try ManagedGit(root: root).switchBranch(main, expectedState: repository.observe().statePrecondition)
        _ = try service.mutate(.createPage(name: "Main"), expectedState: service.observe().statePrecondition, author: .human)
        try commit(root, "main page")
        let observed = try service.observe()
        _ = try PublishedCanonicalIndex().rebuildPublished(at: root,
            snapshot: repository.withCoordinatedSnapshot { $0 })
        return Fixture(root: root, main: main, oldHead: try git(root, "rev-parse", "HEAD"),
                       otherHead: otherHead, oldState: observed.statePrecondition,
                       documentID: observed.document.id, scopeID: created.scopes[0].id)
    }

    func testPublicationAndRecoveryAtEveryCoordinatedPhase() throws {
        let phases: [MergePublicationStep] = [.pending, .beforeRefCAS, .afterRefCAS, .materialized,
            .canonicalVerified, .beforeIndexBuild, .indexBuilt, .beforeGateRelease, .gateReleased]
        for phase in phases {
            let f = try fixture()
            defer { cleanupTestCandidates(f.root); try? FileManager.default.removeItem(at: f.root) }
            let publisher = ValidatedMergePublisher(root: f.root, index: PublishedCanonicalIndex()) { reached in
                if reached == phase { throw Stopped() }
            }
            XCTAssertThrowsError(try publisher.publish("other", expectedState: f.oldState), "\(phase)")
            let pending = f.root.appendingPathComponent(".hamii/merge-publication.pending.json")
            let beforeCommit = phase == .pending || phase == .beforeRefCAS
            let afterReady = phase == .gateReleased
            XCTAssertEqual(try git(f.root, "rev-parse", "HEAD") == f.oldHead, beforeCommit, "\(phase)")
            XCTAssertEqual(FileManager.default.fileExists(atPath: pending.path), !afterReady, "\(phase)")
            let repository = CanonicalRepository(root: f.root)
            if !afterReady {
                XCTAssertThrowsError(try repository.observe(), "\(phase)") { error in
                    guard case CanonicalError.managedGitPending = error else { return XCTFail("Wrong error: \(error)") }
                }
                XCTAssertThrowsError(try ProjectService(repository: repository).mutate(.createPage(name: "Blocked"),
                    expectedState: f.oldState, author: .human), "\(phase)")
            }
            let recovered = try ValidatedMergePublisher(root: f.root, index: PublishedCanonicalIndex()).recover()
            XCTAssertEqual(recovered.document.pages.contains(where: { $0.name == "Other" }), !beforeCommit, "\(phase)")
            XCTAssertNotEqual(recovered.statePrecondition, f.oldState, "\(phase)")
            XCTAssertEqual(try ValidatedMergePublisher(root: f.root, index: PublishedCanonicalIndex()).recover().statePrecondition,
                           recovered.statePrecondition, "\(phase)")
            XCTAssertThrowsError(try ProjectService(repository: repository).mutate(.createPage(name: "Stale"),
                expectedState: f.oldState, author: .human), "\(phase)") { error in
                guard case AuthoringError.staleState = error else { return XCTFail("Wrong error: \(error)") }
            }
            let hits = try LocalIndex(projectRoot: f.root, documentID: f.documentID,
                                      revisionCalculator: GitCanonicalRevisionCalculator())
                .components(matching: "Button", consumerScopeID: f.scopeID,
                            documentID: f.documentID, revision: recovered.document.revision,
                            expectedSourceIdentity: repository.withCoordinatedSnapshot { $0.identity })
            XCTAssertEqual(hits.count, 1, "\(phase)")
            XCTAssertEqual(try git(f.root, "rev-parse", "other"), f.otherHead, "\(phase)")
            XCTAssertTrue(try git(f.root, "status", "--porcelain").isEmpty, "\(phase)")
        }
    }

    func testIndexFailureKeepsPublishedCanonicalPendingUntilRecovery() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        XCTAssertThrowsError(try ValidatedMergePublisher(root: f.root, index: FailingIndex())
            .publish("other", expectedState: f.oldState))
        XCTAssertNotEqual(try git(f.root, "rev-parse", "HEAD"), f.oldHead)
        XCTAssertThrowsError(try CanonicalRepository(root: f.root).observe())
        let recovered = try ValidatedMergePublisher(root: f.root, index: PublishedCanonicalIndex()).recover()
        XCTAssertTrue(recovered.document.pages.contains(where: { $0.name == "Other" }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".hamii/merge-publication.pending.json").path))
    }

    func testPublishedIndexSourceMismatchKeepsGateUntilRecoveryRebuildsFromCandidate() throws {
        let f = try fixture()
        defer { cleanupTestCandidates(f.root); try? FileManager.default.removeItem(at: f.root) }
        let indexURL = LocalIndexLocation.url(projectRoot: f.root, documentID: f.documentID)
        let corrupting = PublishedCanonicalIndex { step in
            guard step == .published else { return }
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(indexURL.path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            XCTAssertEqual(sqlite3_exec(db,
                "UPDATE metadata SET value='\(String(repeating: "a", count: 64))' WHERE key='sourceCanonicalIdentity'",
                nil, nil, nil), SQLITE_OK)
        }
        XCTAssertThrowsError(try ValidatedMergePublisher(root: f.root, index: corrupting)
            .publish("other", expectedState: f.oldState))
        XCTAssertNotEqual(try git(f.root, "rev-parse", "HEAD"), f.oldHead)
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            f.root.appendingPathComponent(".hamii/merge-publication.pending.json").path))
        XCTAssertThrowsError(try CanonicalRepository(root: f.root).observe())
        let recovered = try ValidatedMergePublisher(root: f.root, index: PublishedCanonicalIndex()).recover()
        let snapshot = try CanonicalRepository(root: f.root).withCoordinatedSnapshot { $0 }
        let generation = try PublishedCanonicalIndex().verifyPublished(at: f.root, snapshot: snapshot)
        XCTAssertEqual(generation.sourceCanonicalIdentity, snapshot.identity)
        XCTAssertEqual(generation.documentRevision, recovered.document.revision)
        XCTAssertThrowsError(try ProjectService(repository: CanonicalRepository(root: f.root))
            .mutate(.createPage(name: "Stale"), expectedState: f.oldState, author: .human))
    }

    func testReadyRecoveryKeepsPublishedGenerationAndSnapshotBinding() throws {
        let f = try fixture()
        defer { cleanupTestCandidates(f.root); try? FileManager.default.removeItem(at: f.root) }
        let publisher = ValidatedMergePublisher(root: f.root, index: PublishedCanonicalIndex())
        let published = try publisher.publish("other", expectedState: f.oldState)
        let repository = CanonicalRepository(root: f.root)
        let snapshot = try repository.withCoordinatedSnapshot { $0 }
        let generation = try PublishedCanonicalIndex().verifyPublished(at: f.root, snapshot: snapshot)
        XCTAssertEqual(generation.sourceCanonicalIdentity, snapshot.identity)
        XCTAssertEqual(generation.documentID, published.document.id)
        XCTAssertEqual(generation.documentRevision, published.document.revision)
        let recovered = try publisher.recover()
        XCTAssertEqual(recovered.document.revision, published.document.revision)
        let after = try PublishedCanonicalIndex().verifyPublished(at: f.root,
            snapshot: repository.withCoordinatedSnapshot { $0 })
        XCTAssertEqual(after, generation)
    }

    func testUnknownRefRemainsGated() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let publisher = ValidatedMergePublisher(root: f.root, index: PublishedCanonicalIndex()) { step in
            if step == .pending { throw Stopped() }
        }
        XCTAssertThrowsError(try publisher.publish("other", expectedState: f.oldState))
        try git(f.root, "update-ref", "refs/heads/\(f.main)", f.otherHead, f.oldHead)
        XCTAssertThrowsError(try ValidatedMergePublisher(root: f.root, index: PublishedCanonicalIndex()).recover()) { error in
            guard case MergePublicationError.unknownSourceState = error else { return XCTFail("Wrong error: \(error)") }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".hamii/merge-publication.pending.json").path))
        XCTAssertThrowsError(try CanonicalRepository(root: f.root).observe())
    }

    func testRecoveryPreservesLiveExternalRefLock() throws {
        let f = try fixture()
        defer { cleanupTestCandidates(f.root); try? FileManager.default.removeItem(at: f.root) }
        let publisher = ValidatedMergePublisher(root: f.root, index: PublishedCanonicalIndex()) { step in
            if step == .pending { throw Stopped() }
        }
        XCTAssertThrowsError(try publisher.publish("other", expectedState: f.oldState))
        try configureRefCASStop(f.root, main: f.main, stage: "refCASPrepared")
        let lock = f.root.appendingPathComponent(".git/refs/heads/\(f.main).lock")
        let marker = f.root.appendingPathComponent(".hamii/test-writer-paused")
        let external = try gitProcess(f.root, ["update-ref", "refs/heads/\(f.main)", f.otherHead, f.oldHead])
        defer { stopProcessTree(external) }
        try awaitFile(marker, process: external)
        XCTAssertTrue(external.isRunning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
        XCTAssertThrowsError(try ValidatedMergePublisher(root: f.root, index: PublishedCanonicalIndex()).recover()) { error in
            guard case MergePublicationError.gitLockOwnershipUnknown = error else { return XCTFail("Wrong error: \(error)") }
        }
        XCTAssertTrue(external.isRunning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".hamii/merge-publication.pending.json").path))
        XCTAssertThrowsError(try CanonicalRepository(root: f.root).observe())
        stopProcessTree(external)
        try FileManager.default.removeItem(at: lock)
        try git(f.root, "config", "--unset", "core.hooksPath")
        let recovered = try ValidatedMergePublisher(root: f.root, index: PublishedCanonicalIndex()).recover()
        XCTAssertEqual(try git(f.root, "rev-parse", "HEAD"), f.oldHead)
        XCTAssertNotEqual(recovered.statePrecondition, f.oldState)
    }

    func testRecoveryPreservesLiveExternalIndexLock() throws {
        let f = try fixture()
        defer { cleanupTestCandidates(f.root); try? FileManager.default.removeItem(at: f.root) }
        let publisher = ValidatedMergePublisher(root: f.root, index: PublishedCanonicalIndex()) { step in
            if step == .afterRefCAS { throw Stopped() }
        }
        XCTAssertThrowsError(try publisher.publish("other", expectedState: f.oldState))
        let marker = f.root.appendingPathComponent(".hamii/test-external-index-paused")
        let script = f.root.appendingPathComponent(".hamii/pause-clean.sh")
        try Data("#!/bin/sh\n: > '\(marker.path)'\nwhile :; do sleep 1; done\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        try git(f.root, "config", "filter.hamii-pause.clean", script.path)
        try Data("probe.txt filter=hamii-pause\n".utf8)
            .write(to: f.root.appendingPathComponent(".git/info/attributes"))
        let probe = f.root.appendingPathComponent("probe.txt")
        try Data("probe\n".utf8).write(to: probe)
        let lock = f.root.appendingPathComponent(".git/index.lock")
        let external = try gitProcess(f.root, ["add", "probe.txt"])
        defer { stopProcessTree(external) }
        try awaitFile(marker, process: external)
        XCTAssertTrue(external.isRunning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
        XCTAssertThrowsError(try ValidatedMergePublisher(root: f.root, index: PublishedCanonicalIndex()).recover()) { error in
            guard case MergePublicationError.gitLockOwnershipUnknown = error else { return XCTFail("Wrong error: \(error)") }
        }
        XCTAssertTrue(external.isRunning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".hamii/merge-publication.pending.json").path))
        XCTAssertThrowsError(try CanonicalRepository(root: f.root).observe())
        stopProcessTree(external)
        try FileManager.default.removeItem(at: lock)
        try FileManager.default.removeItem(at: probe)
        try git(f.root, "config", "--unset", "filter.hamii-pause.clean")
        let recovered = try ValidatedMergePublisher(root: f.root, index: PublishedCanonicalIndex()).recover()
        XCTAssertTrue(recovered.document.pages.contains(where: { $0.name == "Other" }))
        XCTAssertNotEqual(recovered.statePrecondition, f.oldState)
    }

    /// Every checkpoint runs in a separate OS process. The parent observes
    /// lock contention before SIGKILL, then opens a new publisher for recovery.
    func testSIGKILLPublicationAndIdempotentRestartRecovery() throws {
        let stages = ["materializationInternal", "refCASPrepared", "refCASCommitted",
                      "pending", "beforeRefCAS", "afterRefCAS", "beforeMaterialization",
                      "materialized", "beforeCanonicalValidation", "duringCanonicalValidation", "canonicalVerified",
                      "beforeIndexBuild", "indexBeforeBuild", "indexDuringTransaction", "indexBuilt", "indexBeforePublish",
                      "indexPublished", "beforeGateRelease", "gateReleased"]
        for stage in stages {
            let f = try fixture()
            defer { cleanupTestCandidates(f.root); try? FileManager.default.removeItem(at: f.root) }
            if stage == "materializationInternal" { try configureMaterializationStop(f.root, main: f.main) }
            if stage == "refCASPrepared" || stage == "refCASCommitted" {
                try configureRefCASStop(f.root, main: f.main, stage: stage)
            }
            let marker = f.root.appendingPathComponent(".hamii/test-writer-paused")
            let attempt = f.root.appendingPathComponent(".hamii/test-reader-attempt")
            let result = f.root.appendingPathComponent(".hamii/test-reader-result")
            let environment = ["HAMII_PUBLICATION_ROOT": f.root.path,
                               "HAMII_PUBLICATION_STAGE": stage,
                               "HAMII_PUBLICATION_STATE": try CanonicalRepository(root: f.root).observe().statePrecondition.rawValue]
            let writer = try child("testPublicationWriterWorker", environment: environment)
            defer {
                if writer.isRunning {
                    let descendants = (try? processDescendants(of: writer.processIdentifier)) ?? []
                    _ = kill(writer.processIdentifier, SIGKILL)
                    for identifier in descendants { _ = kill(identifier, SIGKILL) }
                    writer.waitUntilExit()
                }
            }
            try awaitFile(marker, process: writer)
            let reader = try child("testPublicationReaderWorker", environment: environment.merging([
                "HAMII_PUBLICATION_ATTEMPT": attempt.path,
                "HAMII_PUBLICATION_RESULT": result.path
            ]) { _, new in new })
            defer { if reader.isRunning { _ = kill(reader.processIdentifier, SIGKILL); reader.waitUntilExit() } }
            try awaitFile(attempt, process: reader)
            Thread.sleep(forTimeInterval: 0.12)
            XCTAssertFalse(FileManager.default.fileExists(atPath: result.path), "Reader crossed the writer lock at \(stage)")
            let descendants = ["materializationInternal", "refCASPrepared", "refCASCommitted"].contains(stage)
                ? try processDescendants(of: writer.processIdentifier) : []
            XCTAssertEqual(kill(writer.processIdentifier, SIGKILL), 0, stage)
            for identifier in descendants { _ = kill(identifier, SIGKILL) }
            writer.waitUntilExit()
            XCTAssertEqual(writer.terminationReason, .uncaughtSignal, stage)
            XCTAssertEqual(writer.terminationStatus, SIGKILL, stage)
            try awaitFile(result, process: reader)
            reader.waitUntilExit()
            XCTAssertEqual(reader.terminationStatus, 0, stage)
            let afterReady = stage == "gateReleased"
            XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), afterReady ? "ready" : "pending", stage)
            let pending = f.root.appendingPathComponent(".hamii/merge-publication.pending.json")
            XCTAssertEqual(FileManager.default.fileExists(atPath: pending.path), !afterReady, stage)
            if !afterReady {
                let repository = CanonicalRepository(root: f.root)
                XCTAssertThrowsError(try repository.observe(), stage) { error in
                    guard case CanonicalError.managedGitPending = error else { return XCTFail("Wrong error: \(error)") }
                }
                XCTAssertThrowsError(try repository.withCoordinatedIdentity { _, _ in true }, stage) { error in
                    guard case CanonicalError.managedGitPending = error else { return XCTFail("Wrong query gate: \(error)") }
                }
                XCTAssertThrowsError(try ProjectService(repository: repository)
                    .mutate(.createPage(name: "Pending"), expectedState: f.oldState, author: .human), stage)
            }
            // The filter is a test-only pause. Recovery must be allowed to
            // materialize the immutable candidate without pausing again.
            if stage == "materializationInternal" {
                try git(f.root, "config", "--unset", "filter.hamii-pause.smudge")
            }
            if stage == "refCASPrepared" || stage == "refCASCommitted" {
                try git(f.root, "config", "--unset", "core.hooksPath")
            }
            let reopened = ValidatedMergePublisher(root: f.root, index: PublishedCanonicalIndex())
            if stage == "materializationInternal" || stage == "refCASPrepared" {
                let lock = stage == "materializationInternal"
                    ? f.root.appendingPathComponent(".git/index.lock")
                    : f.root.appendingPathComponent(".git/refs/heads/\(f.main).lock")
                XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path), stage)
                XCTAssertThrowsError(try reopened.recover(), stage) { error in
                    guard case MergePublicationError.gitLockOwnershipUnknown = error else {
                        return XCTFail("Wrong lock error: \(error)")
                    }
                }
                XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path), stage)
                XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path), stage)
                // The test has observed and killed the entire writer process
                // tree, so it can perform explicit manual lock removal.
                try FileManager.default.removeItem(at: lock)
            }
            let recovered = try reopened.recover()
            XCTAssertEqual(try reopened.recover().statePrecondition, recovered.statePrecondition, stage)
            XCTAssertNotEqual(recovered.statePrecondition, f.oldState, stage)
            XCTAssertThrowsError(try ProjectService(repository: CanonicalRepository(root: f.root))
                .mutate(.createPage(name: "Stale"), expectedState: f.oldState, author: .human), stage)
            let hits = try LocalIndex(projectRoot: f.root, documentID: f.documentID,
                                      revisionCalculator: GitCanonicalRevisionCalculator())
                .components(matching: "Button", consumerScopeID: f.scopeID,
                            documentID: f.documentID, revision: recovered.document.revision,
                            expectedSourceIdentity: CanonicalRepository(root: f.root).withCoordinatedSnapshot { $0.identity })
            XCTAssertEqual(hits.count, 1, stage)
            XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path), stage)
            XCTAssertTrue(try git(f.root, "status", "--porcelain").isEmpty, stage)
            if !afterReady {
                XCTAssertEqual(try git(f.root, "worktree", "list", "--porcelain")
                    .split(separator: "\n").filter { $0.hasPrefix("worktree ") }.count, 1, stage)
            }
            if stage != "materializationInternal" {
                XCTAssertEqual(try git(f.root, "rev-parse", "other"), f.otherHead, stage)
            }
            let oldState = ["pending", "beforeRefCAS", "refCASPrepared"].contains(stage)
            XCTAssertEqual(try git(f.root, "rev-parse", "HEAD") == f.oldHead, oldState, stage)
        }
    }

    private func configureMaterializationStop(_ root: URL, main: String) throws {
        let script = root.appendingPathComponent(".hamii/pause-smudge.sh")
        let marker = root.appendingPathComponent(".hamii/test-writer-paused")
        let body = """
        #!/bin/sh
        if [ "$PWD" = "$(cd '\(root.path)' && pwd -P)" ]; then
          printf 'materializationInternal' > '\(marker.path)'
          while :; do sleep 1; done
        fi
        cat
        """
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        try git(root, "config", "filter.hamii-pause.smudge", script.path)
        _ = try ManagedGit(root: root).switchBranch("other", expectedState: CanonicalRepository(root: root).observe().statePrecondition)
        try Data("probe.txt filter=hamii-pause\n".utf8).write(to: root.appendingPathComponent(".gitattributes"))
        try Data("materialization probe\n".utf8).write(to: root.appendingPathComponent("probe.txt"))
        try commit(root, "materialization probe")
        _ = try ManagedGit(root: root).switchBranch(main, expectedState: CanonicalRepository(root: root).observe().statePrecondition)
    }

    private func configureRefCASStop(_ root: URL, main: String, stage: String) throws {
        let hooks = root.appendingPathComponent(".hamii/test-git-hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let script = hooks.appendingPathComponent("reference-transaction")
        let marker = root.appendingPathComponent(".hamii/test-writer-paused")
        let phase = stage == "refCASPrepared" ? "prepared" : "committed"
        let body = """
        #!/bin/sh
        if [ "$1" = '\(phase)' ]; then
          while read -r old new ref; do
            if [ "$ref" = 'refs/heads/\(main)' ]; then
              printf '\(stage)' > '\(marker.path)'
              while :; do sleep 1; done
            fi
          done
        fi
        exit 0
        """
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        try git(root, "config", "core.hooksPath", hooks.path)
    }

    private func processDescendants(of rootPID: Int32) throws -> [Int32] {
        let rows = try toolOutput("/bin/ps", ["-axo", "pid=,ppid="])
            .split(separator: "\n").compactMap { row -> (Int32, Int32)? in
                let values = row.split(whereSeparator: \.isWhitespace)
                guard values.count == 2, let pid = Int32(values[0]), let parent = Int32(values[1]) else { return nil }
                return (pid, parent)
            }
        var found = [rootPID]
        while true {
            let children = rows.filter { found.contains($0.1) && !found.contains($0.0) }.map(\.0)
            if children.isEmpty { break }
            found += children
        }
        return Array(found.dropFirst())
    }

    private func cleanupTestCandidates(_ root: URL) {
        guard let listed = try? git(root, "worktree", "list", "--porcelain") else { return }
        for line in listed.split(separator: "\n") where line.hasPrefix("worktree ") {
            let path = String(line.dropFirst("worktree ".count))
            let candidate = URL(fileURLWithPath: path)
            guard candidate.lastPathComponent == "worktree",
                  candidate.deletingLastPathComponent().lastPathComponent.hasPrefix("hamii-merge-publish-") else { continue }
            _ = try? git(root, "worktree", "remove", "--force", path)
            try? FileManager.default.removeItem(at: candidate.deletingLastPathComponent())
        }
    }

    func testPublicationWriterWorker() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rootPath = environment["HAMII_PUBLICATION_ROOT"],
              let stage = environment["HAMII_PUBLICATION_STAGE"],
              let state = environment["HAMII_PUBLICATION_STATE"] else { throw XCTSkip("Worker only") }
        let root = URL(fileURLWithPath: rootPath)
        func pause(_ name: String) -> Never {
            try! Data(name.utf8).write(to: root.appendingPathComponent(".hamii/test-writer-paused"))
            while true { Thread.sleep(forTimeInterval: 1) }
        }
        let index = PublishedCanonicalIndex { step in
            let name: String
            switch step {
            case .beforeBuild: name = "indexBeforeBuild"
            case .duringTransaction: name = "indexDuringTransaction"
            case .built: name = "indexBuilt"
            case .beforePublish: name = "indexBeforePublish"
            case .published: name = "indexPublished"
            }
            if name == stage { pause(name) }
        }
        let publisher = ValidatedMergePublisher(root: root, index: index) { step in
            if String(describing: step) == stage { pause(stage) }
        }
        _ = try publisher.publish("other", expectedState: ClientPrecondition(state))
        XCTFail("Worker reached Ready without its requested pause")
    }

    func testPublicationReaderWorker() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rootPath = environment["HAMII_PUBLICATION_ROOT"],
              let attemptPath = environment["HAMII_PUBLICATION_ATTEMPT"],
              let resultPath = environment["HAMII_PUBLICATION_RESULT"] else { throw XCTSkip("Worker only") }
        try Data().write(to: URL(fileURLWithPath: attemptPath))
        let value: String
        do {
            _ = try CanonicalRepository(root: URL(fileURLWithPath: rootPath)).observe()
            value = "ready"
        } catch CanonicalError.managedGitPending {
            value = "pending"
        }
        try Data(value.utf8).write(to: URL(fileURLWithPath: resultPath))
    }

    private func child(_ method: String, environment: [String: String]) throws -> Process {
        let bundle = Bundle(for: Self.self).bundleURL
        let xctest = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        guard FileManager.default.isExecutableFile(atPath: xctest.path) else {
            throw CocoaError(.executableNotLoadable)
        }
        let process = Process()
        process.executableURL = xctest
        process.arguments = ["-XCTest", "HamiiTests.ValidatedMergePublicationTests/\(method)", bundle.path]
        var childEnvironment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        for imageIndex in 0..<_dyld_image_count() {
            guard let imageName = _dyld_get_image_name(imageIndex) else { continue }
            let imagePath = String(cString: imageName)
            if imagePath.hasSuffix("/libTesting.dylib") {
                childEnvironment["DYLD_LIBRARY_PATH"] = URL(fileURLWithPath: imagePath)
                    .deletingLastPathComponent().path
                break
            }
        }
        process.environment = childEnvironment
        process.standardOutput = Pipe()
        process.standardError = process.standardOutput
        try process.run()
        return process
    }

    private func gitProcess(_ root: URL, _ args: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + args
        process.standardOutput = Pipe()
        process.standardError = process.standardOutput
        try process.run()
        return process
    }

    private func stopProcessTree(_ process: Process) {
        guard process.isRunning else { return }
        let descendants = (try? processDescendants(of: process.processIdentifier)) ?? []
        _ = kill(process.processIdentifier, SIGKILL)
        for identifier in descendants { _ = kill(identifier, SIGKILL) }
        process.waitUntilExit()
    }

    private func toolOutput(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func awaitFile(_ url: URL, process: Process) throws {
        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: url.path) && process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            let output = (process.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
            XCTFail("Worker exited or timed out: \(url.lastPathComponent): \(String(decoding: output, as: UTF8.self))")
            throw CocoaError(.fileReadUnknown)
        }
    }

    private func commit(_ root: URL, _ message: String) throws {
        try git(root, "add", "-A")
        try git(root, "commit", "-qm", message)
    }

    @discardableResult private func git(_ root: URL, _ args: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ManagedGitError.commandFailed(String(decoding: bytes, as: UTF8.self)) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
