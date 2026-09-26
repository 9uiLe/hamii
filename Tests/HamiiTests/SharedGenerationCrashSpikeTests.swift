import CryptoKit
import Darwin
import Foundation
import XCTest
import HamiiCore
@testable import HamiiFormat
import HamiiIndex

/// Real child processes and SIGKILL around a test-only coordinated generation protocol.
final class SharedGenerationCrashSpikeTests: XCTestCase {
    private struct Record: Codable { var phase: String; var generation: Int }
    private final class BootTrust: @unchecked Sendable { var verified = false }
    private struct Calculator: CanonicalRevisionCalculating {
        let trust: BootTrust?
        func current(at root: URL) throws -> CanonicalRevision {
            if let trust, !trust.verified { throw IndexError.stale }
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
        let descriptor = open(temporary.path, O_RDONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0, rename(temporary.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let parent = open(directory.path, O_RDONLY)
        guard parent >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private func snapshot(_ root: URL) throws -> String {
        var hash = SHA256()
        let folders = ["pages", "screens", "scopes", "components", "tokens", "assets", "interactions", "motions", "fixtures", "targets"]
        var names = ["hamii.json"]
        for folder in folders {
            let directory = root.appendingPathComponent(folder)
            if FileManager.default.fileExists(atPath: directory.path) {
                names += try FileManager.default.contentsOfDirectory(atPath: directory.path)
                    .filter { $0.hasSuffix(".json") }.map { "\(folder)/\($0)" }
            }
        }
        for name in names.sorted() {
            let bytes = try Data(contentsOf: root.appendingPathComponent(name))
            hash.update(data: Data(name.utf8))
            hash.update(data: Data([0]))
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { hash.update(data: $0) }
            hash.update(data: bytes)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func testBundle() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/out/Products/Debug/HamiiTests.xctest")
    }

    private func child(_ method: String, environment: [String: String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xctest", "-XCTest", "HamiiTests.SharedGenerationCrashSpikeTests/\(method)", testBundle().path]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardOutput = Pipe()
        process.standardError = process.standardOutput
        try process.run()
        return process
    }

    private func awaitFile(_ url: URL, process: Process) throws {
        let deadline = Date().addingTimeInterval(12)
        while !FileManager.default.fileExists(atPath: url.path) && process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Worker exited or timed out before marker")
    }

    private func fixture(_ root: URL, indexRoot: URL) throws -> (Document, LocalIndex) {
        let repository = CanonicalRepository(root: root)
        let created = try repository.create(name: "Crash boundary")
        var base = created
        base.revision = 1
        base.scopes = [ArchitectureScope(id: EntityID("scope_app"), name: "App", parentID: nil)]
        base.components = [ComponentDefinition(id: EntityID("component_probe"), name: "Alpha", ownerScopeID: EntityID("scope_app"),
                                               root: Layer(id: EntityID("layer_probe"), kind: .stack, name: "Root"))]
        try repository.save(base, expected: created)
        try persist(Record(phase: "current", generation: 0), root: root)
        let index = try LocalIndex(projectRoot: root, documentID: base.id, revisionCalculator: Calculator(trust: nil), storageRoot: indexRoot)
        try withLock(root, exclusive: true) {
            try index.rebuild(from: repository.load(), canonicalRevision: CanonicalRevision("gen-0"))
        }
        return (base, index)
    }

    func testWriterWorker() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rootPath = env["HAMII_CRASH_SPIKE_ROOT"], let stage = env["HAMII_CRASH_SPIKE_STAGE"],
              let markerPath = env["HAMII_CRASH_SPIKE_MARKER"], let indexPath = env["HAMII_CRASH_SPIKE_INDEX_ROOT"] else {
            throw XCTSkip("Child writer only")
        }
        let root = URL(fileURLWithPath: rootPath)
        let marker = URL(fileURLWithPath: markerPath)
        func pause() -> Never {
            try! Data(stage.utf8).write(to: marker)
            while true { Thread.sleep(forTimeInterval: 1) }
        }
        try withLock(root, exclusive: true) {
            try persist(Record(phase: "pending", generation: 0), root: root)
            if stage == "pending" { pause() }
            let repository = CanonicalRepository(root: root)
            let base = try repository.load()
            var updated = base
            updated.revision += 1
            updated.components[0].name = "Beta"
            if stage == "save" {
                let interrupted = CanonicalRepository(root: root) { step in
                    if case .applied("components/component_probe.json") = step { pause() }
                }
                try interrupted.save(updated, expected: base)
            } else {
                try repository.save(updated, expected: base)
            }
            try persist(Record(phase: "current", generation: 1), root: root)
            if stage == "generationFinalized" { pause() }
            let index = try LocalIndex(projectRoot: root, documentID: updated.id, revisionCalculator: Calculator(trust: nil),
                                       storageRoot: URL(fileURLWithPath: indexPath))
            try index.rebuild(from: updated, canonicalRevision: CanonicalRevision("gen-1"))
            if stage == "indexPublished" { pause() }
        }
    }

    func testRecoveryWorker() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rootPath = env["HAMII_CRASH_SPIKE_ROOT"], let resultPath = env["HAMII_CRASH_SPIKE_RESULT"],
              let indexPath = env["HAMII_CRASH_SPIKE_INDEX_ROOT"], let documentID = env["HAMII_CRASH_SPIKE_DOCUMENT_ID"] else {
            throw XCTSkip("Child recovery only")
        }
        let root = URL(fileURLWithPath: rootPath)
        let trust = BootTrust()
        let index = try LocalIndex(projectRoot: root, documentID: EntityID(documentID), revisionCalculator: Calculator(trust: trust),
                                   storageRoot: URL(fileURLWithPath: indexPath))
        let before = try JSONDecoder().decode(Record.self, from: Data(contentsOf: root.appendingPathComponent(".hamii/prototype-generation.json")))
        let expectedRevision = before.phase == "current" ? 2 : 1
        let bootRejected: Bool
        do {
            _ = try withLock(root, exclusive: false) {
                try index.components(matching: "", consumerScopeID: EntityID("scope_app"), documentID: EntityID(documentID), revision: expectedRevision)
            }
            bootRejected = false
        } catch { bootRejected = true }
        XCTAssertTrue(bootRejected)

        let recovered: (String, String, Int, Bool) = try withLock(root, exclusive: true) {
            let repository = CanonicalRepository(root: root)
            let document = try repository.load() // This runs Canonical journal recovery first.
            let source = try snapshot(root)
            let hadJournal = FileManager.default.fileExists(atPath: root.appendingPathComponent(".hamii/transaction.ready").path)
            let next = before.generation + 1
            try persist(Record(phase: "current", generation: next), root: root)
            try index.rebuild(from: document, canonicalRevision: CanonicalRevision("gen-\(next)"))
            let after = try snapshot(root)
            XCTAssertEqual(source, after)
            trust.verified = true
            return (document.components[0].name, source, document.revision, hadJournal)
        }
        let hits = try withLock(root, exclusive: false) {
            try index.components(matching: recovered.0, consumerScopeID: EntityID("scope_app"),
                                 documentID: EntityID(documentID), revision: recovered.2)
        }
        XCTAssertEqual(hits.map(\.name), [recovered.0])
        let report: [String: Any] = ["bootRejected": bootRejected, "recoveredName": recovered.0,
                                      "snapshotDigest": recovered.1, "revision": recovered.2,
                                      "journalRemainsAfterRecovery": recovered.3,
                                      "queryAfterRecovery": hits.map(\.name)]
        let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try bytes.write(to: URL(fileURLWithPath: resultPath))
    }

    func testRealProcessStopsAcrossGenerationPhases() throws {
        guard let resultPath = ProcessInfo.processInfo.environment["HAMII_CRASH_SPIKE_MATRIX_RESULT"] else {
            throw XCTSkip("Run with HAMII_CRASH_SPIKE_MATRIX_RESULT for the process-stop matrix")
        }
        var results: [[String: Any]] = []
        for stage in ["pending", "save", "generationFinalized", "indexPublished"] {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let root = temporary.appendingPathComponent("Project")
            let indexRoot = temporary.appendingPathComponent("Indexes")
            let (base, index) = try fixture(root, indexRoot: indexRoot)
            let marker = temporary.appendingPathComponent("writer.ready")
            let result = temporary.appendingPathComponent("recovery.json")
            let common = ["HAMII_CRASH_SPIKE_ROOT": root.path, "HAMII_CRASH_SPIKE_INDEX_ROOT": indexRoot.path,
                          "HAMII_CRASH_SPIKE_DOCUMENT_ID": base.id.rawValue]
            let writer = try child("testWriterWorker", environment: common.merging([
                "HAMII_CRASH_SPIKE_STAGE": stage, "HAMII_CRASH_SPIKE_MARKER": marker.path]) { _, new in new })
            try awaitFile(marker, process: writer)
            let reader = Process()
            let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            reader.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            reader.arguments = [sourceRoot.appendingPathComponent("adr/index-consistency/spikes/shared-worktree-generation/artifacts/restart_query_probe.py").path,
                                root.path, index.url.path, "Alpha", "--boot-gate"]
            let readerOutput = Pipe()
            reader.standardOutput = readerOutput
            reader.standardError = readerOutput
            try reader.run()
            Thread.sleep(forTimeInterval: 0.15)
            let blockedOnWriter = reader.isRunning
            XCTAssertTrue(blockedOnWriter)
            kill(writer.processIdentifier, SIGKILL)
            writer.waitUntilExit()
            let readerBytes = readerOutput.fileHandleForReading.readDataToEndOfFile()
            reader.waitUntilExit()
            XCTAssertEqual(reader.terminationStatus, 0, String(data: readerBytes, encoding: .utf8) ?? "")
            let bootReader = try JSONSerialization.jsonObject(with: readerBytes) as! [String: Any]
            XCTAssertEqual(bootReader["status"] as? String, "staleIndex")
            let journalPresentBeforeRecovery = FileManager.default.fileExists(atPath: root.appendingPathComponent(".hamii/transaction.ready").path)
            XCTAssertEqual(journalPresentBeforeRecovery, stage == "save")
            let ungated = Process()
            ungated.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            ungated.arguments = [sourceRoot.appendingPathComponent("adr/index-consistency/spikes/shared-worktree-generation/artifacts/restart_query_probe.py").path,
                                 root.path, index.url.path, "Alpha"]
            let ungatedOutput = Pipe()
            ungated.standardOutput = ungatedOutput
            ungated.standardError = ungatedOutput
            try ungated.run()
            let ungatedBytes = ungatedOutput.fileHandleForReading.readDataToEndOfFile()
            ungated.waitUntilExit()
            XCTAssertEqual(ungated.terminationStatus, 0)
            let rawReader = try JSONSerialization.jsonObject(with: ungatedBytes) as! [String: Any]
            let recovery = try child("testRecoveryWorker", environment: common.merging([
                "HAMII_CRASH_SPIKE_RESULT": result.path]) { _, new in new })
            recovery.waitUntilExit()
            XCTAssertEqual(recovery.terminationStatus, 0, stage)
            let report = try JSONSerialization.jsonObject(with: Data(contentsOf: result)) as! [String: Any]
            XCTAssertEqual(report["bootRejected"] as? Bool, true)
            XCTAssertEqual(report["journalRemainsAfterRecovery"] as? Bool, false)
            let expected = stage == "pending" || stage == "save" ? "Alpha" : "Beta"
            XCTAssertEqual(report["recoveredName"] as? String, expected)
            XCTAssertEqual(report["queryAfterRecovery"] as? [String], [expected])
            results.append(["stage": stage, "writerKilledBySignal9": writer.terminationStatus == 9,
                            "readerBlockedDuringWriterLock": blockedOnWriter,
                            "bootGatedReaderStatusAfterKill": bootReader["status"] ?? "missing",
                            "rawReaderStatusAfterKill": rawReader["status"] ?? "missing",
                            "journalPresentBeforeRecovery": journalPresentBeforeRecovery,
                            "bootRejected": report["bootRejected"] ?? false,
                            "journalCleared": report["journalRemainsAfterRecovery"] as? Bool == false,
                            "recoveredName": expected, "snapshotDigest": report["snapshotDigest"] ?? "missing"])
        }
        let bytes = try JSONSerialization.data(withJSONObject: ["cases": results], options: [.prettyPrinted, .sortedKeys])
        try bytes.write(to: URL(fileURLWithPath: resultPath))
    }
}
