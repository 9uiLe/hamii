import Darwin
import Foundation
import XCTest
import HamiiCore
import HamiiFormat
import HamiiIndex

/// Evidence for a conditional shared-generation protocol. None of this state is production code.
final class SharedWorktreeGenerationSpikeTests: XCTestCase {
    private struct Record: Codable {
        var phase: String
        var generation: Int
    }

    private struct SharedCalculator: CanonicalRevisionCalculating {
        func current(at root: URL) throws -> CanonicalRevision {
            let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: root.appendingPathComponent(".hamii/prototype-generation.json")))
            guard record.phase == "current" else { throw IndexError.stale }
            return CanonicalRevision("gen-\(record.generation)")
        }
    }

    private func withLock<T>(_ root: URL, exclusive: Bool, _ body: () throws -> T) throws -> T {
        let url = root.appendingPathComponent(".hamii/prototype-generation.lock")
        let fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        guard flock(fd, exclusive ? LOCK_EX : LOCK_SH) == 0 else { throw CocoaError(.fileReadUnknown) }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private func persist(_ record: Record, root: URL) throws {
        let directory = root.appendingPathComponent(".hamii")
        let temporary = directory.appendingPathComponent("prototype-generation.\(UUID().uuidString).tmp")
        let destination = directory.appendingPathComponent("prototype-generation.json")
        try JSONEncoder().encode(record).write(to: temporary)
        let file = open(temporary.path, O_RDONLY)
        guard file >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { close(file) }
        guard fsync(file) == 0, rename(temporary.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let parent = open(directory.path, O_RDONLY)
        guard parent >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private func read(_ root: URL) throws -> Record {
        try JSONDecoder().decode(Record.self, from: Data(contentsOf: root.appendingPathComponent(".hamii/prototype-generation.json")))
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

    private func childQuery(_ root: URL, index: URL, term: String) throws -> [String: Any] {
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = sourceRoot.appendingPathComponent("adr/index-consistency/spikes/shared-worktree-generation/artifacts/restart_query_probe.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, root.path, index.path, term]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(data: bytes, encoding: .utf8) ?? "")
        return try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
    }

    private func timed<T>(_ body: () throws -> T) rethrows -> (T, Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = try body()
        return (value, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }

    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        return sorted[Int(ceil(Double(sorted.count) * fraction)) - 1]
    }

    func testSharedGenerationOrderingAndRestart() throws {
        guard let resultPath = ProcessInfo.processInfo.environment["HAMII_SHARED_GENERATION_SPIKE_RESULT"] else {
            throw XCTSkip("Run with HAMII_SHARED_GENERATION_SPIKE_RESULT to collect the Spike")
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let project = temporary.appendingPathComponent("Project")
        let first = CanonicalRepository(root: project)
        let initial = try first.create(name: "Shared generation")
        try Data(".hamii/\n".utf8).write(to: project.appendingPathComponent(".gitignore"))
        try git(project, ["init", "-q", "-b", "main"])
        let owner = EntityID("scope_app")
        var base = initial
        base.scopes = [ArchitectureScope(id: owner, name: "App", parentID: nil)]
        base.components = [ComponentDefinition(id: EntityID("component_probe"), name: "Alpha", ownerScopeID: owner,
                                               root: Layer(id: EntityID("layer_probe"), kind: .stack, name: "Root"))]
        base.revision += 1
        try first.save(base, expected: initial)
        try git(project, ["add", "-A"])
        try git(project, ["-c", "user.name=Spike", "-c", "user.email=spike@example.invalid", "commit", "-qm", "base"])
        try persist(Record(phase: "current", generation: 0), root: project)
        let calculator = SharedCalculator()
        let index = try LocalIndex(projectRoot: project, documentID: base.id, revisionCalculator: calculator,
                                   storageRoot: temporary.appendingPathComponent("Indexes"))
        try withLock(project, exclusive: true) {
            try index.rebuild(from: first.load(), canonicalRevision: calculator.current(at: project))
        }
        func query(_ term: String, revision: Int) throws -> [ComponentHit] {
            try withLock(project, exclusive: false) {
                try index.components(matching: term, consumerScopeID: owner, documentID: base.id, revision: revision)
            }
        }
        XCTAssertEqual(try query("Alpha", revision: base.revision).count, 1)
        try withLock(project, exclusive: true) {
            try index.rebuild(from: base, canonicalRevision: CanonicalRevision("gen-1"))
        }
        XCTAssertThrowsError(try query("Alpha", revision: base.revision))
        try withLock(project, exclusive: true) {
            try index.rebuild(from: base, canonicalRevision: calculator.current(at: project))
        }

        let second = CanonicalRepository(root: project)
        var beta = base
        beta.revision += 1
        beta.components[0].name = "Beta"
        let (_, pendingWriteMs) = try timed {
            try withLock(project, exclusive: true) {
                try persist(Record(phase: "pending", generation: 0), root: project)
            }
        }
        XCTAssertEqual(try childQuery(project, index: index.url, term: "Alpha")["status"] as? String, "staleIndex")
        // Simulated crash after Canonical save but before final generation update.
        try withLock(project, exclusive: true) { try second.save(beta, expected: base) }
        XCTAssertEqual(try childQuery(project, index: index.url, term: "Alpha")["status"] as? String, "staleIndex")
        let pendingAfterSave = try read(project).phase
        XCTAssertEqual(pendingAfterSave, "pending")
        let (_, finalizeWriteMs) = try timed {
            try withLock(project, exclusive: true) {
                try persist(Record(phase: "current", generation: 1), root: project)
            }
        }
        XCTAssertThrowsError(try query("Alpha", revision: beta.revision))
        XCTAssertEqual(try childQuery(project, index: index.url, term: "Alpha")["reason"] as? String, "generationMismatch")
        try withLock(project, exclusive: true) {
            try index.rebuild(from: second.load(), canonicalRevision: calculator.current(at: project))
        }
        XCTAssertEqual(try query("Beta", revision: beta.revision).count, 1)
        // This fresh OS process reads only persisted generation and SQLite metadata.
        let restarted = try childQuery(project, index: index.url, term: "Beta")
        XCTAssertEqual(restarted["status"] as? String, "current")
        XCTAssertEqual(restarted["names"] as? [String], ["Beta"])

        var warmMs: [Double] = []
        for _ in 0..<30 {
            let (hits, ms) = try timed { try query("Beta", revision: beta.revision) }
            XCTAssertEqual(hits.count, 1)
            warmMs.append(ms)
        }

        // A Git operation can participate in the same prototype writer protocol.
        try git(project, ["add", "-A"])
        try git(project, ["-c", "user.name=Spike", "-c", "user.email=spike@example.invalid", "commit", "-qm", "beta"])
        try git(project, ["checkout", "-qb", "other"])
        var gamma = beta
        gamma.revision += 1
        gamma.components[0].name = "Gamma"
        try withLock(project, exclusive: true) {
            try persist(Record(phase: "pending", generation: 1), root: project)
            try second.save(gamma, expected: beta)
            try persist(Record(phase: "current", generation: 2), root: project)
        }
        try git(project, ["add", "-A"])
        try git(project, ["-c", "user.name=Spike", "-c", "user.email=spike@example.invalid", "commit", "-qm", "gamma"])
        try withLock(project, exclusive: true) {
            try persist(Record(phase: "pending", generation: 2), root: project)
            try git(project, ["checkout", "-q", "main"])
            try persist(Record(phase: "current", generation: 3), root: project)
        }
        XCTAssertThrowsError(try query("Beta", revision: beta.revision))
        XCTAssertEqual(try childQuery(project, index: index.url, term: "Beta")["reason"] as? String, "generationMismatch")
        try withLock(project, exclusive: true) {
            try index.rebuild(from: first.load(), canonicalRevision: calculator.current(at: project))
        }
        XCTAssertEqual(try query("Beta", revision: beta.revision).count, 1)

        // Negative control: an uncoordinated writer bypasses the generation file.
        let componentURL = project.appendingPathComponent("components/component_probe.json")
        let oldText = try XCTUnwrap(String(data: Data(contentsOf: componentURL), encoding: .utf8))
        try XCTUnwrap(oldText.replacingOccurrences(of: "Beta", with: "Delta").data(using: .utf8)).write(to: componentURL)
        let uncoordinatedFalseCurrent = try query("Beta", revision: beta.revision).count == 1
        XCTAssertTrue(uncoordinatedFalseCurrent)

        let result: [String: Any] = [
            "environment": "macOS arm64, Swift 6.4 debug XCTest; disposable Git worktree; actual CanonicalRepository and LocalIndex; 30 warm queries",
            "twoRepositoryInstancesObservedSharedGeneration": true,
            "pendingBeforeSaveRejected": true,
            "pendingAfterCanonicalSaveRejectedAcrossFreshProcess": pendingAfterSave == "pending",
            "generationAdvancedBeforeIndexPublishRejected": true,
            "futureIndexGenerationRejected": true,
            "freshProcessReadMatchingGeneration": restarted["status"] as? String == "current",
            "coordinatedBranchSwitchInvalidatedIndex": true,
            "uncoordinatedExternalEditFalselyReturnedCurrent": uncoordinatedFalseCurrent,
            "warmQueryP50Ms": percentile(warmMs, 0.5),
            "warmQueryP95Ms": percentile(warmMs, 0.95),
            "pendingPersistMs": pendingWriteMs,
            "finalizePersistMs": finalizeWriteMs,
            "restartChildQueryMs": restarted["elapsedMs"] as? Double ?? -1,
            "limits": "Prototype lock is separate from production .hamii/write.lock and only explicit participants honor it. Crash is a stopped protocol step, not SIGKILL or power-loss injection. Recovery from pending, concurrent processes/writer throughput, filesystem watcher gaps, and atomic source snapshot acquisition remain unresolved. External edits bypassing protocol return false current."
        ]
        let bytes = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try bytes.write(to: URL(fileURLWithPath: resultPath))
    }
}
