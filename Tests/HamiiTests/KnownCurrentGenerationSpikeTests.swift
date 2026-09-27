import Foundation
import SQLite3
import XCTest
import HamiiCore
import HamiiFormat
import HamiiIndex

/// Experimental process-local knowledge. This is deliberately outside production query code.
final class KnownCurrentGenerationSpikeTests: XCTestCase {
    private enum Freshness: String { case knownCurrent, unknown, knownStale }

    private struct Session {
        var canonicalGeneration: Int?
        var indexedGeneration: Int?
        var observationValid = false

        var freshness: Freshness {
            guard observationValid, let canonicalGeneration else { return .unknown }
            return indexedGeneration == canonicalGeneration ? .knownCurrent : .knownStale
        }

        mutating func verifiedOpen(generation: Int, indexed: Bool) {
            canonicalGeneration = generation
            indexedGeneration = indexed ? generation : nil
            observationValid = true
        }

        mutating func saved(generation: Int) {
            canonicalGeneration = generation
        }

        mutating func published() { indexedGeneration = canonicalGeneration }
        mutating func externalSignal() { observationValid = false }
    }

    private func timed<T>(_ operation: () throws -> T) rethrows -> (T, Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = try operation()
        return (value, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }

    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        return sorted[Int(ceil(Double(sorted.count) * fraction)) - 1]
    }

