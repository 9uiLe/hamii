import Darwin
import Foundation
import SQLite3
import XCTest
import HamiiCore
@testable import HamiiFormat
@testable import HamiiIndex

/// Test-only candidate Query. Production LocalIndex still uses the Git oracle.
final class FastQueryReadBoundarySpikeTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let indexRoot: URL
        let documentID: EntityID
        let scopeID: EntityID
    }

    private struct Witness {
        let generation: CanonicalGeneration
        let identity: CanonicalSnapshotIdentity
        let indexID: IndexGenerationID
    }

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hamii-fast-read-\(UUID().uuidString)")
        let root = directory.appendingPathComponent("Project")
        let repository = CanonicalRepository(root: root)
        let created = try repository.create(name: "Fast read")
        let scope = try XCTUnwrap(created.scopes.first?.id)
        var next = created
        next.components = [ComponentDefinition(id: EntityID("component_alpha"), name: "Alpha", ownerScopeID: scope,
            root: Layer(id: EntityID("layer_alpha"), kind: .stack, name: "Root"))]
        next.revision += 1
        try repository.save(next, expected: created)
        try Data(".hamii/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try git(root, ["init", "-q"])
        try git(root, ["add", "-A"])
        try git(root, ["-c", "user.name=Spike", "-c", "user.email=spike@example.invalid", "commit", "-qm", "initial"])
        let fixture = Fixture(root: root, indexRoot: directory.appendingPathComponent("Indexes"),
                              documentID: next.id, scopeID: scope)
        try rebuild(fixture)
        return fixture
    }

    private func git(_ root: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw IndexError.sqlite(String(decoding: output, as: UTF8.self))
        }
    }

    private func index(_ fixture: Fixture) throws -> LocalIndex {
        try LocalIndex(projectRoot: fixture.root, documentID: fixture.documentID,
                       revisionCalculator: GitCanonicalRevisionCalculator(), storageRoot: fixture.indexRoot)
    }

    private func rebuild(_ fixture: Fixture, acquired: URL? = nil) throws {
        try CanonicalRepository(root: fixture.root).withCoordinatedSnapshot { snapshot in
            if let acquired { try Data().write(to: acquired) }
            let source = try CanonicalGenerationStore(root: fixture.root).requireMatchingStable(snapshot).generation
            let revision = try GitCanonicalRevisionCalculator().current(at: fixture.root)
            _ = try index(fixture).rebuild(from: snapshot, canonicalRevision: revision,
                                          sourceCanonicalGeneration: source)
        }
    }

    private func issueWitness(_ fixture: Fixture) throws -> Witness {
        try CanonicalRepository(root: fixture.root).withCoordinatedSnapshot { snapshot in
            let stable = try CanonicalGenerationStore(root: fixture.root).requireMatchingStable(snapshot)
            let published = try index(fixture).assertCurrent(documentID: snapshot.document.id,
                revision: snapshot.document.revision, expectedSourceIdentity: snapshot.identity)
            guard published.sourceCanonicalGeneration == stable.generation else { throw IndexError.stale }
            return Witness(generation: stable.generation, identity: snapshot.identity, indexID: published.id)
        }
    }

    private func oracleRows(_ fixture: Fixture) throws -> [ComponentHit] {
        try CanonicalRepository(root: fixture.root).withCoordinatedSnapshot { snapshot in
            try index(fixture).components(matching: "Alpha", consumerScopeID: fixture.scopeID,
                documentID: snapshot.document.id, revision: snapshot.document.revision,
                expectedSourceIdentity: snapshot.identity)
        }
    }

    private func candidateRows(_ fixture: Fixture, witness: Witness,
                               afterVerdict: (() throws -> Void)? = nil) throws -> [ComponentHit] {
        try WorktreeCoordinator(root: fixture.root).withExclusive {
            let coordinator = WorktreeCoordinator(root: fixture.root)
            try coordinator.requireReady()
            let stable = try CanonicalGenerationStore(root: fixture.root).readStable()
            guard stable.generation == witness.generation,
                  stable.snapshotIdentity == witness.identity else { throw IndexError.stale }
            let published = try index(fixture).shadowPublishedGeneration()
            guard published.id == witness.indexID,
                  published.sourceCanonicalIdentity == witness.identity,
                  published.sourceCanonicalGeneration == witness.generation,
                  published.documentID == fixture.documentID else { throw IndexError.stale }
            try afterVerdict?()
            // The same worktree lock still protects this actual SQLite row
            // read. Releasing it after the verdict would create the TOCTOU.
            return try readHits(at: index(fixture).url, scopeID: fixture.scopeID)
        }
    }

    private func readHits(at url: URL, scopeID: EntityID) throws -> [ComponentHit] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw IndexError.stale
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "BEGIN DEFERRED TRANSACTION", nil, nil, nil) == SQLITE_OK else {
            throw IndexError.stale
        }
        defer { _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        let sql = "SELECT c.id, c.name, c.owner_scope_id, c.usage_count FROM components c JOIN component_availability a ON a.component_id = c.id WHERE a.consumer_id = ? AND c.name LIKE ? ORDER BY c.name"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw IndexError.stale }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = sqlite3_bind_text(statement, 1, scopeID.rawValue, -1, transient)
        _ = sqlite3_bind_text(statement, 2, "%Alpha%", -1, transient)
        var result: [ComponentHit] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0), let name = sqlite3_column_text(statement, 1),
                  let scope = sqlite3_column_text(statement, 2) else { throw IndexError.stale }
            result.append(ComponentHit(id: EntityID(String(cString: id)), name: String(cString: name),
                                       ownerScopeID: EntityID(String(cString: scope)),
                                       usageCount: Int(sqlite3_column_int(statement, 3))))
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw IndexError.stale }
        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw IndexError.stale }
        return result
    }

    private func child(_ method: String, environment: [String: String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        process.arguments = ["-XCTest", "HamiiTests.FastQueryReadBoundarySpikeTests/\(method)", Bundle(for: Self.self).bundleURL.path]
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
            XCTFail("Missing barrier \(url.lastPathComponent)")
            throw CocoaError(.fileReadUnknown)
        }
    }

    func testCoordinatedWriterWorker() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rootPath = env["HAMII_FAST_ROOT"], let attempt = env["HAMII_FAST_ATTEMPT"],
              let acquired = env["HAMII_FAST_ACQUIRED"], let completed = env["HAMII_FAST_COMPLETED"] else {
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
        guard let rootPath = env["HAMII_FAST_ROOT"], let indexPath = env["HAMII_FAST_INDEX_ROOT"],
              let documentID = env["HAMII_FAST_DOCUMENT_ID"], let scopeID = env["HAMII_FAST_SCOPE_ID"],
              let attempt = env["HAMII_FAST_ATTEMPT"], let acquired = env["HAMII_FAST_ACQUIRED"],
              let completed = env["HAMII_FAST_COMPLETED"] else { throw XCTSkip("Worker only") }
        let fixture = Fixture(root: URL(fileURLWithPath: rootPath), indexRoot: URL(fileURLWithPath: indexPath),
                              documentID: EntityID(documentID), scopeID: EntityID(scopeID))
        try Data().write(to: URL(fileURLWithPath: attempt))
        try rebuild(fixture, acquired: URL(fileURLWithPath: acquired))
        try Data().write(to: URL(fileURLWithPath: completed))
    }

    private func race(_ kind: String) throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let witness = try issueWitness(fixture)
        XCTAssertEqual(try candidateRows(fixture, witness: witness), try oracleRows(fixture))
        let directory = fixture.root.deletingLastPathComponent()
        let attempt = directory.appendingPathComponent("\(kind).attempt")
        let acquired = directory.appendingPathComponent("\(kind).acquired")
        let completed = directory.appendingPathComponent("\(kind).completed")
        var worker: Process?
        let rows = try candidateRows(fixture, witness: witness) {
            var environment = ["HAMII_FAST_ROOT": fixture.root.path,
                               "HAMII_FAST_ATTEMPT": attempt.path, "HAMII_FAST_ACQUIRED": acquired.path,
                               "HAMII_FAST_COMPLETED": completed.path]
            if kind == "rebuild" {
                environment["HAMII_FAST_INDEX_ROOT"] = fixture.indexRoot.path
                environment["HAMII_FAST_DOCUMENT_ID"] = fixture.documentID.rawValue
                environment["HAMII_FAST_SCOPE_ID"] = fixture.scopeID.rawValue
            }
            worker = try self.child(kind == "save" ? "testCoordinatedWriterWorker" : "testIndexRebuildWorker",
                                    environment: environment)
            try self.awaitFile(attempt, process: worker!)
            Thread.sleep(forTimeInterval: 0.10)
            XCTAssertFalse(FileManager.default.fileExists(atPath: acquired.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: completed.path))
        }
        XCTAssertEqual(rows.map(\.name), ["Alpha"])
        let process = try XCTUnwrap(worker)
        try awaitFile(acquired, process: process)
        try awaitFile(completed, process: process)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertThrowsError(try candidateRows(fixture, witness: witness))
        if kind == "save" {
            XCTAssertThrowsError(try oracleRows(fixture))
            XCTAssertNotEqual(try CanonicalGenerationStore(root: fixture.root).readStable().generation,
                              witness.generation)
        } else {
            XCTAssertEqual(try CanonicalGenerationStore(root: fixture.root).readStable().generation,
                           witness.generation)
            XCTAssertEqual(try oracleRows(fixture).map(\.name), ["Alpha"])
            let renewed = try issueWitness(fixture)
            XCTAssertNotEqual(renewed.indexID, witness.indexID)
            XCTAssertEqual(try candidateRows(fixture, witness: renewed), try oracleRows(fixture))
        }
    }

    func testSaveCannotCrossFastVerdictAndRowRead() throws { try race("save") }
    func testIndexRebuildCannotCrossFastVerdictAndRowRead() throws { try race("rebuild") }

    func testCandidateRejectsMissingCorruptAndMismatchedMetadataBeforeRows() throws {
        for (name, sql) in [
            ("missing ID", "DELETE FROM metadata WHERE key='indexGenerationID'"),
            ("corrupt ID", "UPDATE metadata SET value='bad' WHERE key='indexGenerationID'"),
            ("source identity", "UPDATE metadata SET value='0000000000000000000000000000000000000000000000000000000000000000' WHERE key='sourceCanonicalIdentity'"),
            ("source generation", "UPDATE metadata SET value='' WHERE key='sourceCanonicalGeneration'")
        ] {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
            let witness = try issueWitness(fixture)
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(try index(fixture).url.path, &db), SQLITE_OK, name)
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, name)
            sqlite3_close(db)
            XCTAssertThrowsError(try candidateRows(fixture, witness: witness), name)
        }
        for variant in ["missing", "corrupt", "pending"] {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
            let witness = try issueWitness(fixture)
            let store = CanonicalGenerationStore(root: fixture.root)
            let url = fixture.root.appendingPathComponent(".hamii/canonical-generation.json")
            switch variant {
            case "missing": try FileManager.default.removeItem(at: url)
            case "corrupt": try Data("corrupt".utf8).write(to: url)
            default:
                try WorktreeCoordinator(root: fixture.root).withExclusive {
                    _ = try store.beginPending(old: try store.readStable(), expectedNewIdentity: nil)
                }
            }
            XCTAssertThrowsError(try candidateRows(fixture, witness: witness), variant)
        }

        let generationFixture = try fixture()
        defer { try? FileManager.default.removeItem(at: generationFixture.root.deletingLastPathComponent()) }
        let generationWitness = try issueWitness(generationFixture)
        let current = try CanonicalGenerationStore(root: generationFixture.root).readStable().generation
        for (name, value) in [
            ("old source generation", CanonicalGeneration(lineage: current.lineage, value: current.value - 1)),
            ("future source generation", CanonicalGeneration(lineage: current.lineage, value: current.value + 1))
        ] {
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(try index(generationFixture).url.path, &db), SQLITE_OK, name)
            let sql = "UPDATE metadata SET value='\(value.serialized)' WHERE key='sourceCanonicalGeneration'"
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, name)
            sqlite3_close(db)
            XCTAssertThrowsError(try candidateRows(generationFixture, witness: generationWitness), name)
        }

        let missingIndex = try fixture()
        defer { try? FileManager.default.removeItem(at: missingIndex.root.deletingLastPathComponent()) }
        let missingIndexWitness = try issueWitness(missingIndex)
        try FileManager.default.removeItem(at: try index(missingIndex).url)
        XCTAssertThrowsError(try candidateRows(missingIndex, witness: missingIndexWitness), "missing index")
    }
}
