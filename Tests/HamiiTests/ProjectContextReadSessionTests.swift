import Foundation
import XCTest
import HamiiApplication
import HamiiCore
@testable import HamiiFormat

final class ProjectContextReadSessionTests: XCTestCase {
    private struct Stopped: Error {}

    private func project() throws -> (URL, CanonicalRepository, EntityID) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hamii-context-session-\(UUID().uuidString)", isDirectory: true)
        let repository = CanonicalRepository(root: root)
        let document = try repository.create(name: "Session")
        return (root, repository, try XCTUnwrap(document.scopes.first?.id))
    }

    private func expectPermanentlyInvalidated(_ session: ProjectContextReadSession,
                                              scopeID: EntityID,
                                              checkFirst: (Error) -> Void) {
        XCTAssertThrowsError(try session.resources(consumerScopeID: scopeID, kind: .component)) { error in
            checkFirst(error)
        }
        XCTAssertThrowsError(try session.resources(consumerScopeID: scopeID, kind: .component)) { error in
            XCTAssertEqual(error as? ProjectContextSessionError, .invalidated)
        }
    }

    func testProductionVerifierAndSessionShareExactStateAndDoNotHoldWorktreeLock() throws {
        let (root, repository, scope) = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let started = try ProjectContextReadSession.start(repository: repository)
        let state = started.initialSummary.observation.statePrecondition
        try repository.verifyCurrent(state)
        let current = try ProjectContextService(repository: repository).resources(
            consumerScopeID: scope, kind: .component, expectedState: state)
        let cached = try started.session.resources(consumerScopeID: scope, kind: .component)
        XCTAssertEqual(cached, current)
        XCTAssertEqual(cached.observation, started.initialSummary.observation)

        // A separate repository instance can save while the session is idle.
        let writer = ProjectService(repository: CanonicalRepository(root: root))
        _ = try writer.mutate(.createPage(name: "Writer"), expectedState: state, author: .human)
        expectPermanentlyInvalidated(started.session, scopeID: scope) { error in
            guard case AuthoringError.staleState = error else { return XCTFail("Wrong error: \(error)") }
        }
        XCTAssertThrowsError(try writer.mutate(.createPage(name: "Old session"),
            expectedState: state, author: .human)) { error in
            guard case AuthoringError.staleState = error else { return XCTFail("Wrong error: \(error)") }
        }
        let fresh = try ProjectContextReadSession.start(repository: CanonicalRepository(root: root))
        XCTAssertNotEqual(fresh.initialSummary.observation.statePrecondition, state)
    }

    func testPendingGatesAndEpochFailureReturnNoCachedPayload() throws {
        for marker in ["managed-git-transition.json", "merge-publication.pending.json",
                       "migration-publication.pending.json"] {
            let (root, repository, scope) = try project()
            defer { try? FileManager.default.removeItem(at: root) }
            let session = try ProjectContextReadSession.start(repository: repository).session
            try Data("{}".utf8).write(to: root.appendingPathComponent(".hamii/\(marker)"), options: .atomic)
            expectPermanentlyInvalidated(session, scopeID: scope) { error in
                guard case CanonicalError.managedGitPending = error else { return XCTFail("\(marker): \(error)") }
            }
        }
        for change in ["missing", "corrupt"] {
            let (root, repository, scope) = try project()
            defer { try? FileManager.default.removeItem(at: root) }
            let session = try ProjectContextReadSession.start(repository: repository).session
            let epoch = root.appendingPathComponent(".hamii/client-observation-epoch")
            if change == "missing" {
                try FileManager.default.removeItem(at: epoch)
            } else {
                try Data("corrupt\n".utf8).write(to: epoch, options: .atomic)
            }
            expectPermanentlyInvalidated(session, scopeID: scope) { error in
                if change == "missing" {
                    guard case AuthoringError.staleState = error else { return XCTFail("\(error)") }
                } else {
                    guard case CanonicalError.invalidClientEpoch = error else { return XCTFail("\(error)") }
                }
            }
        }
    }

    func testAgentProfileExternalBytesAndGenerationRecordFailureInvalidate() throws {
        for change in ["agent", "external", "generationMissing", "generationCorrupt"] {
            let (root, repository, scope) = try project()
            defer { try? FileManager.default.removeItem(at: root) }
            let session = try ProjectContextReadSession.start(repository: repository).session
            switch change {
            case "agent":
                let path = root.appendingPathComponent("hamii-agent-profiles.json")
                let before = try String(contentsOf: path, encoding: .utf8)
                let after = before.replacingOccurrences(of: "\"builder\"", with: "\"builderChanged\"")
                XCTAssertNotEqual(before, after)
                try after.write(to: path, atomically: true, encoding: .utf8)
            case "external":
                let path = root.appendingPathComponent("hamii.json")
                let before = try Data(contentsOf: path)
                try (before + Data(" \n".utf8)).write(to: path, options: .atomic)
            default:
                let path = root.appendingPathComponent(".hamii/canonical-generation.json")
                if change == "generationMissing" { try FileManager.default.removeItem(at: path) }
                else { try Data("{}".utf8).write(to: path, options: .atomic) }
            }
            expectPermanentlyInvalidated(session, scopeID: scope) { error in
                if change.hasPrefix("generation") {
                    guard error is CanonicalGenerationError else { return XCTFail("\(error)") }
                } else {
                    guard case AuthoringError.staleState = error else { return XCTFail("\(error)") }
                }
            }
        }
    }

    func testCoordinatedRoundTripRejectsOldSessionEvenWhenBytesReturn() throws {
        let (root, repository, scope) = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(".hamii/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try git(root, "init", "-q")
        try commit(root, "base")
        let main = try gitOutput(root, "branch", "--show-current")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try git(root, "branch", "other")
        let old = try ProjectContextReadSession.start(repository: repository)
        let oldState = old.initialSummary.observation.statePrecondition
        let switched = try ManagedGit(root: root).switchBranch("other", expectedState: oldState)
        XCTAssertEqual(old.initialSummary.observation.documentRevision, switched.document.revision)
        _ = try ManagedGit(root: root).switchBranch(main, expectedState: switched.statePrecondition)
        let fresh = try repository.observe()
        XCTAssertEqual(fresh.document.revision, old.initialSummary.observation.documentRevision)
        XCTAssertNotEqual(fresh.statePrecondition, oldState)
        expectPermanentlyInvalidated(old.session, scopeID: scope) { error in
            guard case AuthoringError.staleState = error else { return XCTFail("\(error)") }
        }
    }

    func testJournalRecoveryDoesNotResurrectOldSession() throws {
        for stop in [TransactionStep.prepared, .ready] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("hamii-context-journal-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            var armed = false
            let repository = CanonicalRepository(root: root) { step in
                if armed && String(describing: step) == String(describing: stop) { throw Stopped() }
            }
            let document = try repository.create(name: "Journal")
            let scope = try XCTUnwrap(document.scopes.first?.id)
            let started = try ProjectContextReadSession.start(repository: repository)
            armed = true
            XCTAssertThrowsError(try ProjectService(repository: repository).mutate(.createPage(name: "Changed"),
                expectedState: started.initialSummary.observation.statePrecondition, author: .human))
            armed = false
            expectPermanentlyInvalidated(started.session, scopeID: scope) { error in
                // The verifier performs journal recovery but deliberately does
                // not bootstrap/reconcile a pending CanonicalGeneration.
                guard case CanonicalGenerationError.pending = error else { return XCTFail("\(stop): \(error)") }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".hamii/transaction.ready").path))
            XCTAssertNotEqual(try CanonicalRepository(root: root).observe().statePrecondition,
                started.initialSummary.observation.statePrecondition)
        }
    }

    private func commit(_ root: URL, _ message: String) throws {
        try git(root, "add", "-A")
        try git(root, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", message)
    }

    private func git(_ root: URL, _ args: String...) throws { _ = try gitOutput(root, args) }

    private func gitOutput(_ root: URL, _ args: String...) throws -> String { try gitOutput(root, args) }

    private func gitOutput(_ root: URL, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "Git", code: Int(process.terminationStatus)) }
        return String(decoding: output, as: UTF8.self)
    }
}