    private func git(_ root: URL, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + args
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, args.joined(separator: " "))
    }

    private func directRowCount(_ url: URL, name: String) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw IndexError.sqlite("Could not open prototype reader")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT count(*) FROM components WHERE name = ?", -1, &statement, nil) == SQLITE_OK else {
            throw IndexError.sqlite("Could not prepare prototype query")
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = sqlite3_bind_text(statement, 1, name, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw IndexError.sqlite("Could not read prototype row") }
        return Int(sqlite3_column_int(statement, 0))
    }

    func testKnownCurrentProposalAndUnobservedExternalWriterCounterexample() throws {
        guard let resultPath = ProcessInfo.processInfo.environment["HAMII_KNOWN_CURRENT_SPIKE_RESULT"] else {
            throw XCTSkip("Run with HAMII_KNOWN_CURRENT_SPIKE_RESULT to collect the controlled Spike")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let project = temporary.appendingPathComponent("Project")
        try FileManager.default.copyItem(at: root.appendingPathComponent("Samples/Starter"), to: project)
        try git(project, ["init", "-q", "-b", "main"])
        try git(project, ["add", "-A"])
        try git(project, ["-c", "user.name=Spike", "-c", "user.email=spike@example.invalid", "commit", "-qm", "baseline"])

        let repository = CanonicalRepository(root: project)
        let before = try repository.load()
        let scope = try XCTUnwrap(before.scopes.first?.id)
        var withComponent = before
        withComponent.revision += 1
        withComponent.components = [ComponentDefinition(id: EntityID("component_probe"), name: "BaseButton", ownerScopeID: scope,
                                                        root: Layer(id: EntityID("layer_probe"), kind: .stack, name: "Root"))]
        try repository.save(withComponent, expected: before)
        try git(project, ["add", "-A"])
        try git(project, ["-c", "user.name=Spike", "-c", "user.email=spike@example.invalid", "commit", "-qm", "component"])

        let calculator = GitCanonicalRevisionCalculator()
        let index = try LocalIndex(projectRoot: project, documentID: withComponent.id, revisionCalculator: calculator,
                                   storageRoot: temporary.appendingPathComponent("Indexes"))
        var session = Session()
        let coldState = session.freshness
        XCTAssertEqual(coldState, .unknown)
        let (source, coldVerificationMs) = try timed { try calculator.current(at: project) }
        let baseSnapshot = try repository.withCoordinatedSnapshot { $0 }
        try index.rebuild(from: baseSnapshot, canonicalRevision: source)
        session.verifiedOpen(generation: 1, indexed: true)
        XCTAssertEqual(session.freshness, .knownCurrent)

        var warmGateMs: [Double] = []
        var warmDirectQueryMs: [Double] = []
        var productionQueryMs: [Double] = []
        for _ in 0..<15 {
            let (state, gateMs) = timed { session.freshness }
            XCTAssertEqual(state, .knownCurrent)
            warmGateMs.append(gateMs)
            let (count, directMs) = try timed { try directRowCount(index.url, name: "BaseButton") }
            XCTAssertEqual(count, 1)
            warmDirectQueryMs.append(directMs)
            let (hits, actualMs) = try timed {
                try index.components(matching: "BaseButton", consumerScopeID: scope,
                                     documentID: withComponent.id, revision: withComponent.revision,
                                     expectedSourceIdentity: baseSnapshot.identity)
            }
            XCTAssertEqual(hits.count, 1)
            productionQueryMs.append(actualMs)
        }

        var renamed = withComponent
        renamed.revision += 1
        renamed.components[0].name = "NextButton"
        try repository.save(renamed, expected: withComponent)
        session.saved(generation: 2)
        let afterSave = session.freshness
        XCTAssertEqual(afterSave, .knownStale)
        let nextSource = try calculator.current(at: project)
        let renamedSnapshot = try repository.withCoordinatedSnapshot { $0 }
        try index.rebuild(from: renamedSnapshot, canonicalRevision: nextSource)
        session.published()
        let afterPublish = session.freshness
        XCTAssertEqual(afterPublish, .knownCurrent)
        XCTAssertEqual(try directRowCount(index.url, name: "NextButton"), 1)

        var reopened = Session()
        let afterRestart = reopened.freshness
        XCTAssertEqual(afterRestart, .unknown)
        let (_, restartVerificationMs) = try timed { try calculator.current(at: project) }
        reopened.verifiedOpen(generation: 2, indexed: true)
        XCTAssertEqual(reopened.freshness, .knownCurrent)
        reopened.externalSignal()
        let afterExternalSignal = reopened.freshness
        XCTAssertEqual(afterExternalSignal, .unknown)

        // Negative control: a non-coordinating editor writes without sending a signal.
        let componentURL = project.appendingPathComponent("components/component_probe.json")
        let oldBytes = try Data(contentsOf: componentURL)
        let oldText = try XCTUnwrap(String(data: oldBytes, encoding: .utf8))
        XCTAssertTrue(oldText.contains("NextButton"))
        let externalBytes = try XCTUnwrap(oldText.replacingOccurrences(of: "NextButton", with: "ElseButton").data(using: .utf8))
        try externalBytes.write(to: componentURL)
        let falselyKnownCurrent = session.freshness == .knownCurrent
        XCTAssertTrue(falselyKnownCurrent)
        XCTAssertEqual(try directRowCount(index.url, name: "NextButton"), 1)
        XCTAssertThrowsError(try index.components(matching: "NextButton", consumerScopeID: scope,
                                                  documentID: renamed.id, revision: renamed.revision,
                                                  expectedSourceIdentity: renamedSnapshot.identity)) { error in
            XCTAssertEqual(String(describing: error), String(describing: IndexError.stale))
        }
        session.externalSignal()
        let afterDetectedExternalChange = session.freshness
        XCTAssertEqual(afterDetectedExternalChange, .unknown)

        // A real branch switch is another unobserved mutation of this same worktree.
        try oldBytes.write(to: componentURL)
        try git(project, ["add", "-A"])
        try git(project, ["-c", "user.name=Spike", "-c", "user.email=spike@example.invalid", "commit", "-qm", "renamed"])
        try git(project, ["checkout", "-qb", "other"])
        let branchBase = try repository.load()
        var branchDocument = branchBase
        branchDocument.revision += 1
        branchDocument.components[0].name = "BranchButton"
        try repository.save(branchDocument, expected: branchBase)
        try git(project, ["add", "-A"])
        try git(project, ["-c", "user.name=Spike", "-c", "user.email=spike@example.invalid", "commit", "-qm", "branch variant"])
        try git(project, ["checkout", "-q", "main"])
        let mainDocument = try repository.load()
        let mainSource = try calculator.current(at: project)
        let mainSnapshot = try repository.withCoordinatedSnapshot { $0 }
        try index.rebuild(from: mainSnapshot, canonicalRevision: mainSource)
        var branchSession = Session()
        branchSession.verifiedOpen(generation: 3, indexed: true)
        XCTAssertEqual(branchSession.freshness, .knownCurrent)
        try git(project, ["checkout", "-q", "other"])
        let unobservedBranchSwitchWouldFalselyReturnCurrent = branchSession.freshness == .knownCurrent
        XCTAssertTrue(unobservedBranchSwitchWouldFalselyReturnCurrent)
        XCTAssertEqual(try directRowCount(index.url, name: "NextButton"), 1)
        XCTAssertThrowsError(try index.components(matching: "NextButton", consumerScopeID: scope,
                                                  documentID: mainDocument.id, revision: mainDocument.revision,
                                                  expectedSourceIdentity: mainSnapshot.identity)) { error in
            XCTAssertEqual(String(describing: error), String(describing: IndexError.stale))
        }
        branchSession.externalSignal()
        let afterBranchSignal = branchSession.freshness
        XCTAssertEqual(afterBranchSignal, .unknown)

        // A separate hamii repository instance honors the file lock, but that lock
        // does not notify an already-open process-local index session of the save.
        let branchSource = try calculator.current(at: project)
        let branchSnapshot = try repository.withCoordinatedSnapshot { $0 }
        try index.rebuild(from: branchSnapshot, canonicalRevision: branchSource)
        var peerSession = Session()
        peerSession.verifiedOpen(generation: 4, indexed: true)
        let peerRepository = CanonicalRepository(root: project)
        let peerBase = try peerRepository.load()
        var peerUpdate = peerBase
        peerUpdate.revision += 1
        peerUpdate.components[0].name = "PeerButton"
        try peerRepository.save(peerUpdate, expected: peerBase)
        let unobservedHamiiPeerSaveWouldFalselyReturnCurrent = peerSession.freshness == .knownCurrent
        XCTAssertTrue(unobservedHamiiPeerSaveWouldFalselyReturnCurrent)
        XCTAssertEqual(try directRowCount(index.url, name: "BranchButton"), 1)
        XCTAssertThrowsError(try index.components(matching: "BranchButton", consumerScopeID: scope,
                                                  documentID: branchDocument.id, revision: branchDocument.revision,
                                                  expectedSourceIdentity: branchSnapshot.identity)) { error in
            XCTAssertEqual(String(describing: error), String(describing: IndexError.stale))
        }

        let result: [String: Any] = [
            "environment": "macOS arm64, Swift 6.4 debug XCTest, disposable Starter Git copy, one component, 15 warm runs",
            "states": ["coldOpen": coldState.rawValue, "afterHamiiSaveBeforeIndex": afterSave.rawValue,
                       "afterIndexPublication": afterPublish.rawValue, "afterProcessRestart": afterRestart.rawValue,
                       "afterExternalSignal": afterExternalSignal.rawValue, "afterBranchSignal": afterBranchSignal.rawValue,
                       "afterDetectedExternalChange": afterDetectedExternalChange.rawValue],
            "unobservedExternalEditWouldFalselyReturnCurrent": falselyKnownCurrent,
            "unobservedBranchSwitchWouldFalselyReturnCurrent": unobservedBranchSwitchWouldFalselyReturnCurrent,
            "unobservedHamiiPeerSaveWouldFalselyReturnCurrent": unobservedHamiiPeerSaveWouldFalselyReturnCurrent,
            "productionQueryRejectedThatEdit": true,
            "productionQueryRejectedThatBranchSwitch": true,
            "productionQueryRejectedThatPeerSave": true,
            "coldVerificationMs": coldVerificationMs,
            "restartVerificationMs": restartVerificationMs,
            "warmGateP50Ms": percentile(warmGateMs, 0.5), "warmGateP95Ms": percentile(warmGateMs, 0.95),
            "warmDirectSQLiteP50Ms": percentile(warmDirectQueryMs, 0.5), "warmDirectSQLiteP95Ms": percentile(warmDirectQueryMs, 0.95),
            "productionQueryP50Ms": percentile(productionQueryMs, 0.5), "productionQueryP95Ms": percentile(productionQueryMs, 0.95),
            "limits": "Generation numbers are test-local markers, not Document.revision or a production CanonicalGeneration. Session is a process-local prototype. Direct SQLite bypasses production freshness and is unsafe with unobserved peer hamii saves, external writers, or Git operations. Peer writer is a separate CanonicalRepository instance in one process, not a separate process. Restart is simulated by constructing a new Session in one process. No watcher, cross-process lease, snapshot binding, persisted index generation ID, or safe cold-open proof is implemented."
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: resultPath))
    }
}
