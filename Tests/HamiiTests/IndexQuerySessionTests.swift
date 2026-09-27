import Darwin
import Foundation
import SQLite3
import XCTest
import HamiiCore
@testable import HamiiFormat
@testable import HamiiIndex

final class IndexQuerySessionTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let indexRoot: URL
        let documentID: EntityID
        let scopeID: EntityID
        var directory: URL { root.deletingLastPathComponent() }
    }

    private struct ContentionSamples: Codable {
        let queryMilliseconds: [Double]
        let lockWaitMilliseconds: [Double]
    }

    private func fixture(componentCount: Int = 1) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hamii-query-session-\(UUID().uuidString)")
        let root = directory.appendingPathComponent("Project")
        let repository = CanonicalRepository(root: root)
        let created = try repository.create(name: "Query session")
        let scope = try XCTUnwrap(created.scopes.first?.id)
        var next = created
        next.components = (0..<componentCount).map { number in
            let suffix = number == 0 ? "alpha" : String(number)
            return ComponentDefinition(id: EntityID("component_\(suffix)"),
                name: number == 0 ? "Alpha" : "Component \(number)", ownerScopeID: scope,
                root: Layer(id: EntityID("layer_\(suffix)"), kind: .stack, name: "Root"))
        }
        next.revision += 1
        try repository.save(next, expected: created)
        try Data(".hamii/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try git(root, ["init", "-q"])
        try git(root, ["add", "-A"])
        try git(root, ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "initial"])
        let fixture = Fixture(root: root, indexRoot: directory.appendingPathComponent("Indexes"),
                              documentID: next.id, scopeID: scope)
        _ = try rebuild(fixture)
        return fixture
    }

    private func git(_ root: URL, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + args
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw IndexError.sqlite(String(decoding: result, as: UTF8.self))
        }
    }

    private func index(_ fixture: Fixture, storageRoot: URL? = nil) throws -> LocalIndex {
        try LocalIndex(projectRoot: fixture.root, documentID: fixture.documentID,
                       revisionCalculator: GitCanonicalRevisionCalculator(),
                       storageRoot: storageRoot ?? fixture.indexRoot)
    }

    private func session(_ fixture: Fixture, afterFastVerdict: (() -> Void)? = nil) -> IndexQuerySession {
        IndexQuerySession(projectRoot: fixture.root, revisionCalculator: GitCanonicalRevisionCalculator(),
                          storageRoot: fixture.indexRoot, afterFastVerdict: afterFastVerdict)
    }

    @discardableResult
    private func rebuild(_ fixture: Fixture,
                         overrideBinding: IndexSourceGenerationBinding? = nil) throws -> IndexGenerationDescriptor {
        try CanonicalRepository(root: fixture.root).withCoordinatedSnapshot { snapshot in
            let calculator = GitCanonicalRevisionCalculator()
            let revision = try calculator.current(at: fixture.root)
            let binding: IndexSourceGenerationBinding
            if let overrideBinding {
                binding = overrideBinding
            } else if let generation = try? CanonicalGenerationStore(root: fixture.root)
                .requireMatchingStable(snapshot).generation {
                binding = .bound(generation)
            } else {
                binding = .explicitlyUnbound
            }
            return try index(fixture).rebuild(from: snapshot, canonicalRevision: revision,
                                              sourceGenerationBinding: binding)
        }
    }

    private func oracle(_ fixture: Fixture, matching text: String) throws -> [ComponentHit] {
        try CanonicalRepository(root: fixture.root).withCoordinatedSnapshot { snapshot in
            try index(fixture).components(matching: text, consumerScopeID: fixture.scopeID,
                documentID: snapshot.document.id, revision: snapshot.document.revision,
                expectedSourceIdentity: snapshot.identity)
        }
    }

    private func query(_ session: IndexQuerySession, _ fixture: Fixture, matching text: String = "")
        throws -> (hits: [ComponentHit], path: QueryVerificationPath) {
        try session.componentsWithVerification(matching: text, consumerScopeID: fixture.scopeID)
    }

    private func changeComponent(_ fixture: Fixture, from old: String, to new: String) throws {
        let file = fixture.root.appendingPathComponent("components/component_alpha.json")
        let oldText = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(oldText.contains(old))
        try Data(oldText.replacingOccurrences(of: old, with: new).utf8).write(to: file)
    }

    private func saveComponent(_ fixture: Fixture, as name: String) throws {
        let repository = CanonicalRepository(root: fixture.root)
        let old = try repository.load()
        var next = old
        next.components[0].name = name
        next.revision += 1
        try repository.save(next, expected: old)
    }

    func testQueryOpenNeverCreatesOrReplacesPublishedIndex() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let published = LocalIndexLocation.url(projectRoot: fixture.root,
            documentID: fixture.documentID, storageRoot: fixture.indexRoot)
        try FileManager.default.removeItem(at: published)
        XCTAssertThrowsError(try query(session(fixture), fixture))
        XCTAssertFalse(FileManager.default.fileExists(atPath: published.path))

        _ = try rebuild(fixture)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(published.path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA user_version = 7", nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        let before = try Data(contentsOf: published)
        XCTAssertThrowsError(try query(session(fixture), fixture))
        XCTAssertEqual(try Data(contentsOf: published), before)
    }

    func testBoundColdWarmSaveAndRebuildPaths() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let querySession = session(fixture)
        let first = try query(querySession, fixture)
        XCTAssertEqual(first.path, .slowBound)
        XCTAssertEqual(first.hits, try oracle(fixture, matching: ""))
        XCTAssertEqual(try query(querySession, fixture).path, .fast)

        try saveComponent(fixture, as: "Beta")
        XCTAssertThrowsError(try query(querySession, fixture))
        _ = try rebuild(fixture)
        let renewed = try query(querySession, fixture)
        XCTAssertEqual(renewed.path, .slowBound)
        XCTAssertEqual(renewed.hits, try oracle(fixture, matching: ""))
        XCTAssertEqual(renewed.hits.map(\.name), ["Beta"])
        XCTAssertEqual(try query(querySession, fixture).path, .fast)

        let prior = try index(fixture).publishedGeneration()
        let next = try rebuild(fixture)
        XCTAssertNotEqual(prior.id, next.id)
        XCTAssertEqual(try query(querySession, fixture).path, .slowBound)
        XCTAssertEqual(try query(querySession, fixture).path, .fast)
    }

    func testExplicitlyUnboundIsSlowOnlyAndExternalEditInvalidatesIt() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try changeComponent(fixture, from: "Alpha", to: "Gamma")
        XCTAssertThrowsError(try query(session(fixture), fixture, matching: "Gamma"))
        let published = try rebuild(fixture)
        XCTAssertEqual(published.sourceGenerationBinding, .explicitlyUnbound)
        let querySession = session(fixture)
        let first = try query(querySession, fixture, matching: "Gamma")
        XCTAssertEqual(first.path, .slowUnbound)
        XCTAssertEqual(first.hits, try oracle(fixture, matching: "Gamma"))
        XCTAssertEqual(first.hits.map(\.name), ["Gamma"])
        XCTAssertEqual(try query(querySession, fixture, matching: "Gamma").path, .slowUnbound)
        try changeComponent(fixture, from: "Gamma", to: "Delta")
        XCTAssertThrowsError(try query(querySession, fixture, matching: "Gamma"))
    }

    func testCoordinatedMutationInvalidatesExplicitlyUnboundIndex() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try rebuild(fixture, overrideBinding: .explicitlyUnbound)
        let querySession = session(fixture)
        XCTAssertEqual(try query(querySession, fixture).path, .slowUnbound)
        try saveComponent(fixture, as: "Beta")
        XCTAssertThrowsError(try query(querySession, fixture))
        let rebound = try rebuild(fixture)
        guard case .bound = rebound.sourceGenerationBinding else { return XCTFail("Expected Bound Index") }
        XCTAssertEqual(try query(querySession, fixture).path, .slowBound)
        XCTAssertEqual(try query(querySession, fixture).path, .fast)
    }

    func testMissingAndCorruptBindingNeverReturnRows() throws {
        for sql in [
            "DELETE FROM metadata WHERE key='sourceGenerationBinding'",
            "UPDATE metadata SET value='' WHERE key='sourceGenerationBinding'",
            "UPDATE metadata SET value='unknown' WHERE key='sourceGenerationBinding'",
            "UPDATE metadata SET value='bound:broken' WHERE key='sourceGenerationBinding'"
        ] {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let querySession = session(fixture)
            XCTAssertEqual(try query(querySession, fixture).path, .slowBound)
            XCTAssertEqual(try query(querySession, fixture).path, .fast)
            var database: OpaquePointer?
            XCTAssertEqual(sqlite3_open(try index(fixture).url.path, &database), SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
            sqlite3_close(database)
            XCTAssertThrowsError(try query(querySession, fixture), sql)
            XCTAssertThrowsError(try query(session(fixture), fixture), sql)
        }
    }

    func testPendingMissingAndCorruptGenerationInvalidateWarmSession() throws {
        for variant in ["pending", "missing", "corrupt", "managedGitPending"] {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let querySession = session(fixture)
            XCTAssertEqual(try query(querySession, fixture).path, .slowBound)
            XCTAssertEqual(try query(querySession, fixture).path, .fast)
            let generation = fixture.root.appendingPathComponent(".hamii/canonical-generation.json")
            switch variant {
            case "pending":
                let store = CanonicalGenerationStore(root: fixture.root)
                try WorktreeCoordinator(root: fixture.root).withExclusive {
                    _ = try store.beginPending(old: try store.readStable(), expectedNewIdentity: nil)
                }
            case "missing":
                try FileManager.default.removeItem(at: generation)
            case "corrupt":
                try Data("corrupt".utf8).write(to: generation)
            default:
                try Data("pending".utf8).write(to: fixture.root.appendingPathComponent(".hamii/managed-git-transition.json"))
            }
            XCTAssertThrowsError(try query(querySession, fixture), variant)
        }
    }

    func testPublishedFileReplacementDoesNotReuseOldSQLiteHandle() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let querySession = session(fixture)
        XCTAssertEqual(try query(querySession, fixture).path, .slowBound)
        XCTAssertEqual(try query(querySession, fixture).path, .fast)
        let oldHandle = try index(fixture)
        let oldDescriptor = try oldHandle.publishedGeneration()
        let newDescriptor = try CanonicalRepository(root: fixture.root).withCoordinatedSnapshot { snapshot in
            let stable = try CanonicalGenerationStore(root: fixture.root).requireMatchingStable(snapshot)
            let replacementRoot = fixture.directory.appendingPathComponent("ReplacementIndexes")
            let replacement = try index(fixture, storageRoot: replacementRoot)
            let generation = try replacement.rebuild(from: snapshot,
                canonicalRevision: GitCanonicalRevisionCalculator().current(at: fixture.root),
                sourceGenerationBinding: .bound(stable.generation))
            XCTAssertEqual(rename(replacement.url.path, try index(fixture).url.path), 0)
            return generation
        }
        XCTAssertNotEqual(oldDescriptor.id, newDescriptor.id)
        if let retained = try? oldHandle.publishedGeneration() {
            XCTAssertEqual(retained.id, oldDescriptor.id,
                           "An open handle must never claim the replacement generation")
        }
        XCTAssertEqual(try index(fixture).publishedGeneration().id, newDescriptor.id)
        XCTAssertEqual(try query(querySession, fixture).path, .slowBound)
        XCTAssertEqual(try query(querySession, fixture).path, .fast)
    }

    func testWitnessesStayWithinTheirWorktrees() throws {
        let first = try fixture()
        let second = try fixture()
        defer {
            try? FileManager.default.removeItem(at: first.directory)
            try? FileManager.default.removeItem(at: second.directory)
        }
        let firstSession = session(first)
        let secondSession = session(second)
        XCTAssertEqual(try query(firstSession, first).path, .slowBound)
        XCTAssertEqual(try query(secondSession, second).path, .slowBound)
        XCTAssertEqual(try query(firstSession, first).path, .fast)
        XCTAssertEqual(try query(secondSession, second).path, .fast)
        XCTAssertEqual(try query(firstSession, first).path, .fast)
        try saveComponent(first, as: "Beta")
        XCTAssertThrowsError(try query(firstSession, first))
        XCTAssertEqual(try query(secondSession, second).path, .fast)
        XCTAssertEqual(try query(secondSession, second).hits, try oracle(second, matching: ""))
        _ = try rebuild(first)
        XCTAssertEqual(try query(firstSession, first).path, .slowBound)
        XCTAssertEqual(try query(secondSession, second).path, .fast)
        XCTAssertEqual(try query(firstSession, first).path, .fast)
    }

    func testLongLivedSessionIsDiscardedOnCloseAndColdAfterReopen() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var opened: IndexQuerySession? = session(fixture)
        XCTAssertEqual(try query(XCTUnwrap(opened), fixture).path, .slowBound)
        XCTAssertEqual(try query(XCTUnwrap(opened), fixture).path, .fast)
        try saveComponent(fixture, as: "Beta")
        XCTAssertThrowsError(try query(XCTUnwrap(opened), fixture))
        _ = try rebuild(fixture)
        XCTAssertEqual(try query(XCTUnwrap(opened), fixture).path, .slowBound)
        XCTAssertEqual(try query(XCTUnwrap(opened), fixture).path, .fast)
        weak let closed = opened
        opened = nil
        XCTAssertNil(closed, "Closing a project must not retain its witness")
        let reopened = session(fixture)
        XCTAssertEqual(try query(reopened, fixture).path, .slowBound)
        XCTAssertEqual(try query(reopened, fixture).path, .fast)
    }

    func testMeasuredProductionQuerySessionCost() throws {
        guard let output = ProcessInfo.processInfo.environment["HAMII_INDEX_QUERY_BENCHMARK_RESULT"] else {
            throw XCTSkip("Set HAMII_INDEX_QUERY_BENCHMARK_RESULT to measure")
        }
        func milliseconds(_ operation: () throws -> Void) throws -> Double {
            let start = ProcessInfo.processInfo.systemUptime
            try operation()
            return (ProcessInfo.processInfo.systemUptime - start) * 1_000
        }
        func distribution(_ values: [Double]) -> [String: Double] {
            let sorted = values.sorted()
            func quantile(_ p: Double) -> Double {
                let index = max(0, Int(ceil(Double(sorted.count) * p)) - 1)
                return (sorted[index] * 1_000).rounded() / 1_000
            }
            return ["p50": quantile(0.5), "p95": quantile(0.95)]
        }
        var report: [String: [String: [String: Double]]] = [:]
        for count in [1, 1_000, 5_000] {
            let fixture = try fixture(componentCount: count)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let querySession = session(fixture)
            var stages: [String: [String: Double]] = [:]
            stages["coldSessionSlowBound"] = distribution(try (0..<10).map { _ in
                try milliseconds { XCTAssertEqual(try query(session(fixture), fixture).path, .slowBound) }
            })
            XCTAssertEqual(try query(querySession, fixture).path, .slowBound)
            stages["warmFast"] = distribution(try (0..<40).map { _ in
                try milliseconds { XCTAssertEqual(try query(querySession, fixture).path, .fast) }
            })
            var rebuildTimes: [Double] = []
            var afterRebuild: [Double] = []
            for _ in 0..<5 {
                rebuildTimes.append(try milliseconds { _ = try rebuild(fixture) })
                afterRebuild.append(try milliseconds {
                    XCTAssertEqual(try query(querySession, fixture).path, .slowBound)
                })
            }
            stages["fullRebuild"] = distribution(rebuildTimes)
            stages["firstQueryAfterRebuild"] = distribution(afterRebuild)
            _ = try rebuild(fixture, overrideBinding: .explicitlyUnbound)
            stages["explicitlyUnboundSlow"] = distribution(try (0..<10).map { _ in
                try milliseconds { XCTAssertEqual(try query(querySession, fixture).path, .slowUnbound) }
            })
            report["\(count)-components"] = stages
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: output))
    }

    func testContentionReaderWorker() throws {
        let env = ProcessInfo.processInfo.environment
        guard let root = env["HAMII_CONTENTION_ROOT"], let indexRoot = env["HAMII_CONTENTION_INDEX_ROOT"],
              let documentID = env["HAMII_CONTENTION_DOCUMENT_ID"], let scopeID = env["HAMII_CONTENTION_SCOPE_ID"],
              let ready = env["HAMII_CONTENTION_READY"], let start = env["HAMII_CONTENTION_START"],
              let output = env["HAMII_CONTENTION_OUTPUT"], let countText = env["HAMII_CONTENTION_COUNT"],
              let count = Int(countText) else { throw XCTSkip("Contention worker only") }
        let fixture = Fixture(root: URL(fileURLWithPath: root), indexRoot: URL(fileURLWithPath: indexRoot),
                              documentID: EntityID(documentID), scopeID: EntityID(scopeID))
        var lockWait: [Double] = []
        let hold = Double(env["HAMII_CONTENTION_HOLD_MS"] ?? "0") ?? 0
        let reader = IndexQuerySession(projectRoot: fixture.root,
            revisionCalculator: GitCanonicalRevisionCalculator(), storageRoot: fixture.indexRoot,
            afterFastVerdict: hold > 0 ? { Thread.sleep(forTimeInterval: hold / 1_000) } : nil,
            onReadBoundaryAcquired: { lockWait.append($0) })
        XCTAssertEqual(try query(reader, fixture).path, .slowBound)
        lockWait.removeAll()
        try Data().write(to: URL(fileURLWithPath: ready))
        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: start) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: start))
        var elapsed: [Double] = []
        for _ in 0..<count {
            let began = ProcessInfo.processInfo.systemUptime
            XCTAssertEqual(try query(reader, fixture).path, .fast)
            elapsed.append((ProcessInfo.processInfo.systemUptime - began) * 1_000)
        }
        let samples = ContentionSamples(queryMilliseconds: elapsed, lockWaitMilliseconds: lockWait)
        try JSONEncoder().encode(samples).write(to: URL(fileURLWithPath: output))
    }

    func testMeasuredProductionReaderContention() throws {
        guard let output = ProcessInfo.processInfo.environment["HAMII_INDEX_CONTENTION_BENCHMARK_RESULT"] else {
            throw XCTSkip("Set HAMII_INDEX_CONTENTION_BENCHMARK_RESULT to measure")
        }
        let fixture = try fixture(componentCount: 1_000)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        func percentile(_ values: [Double]) -> [String: Double] {
            let sorted = values.sorted()
            func rounded(_ rank: Double) -> Double {
                let value = sorted[max(0, Int(ceil(Double(sorted.count) * rank)) - 1)]
                return (value * 1_000).rounded() / 1_000
            }
            return ["p50": rounded(0.5), "p95": rounded(0.95)]
        }
        var report: [String: [String: [String: Double]]] = [:]
        for readers in [1, 2, 4] {
            let start = fixture.directory.appendingPathComponent("readers-\(readers).start")
            var workers: [(Process, URL, URL)] = []
            for number in 0..<readers {
                let ready = fixture.directory.appendingPathComponent("readers-\(readers)-\(number).ready")
                let result = fixture.directory.appendingPathComponent("readers-\(readers)-\(number).json")
                let worker = try child("testContentionReaderWorker", environment: [
                    "HAMII_CONTENTION_ROOT": fixture.root.path,
                    "HAMII_CONTENTION_INDEX_ROOT": fixture.indexRoot.path,
                    "HAMII_CONTENTION_DOCUMENT_ID": fixture.documentID.rawValue,
                    "HAMII_CONTENTION_SCOPE_ID": fixture.scopeID.rawValue,
                    "HAMII_CONTENTION_READY": ready.path,
                    "HAMII_CONTENTION_START": start.path,
                    "HAMII_CONTENTION_OUTPUT": result.path,
                    "HAMII_CONTENTION_COUNT": "40"
                ])
                workers.append((worker, ready, result))
            }
            defer {
                for (worker, _, _) in workers where worker.isRunning {
                    kill(worker.processIdentifier, SIGKILL)
                    worker.waitUntilExit()
                }
            }
            for (worker, ready, _) in workers { try awaitFile(ready, process: worker) }
            try Data().write(to: start)
            var queries: [Double] = []
            var waits: [Double] = []
            for (worker, _, result) in workers {
                try awaitFile(result, process: worker)
                worker.waitUntilExit()
                XCTAssertEqual(worker.terminationStatus, 0)
                let sample = try JSONDecoder().decode(ContentionSamples.self, from: Data(contentsOf: result))
                XCTAssertEqual(sample.queryMilliseconds.count, 40)
                XCTAssertEqual(sample.lockWaitMilliseconds.count, 40)
                queries += sample.queryMilliseconds
                waits += sample.lockWaitMilliseconds
            }
            report["\(readers)-readers"] = ["queryMilliseconds": percentile(queries),
                                            "lockWaitMilliseconds": percentile(waits)]
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: output))
    }

    func testContentionWriterWorker() throws {
        let env = ProcessInfo.processInfo.environment
        guard let root = env["HAMII_CONTENTION_ROOT"], let attempt = env["HAMII_CONTENTION_ATTEMPT"],
              let acquired = env["HAMII_CONTENTION_ACQUIRED"], let release = env["HAMII_CONTENTION_RELEASE"],
              let output = env["HAMII_CONTENTION_OUTPUT"] else { throw XCTSkip("Contention writer only") }
        try Data().write(to: URL(fileURLWithPath: attempt))
        let began = ProcessInfo.processInfo.systemUptime
        try WorktreeCoordinator(root: URL(fileURLWithPath: root)).withExclusive {
            let wait = (ProcessInfo.processInfo.systemUptime - began) * 1_000
            try Data().write(to: URL(fileURLWithPath: acquired))
            let deadline = Date().addingTimeInterval(30)
            while !FileManager.default.fileExists(atPath: release) && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: release))
            try JSONEncoder().encode(["lockWaitMilliseconds": wait]).write(to: URL(fileURLWithPath: output))
        }
    }

    func testMeasuredWriterAndReaderWaiting() throws {
        guard let output = ProcessInfo.processInfo.environment["HAMII_INDEX_WRITER_CONTENTION_BENCHMARK_RESULT"] else {
            throw XCTSkip("Set HAMII_INDEX_WRITER_CONTENTION_BENCHMARK_RESULT to measure")
        }
        let fixture = try fixture(componentCount: 1_000)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        func workerEnvironment(attempt: URL, acquired: URL, release: URL, result: URL) -> [String: String] {
            ["HAMII_CONTENTION_ROOT": fixture.root.path,
             "HAMII_CONTENTION_ATTEMPT": attempt.path,
             "HAMII_CONTENTION_ACQUIRED": acquired.path,
             "HAMII_CONTENTION_RELEASE": release.path,
             "HAMII_CONTENTION_OUTPUT": result.path]
        }
        // A warm reader holds the same production boundary while a writer
        // requests it. The pause is a deterministic contention stimulus.
        let firstAttempt = fixture.directory.appendingPathComponent("writer-behind-reader.attempt")
        let firstAcquired = fixture.directory.appendingPathComponent("writer-behind-reader.acquired")
        let firstRelease = fixture.directory.appendingPathComponent("writer-behind-reader.release")
        let firstResult = fixture.directory.appendingPathComponent("writer-behind-reader.json")
        var waitingWriter: Process?
        let reader = session(fixture) {
            waitingWriter = try? self.child("testContentionWriterWorker", environment:
                workerEnvironment(attempt: firstAttempt, acquired: firstAcquired,
                                  release: firstRelease, result: firstResult))
            guard let waitingWriter else { return XCTFail("Writer did not start") }
            do { try self.awaitFile(firstAttempt, process: waitingWriter) }
            catch { return }
            Thread.sleep(forTimeInterval: 0.12)
            XCTAssertFalse(FileManager.default.fileExists(atPath: firstAcquired.path))
        }
        XCTAssertEqual(try query(reader, fixture).path, .slowBound)
        XCTAssertEqual(try query(reader, fixture).path, .fast)
        let firstWriter = try XCTUnwrap(waitingWriter)
        defer { if firstWriter.isRunning { kill(firstWriter.processIdentifier, SIGKILL); firstWriter.waitUntilExit() } }
        try awaitFile(firstAcquired, process: firstWriter)
        try Data().write(to: firstRelease)
        try awaitFile(firstResult, process: firstWriter)
        firstWriter.waitUntilExit()
        XCTAssertEqual(firstWriter.terminationStatus, 0)
        let writerBehindReader = try JSONDecoder().decode([String: Double].self, from: Data(contentsOf: firstResult))

        // The next reader is warm before the writer takes the lock. It must
        // finish only after the writer releases the same boundary.
        let readerReady = fixture.directory.appendingPathComponent("reader-behind-writer.ready")
        let readerStart = fixture.directory.appendingPathComponent("reader-behind-writer.start")
        let readerResult = fixture.directory.appendingPathComponent("reader-behind-writer.json")
        let blockedReader = try child("testContentionReaderWorker", environment: [
            "HAMII_CONTENTION_ROOT": fixture.root.path,
            "HAMII_CONTENTION_INDEX_ROOT": fixture.indexRoot.path,
            "HAMII_CONTENTION_DOCUMENT_ID": fixture.documentID.rawValue,
            "HAMII_CONTENTION_SCOPE_ID": fixture.scopeID.rawValue,
            "HAMII_CONTENTION_READY": readerReady.path,
            "HAMII_CONTENTION_START": readerStart.path,
            "HAMII_CONTENTION_OUTPUT": readerResult.path,
            "HAMII_CONTENTION_COUNT": "1"
        ])
        defer { if blockedReader.isRunning { kill(blockedReader.processIdentifier, SIGKILL); blockedReader.waitUntilExit() } }
        try awaitFile(readerReady, process: blockedReader)
        let secondAttempt = fixture.directory.appendingPathComponent("writer-ahead-of-reader.attempt")
        let secondAcquired = fixture.directory.appendingPathComponent("writer-ahead-of-reader.acquired")
        let secondRelease = fixture.directory.appendingPathComponent("writer-ahead-of-reader.release")
        let secondResult = fixture.directory.appendingPathComponent("writer-ahead-of-reader.json")
        let aheadWriter = try child("testContentionWriterWorker", environment:
            workerEnvironment(attempt: secondAttempt, acquired: secondAcquired,
                              release: secondRelease, result: secondResult))
        defer { if aheadWriter.isRunning { kill(aheadWriter.processIdentifier, SIGKILL); aheadWriter.waitUntilExit() } }
        try awaitFile(secondAcquired, process: aheadWriter)
        try Data().write(to: readerStart)
        Thread.sleep(forTimeInterval: 0.12)
        XCTAssertFalse(FileManager.default.fileExists(atPath: readerResult.path))
        try Data().write(to: secondRelease)
        try awaitFile(readerResult, process: blockedReader)
        blockedReader.waitUntilExit()
        XCTAssertEqual(blockedReader.terminationStatus, 0)
        try awaitFile(secondResult, process: aheadWriter)
        aheadWriter.waitUntilExit()
        XCTAssertEqual(aheadWriter.terminationStatus, 0)
        let readerBehindWriter = try JSONDecoder().decode(ContentionSamples.self, from: Data(contentsOf: readerResult))
        XCTAssertEqual(readerBehindWriter.queryMilliseconds.count, 1)
        XCTAssertEqual(readerBehindWriter.lockWaitMilliseconds.count, 1)

        let report: [String: Double] = [
            "writerWaitBehindHeldReaderMilliseconds": try XCTUnwrap(writerBehindReader["lockWaitMilliseconds"]),
            "readerWaitBehindHeldWriterMilliseconds": readerBehindWriter.lockWaitMilliseconds[0],
            "readerQueryBehindHeldWriterMilliseconds": readerBehindWriter.queryMilliseconds[0]
        ]
        try JSONEncoder().encode(report).write(to: URL(fileURLWithPath: output))
    }

    func testMeasuredWriterUnderRepeatedWarmReaders() throws {
        guard let output = ProcessInfo.processInfo.environment["HAMII_INDEX_REPEATED_READER_BENCHMARK_RESULT"] else {
            throw XCTSkip("Set HAMII_INDEX_REPEATED_READER_BENCHMARK_RESULT to measure")
        }
        let fixture = try fixture(componentCount: 1_000)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let start = fixture.directory.appendingPathComponent("repeated-readers.start")
        var readers: [(Process, URL, URL)] = []
        for number in 0..<4 {
            let ready = fixture.directory.appendingPathComponent("repeated-reader-\(number).ready")
            let result = fixture.directory.appendingPathComponent("repeated-reader-\(number).json")
            let worker = try child("testContentionReaderWorker", environment: [
                "HAMII_CONTENTION_ROOT": fixture.root.path,
                "HAMII_CONTENTION_INDEX_ROOT": fixture.indexRoot.path,
                "HAMII_CONTENTION_DOCUMENT_ID": fixture.documentID.rawValue,
                "HAMII_CONTENTION_SCOPE_ID": fixture.scopeID.rawValue,
                "HAMII_CONTENTION_READY": ready.path,
                "HAMII_CONTENTION_START": start.path,
                "HAMII_CONTENTION_OUTPUT": result.path,
                "HAMII_CONTENTION_COUNT": "200",
                "HAMII_CONTENTION_HOLD_MS": "5"
            ])
            readers.append((worker, ready, result))
        }
        defer {
            for (worker, _, _) in readers where worker.isRunning {
                kill(worker.processIdentifier, SIGKILL)
                worker.waitUntilExit()
            }
        }
        for (worker, ready, _) in readers { try awaitFile(ready, process: worker) }
        try Data().write(to: start)
        Thread.sleep(forTimeInterval: 0.02)
        var writerWaits: [Double] = []
        for number in 0..<10 {
            let attempt = fixture.directory.appendingPathComponent("repeated-writer-\(number).attempt")
            let acquired = fixture.directory.appendingPathComponent("repeated-writer-\(number).acquired")
            let release = fixture.directory.appendingPathComponent("repeated-writer-\(number).release")
            let result = fixture.directory.appendingPathComponent("repeated-writer-\(number).json")
            try Data().write(to: release)
            let worker = try child("testContentionWriterWorker", environment: [
                "HAMII_CONTENTION_ROOT": fixture.root.path,
                "HAMII_CONTENTION_ATTEMPT": attempt.path,
                "HAMII_CONTENTION_ACQUIRED": acquired.path,
                "HAMII_CONTENTION_RELEASE": release.path,
                "HAMII_CONTENTION_OUTPUT": result.path
            ])
            try awaitFile(result, process: worker)
            worker.waitUntilExit()
            XCTAssertEqual(worker.terminationStatus, 0)
            let sample = try JSONDecoder().decode([String: Double].self, from: Data(contentsOf: result))
            writerWaits.append(try XCTUnwrap(sample["lockWaitMilliseconds"]))
        }
        var queryTimes: [Double] = []
        var readerWaits: [Double] = []
        for (worker, _, result) in readers {
            try awaitFile(result, process: worker)
            worker.waitUntilExit()
            XCTAssertEqual(worker.terminationStatus, 0)
            let sample = try JSONDecoder().decode(ContentionSamples.self, from: Data(contentsOf: result))
            XCTAssertEqual(sample.queryMilliseconds.count, 200)
            queryTimes += sample.queryMilliseconds
            readerWaits += sample.lockWaitMilliseconds
        }
        func percentile(_ values: [Double], _ fraction: Double) -> Double {
            let sorted = values.sorted()
            return sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)]
        }
        let report: [String: [String: Double]] = [
            "readerQueryMilliseconds": ["p50": percentile(queryTimes, 0.5), "p95": percentile(queryTimes, 0.95)],
            "readerLockWaitMilliseconds": ["p50": percentile(readerWaits, 0.5), "p95": percentile(readerWaits, 0.95)],
            "writerLockWaitMilliseconds": ["p50": percentile(writerWaits, 0.5), "p95": percentile(writerWaits, 0.95)]
        ]
        try JSONEncoder().encode(report).write(to: URL(fileURLWithPath: output))
    }

    private func child(_ method: String, environment: [String: String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        process.arguments = ["-XCTest", "HamiiTests.IndexQuerySessionTests/\(method)", Bundle(for: Self.self).bundleURL.path]
        var childEnvironment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        for imageIndex in 0..<_dyld_image_count() {
            guard let imageName = _dyld_get_image_name(imageIndex) else { continue }
            let imagePath = String(cString: imageName)
            if imagePath.hasSuffix("/libTesting.dylib") {
                childEnvironment["DYLD_LIBRARY_PATH"] = URL(fileURLWithPath: imagePath).deletingLastPathComponent().path
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
        let deadline = Date().addingTimeInterval(15)
        while !FileManager.default.fileExists(atPath: url.path) && process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            XCTFail("Missing worker barrier \(url.lastPathComponent)")
            throw CocoaError(.fileReadUnknown)
        }
    }

    func testCoordinatedWriterWorker() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rootPath = env["HAMII_QUERY_ROOT"], let attempt = env["HAMII_QUERY_ATTEMPT"],
              let acquired = env["HAMII_QUERY_ACQUIRED"], let completed = env["HAMII_QUERY_COMPLETED"] else {
            throw XCTSkip("Worker only")
        }
        let root = URL(fileURLWithPath: rootPath)
        try Data().write(to: URL(fileURLWithPath: attempt))
        try WorktreeCoordinator(root: root).withExclusive { try Data().write(to: URL(fileURLWithPath: acquired)) }
        let repository = CanonicalRepository(root: root)
        let old = try repository.load()
        var next = old
        next.components[0].name = "Beta"
        next.revision += 1
        try repository.save(next, expected: old)
        try Data().write(to: URL(fileURLWithPath: completed))
    }

    func testIndexRebuildWorker() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rootPath = env["HAMII_QUERY_ROOT"], let indexPath = env["HAMII_QUERY_INDEX_ROOT"],
              let documentID = env["HAMII_QUERY_DOCUMENT_ID"], let scopeID = env["HAMII_QUERY_SCOPE_ID"],
              let attempt = env["HAMII_QUERY_ATTEMPT"], let acquired = env["HAMII_QUERY_ACQUIRED"],
              let completed = env["HAMII_QUERY_COMPLETED"] else { throw XCTSkip("Worker only") }
        let fixture = Fixture(root: URL(fileURLWithPath: rootPath), indexRoot: URL(fileURLWithPath: indexPath),
                              documentID: EntityID(documentID), scopeID: EntityID(scopeID))
        try Data().write(to: URL(fileURLWithPath: attempt))
        try CanonicalRepository(root: fixture.root).withCoordinatedSnapshot { snapshot in
            try Data().write(to: URL(fileURLWithPath: acquired))
            let generation = try CanonicalGenerationStore(root: fixture.root).requireMatchingStable(snapshot).generation
            _ = try index(fixture).rebuild(from: snapshot,
                canonicalRevision: GitCanonicalRevisionCalculator().current(at: fixture.root),
                sourceGenerationBinding: .bound(generation))
        }
        try Data().write(to: URL(fileURLWithPath: completed))
    }

    private func race(_ kind: String) throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let attempt = fixture.directory.appendingPathComponent("\(kind).attempt")
        let acquired = fixture.directory.appendingPathComponent("\(kind).acquired")
        let completed = fixture.directory.appendingPathComponent("\(kind).completed")
        var worker: Process?
        var stopOnce = true
        let querySession = session(fixture) {
            guard stopOnce else { return }
            stopOnce = false
            var environment = ["HAMII_QUERY_ROOT": fixture.root.path,
                               "HAMII_QUERY_ATTEMPT": attempt.path, "HAMII_QUERY_ACQUIRED": acquired.path,
                               "HAMII_QUERY_COMPLETED": completed.path]
            if kind == "rebuild" {
                environment["HAMII_QUERY_INDEX_ROOT"] = fixture.indexRoot.path
                environment["HAMII_QUERY_DOCUMENT_ID"] = fixture.documentID.rawValue
                environment["HAMII_QUERY_SCOPE_ID"] = fixture.scopeID.rawValue
            }
            worker = try? self.child(kind == "save" ? "testCoordinatedWriterWorker" : "testIndexRebuildWorker",
                                     environment: environment)
            guard let worker else { return XCTFail("Could not start worker") }
            do { try self.awaitFile(attempt, process: worker) }
            catch { return }
            Thread.sleep(forTimeInterval: 0.10)
            XCTAssertFalse(FileManager.default.fileExists(atPath: acquired.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: completed.path))
        }
        XCTAssertEqual(try query(querySession, fixture).path, .slowBound)
        let old = try query(querySession, fixture)
        XCTAssertEqual(old.path, .fast)
        XCTAssertEqual(old.hits.map(\.name), ["Alpha"])
        let process = try XCTUnwrap(worker)
        try awaitFile(acquired, process: process)
        try awaitFile(completed, process: process)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        if kind == "save" {
            XCTAssertThrowsError(try query(querySession, fixture))
        } else {
            XCTAssertEqual(try query(querySession, fixture).path, .slowBound)
            XCTAssertEqual(try query(querySession, fixture).path, .fast)
        }
    }

    func testProductionFastReadBlocksCoordinatedSave() throws { try race("save") }
    func testProductionFastReadBlocksIndexRebuild() throws { try race("rebuild") }
}
