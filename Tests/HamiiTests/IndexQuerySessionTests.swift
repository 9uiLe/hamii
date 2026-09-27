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
        try saveComponent(first, as: "Beta")
        XCTAssertThrowsError(try query(firstSession, first))
        XCTAssertEqual(try query(secondSession, second).path, .fast)
        XCTAssertEqual(try query(secondSession, second).hits, try oracle(second, matching: ""))
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
