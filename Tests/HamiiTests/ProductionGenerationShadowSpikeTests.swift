import CryptoKit
import Darwin
import Foundation
import SQLite3
import XCTest
import HamiiApplication
import HamiiCore
@testable import HamiiFormat
@testable import HamiiIndex

/// Candidate generation protocol layered over real production boundaries.
/// This file does not change the production Query freshness decision.
final class ProductionGenerationShadowSpikeTests: XCTestCase {
    private enum Verdict: String { case knownCurrent, stale, unknown }

    private struct Record: Codable {
        var phase: String
        var generation: Int
        var snapshotIdentity: String
        var proposedIdentity: String?
        var operationID: String?
    }

    private struct Witness {
        let generation: Int
        let snapshotIdentity: String
        let indexGenerationID: String
    }

    private struct ProductionWitness {
        let generation: CanonicalGeneration
        let snapshotIdentity: CanonicalSnapshotIdentity
        let indexGenerationID: IndexGenerationID
    }

    private struct Plan: Decodable {
        struct Entry: Decodable { let path: String; let newHash: String? }
        let entries: [Entry]
    }

    private struct CandidateRecord: Decodable { let candidateCanonicalIdentity: String }

    private struct Fixture {
        let root: URL
        let indexRoot: URL
        let documentID: EntityID
        let scopeID: EntityID
        let initialIdentity: String
    }

    private struct ShadowMergeIndex: MergeIndexPublishing {
        let sourceGeneration: (URL) throws -> Int
        let attach: (Int, URL) throws -> Void
        let delegate = PublishedMergeIndex()

        func validateCandidate(at root: URL, snapshot: CanonicalSnapshot) throws {
            try delegate.validateCandidate(at: root, snapshot: snapshot)
        }

        func rebuildPublished(at root: URL, snapshot: CanonicalSnapshot) throws -> IndexGenerationDescriptor {
            let generation = try delegate.rebuildPublished(at: root, snapshot: snapshot)
            let indexURL = LocalIndexLocation.url(projectRoot: root, documentID: snapshot.document.id)
            try attach(sourceGeneration(root), indexURL)
            return generation
        }

        func verifyPublished(at root: URL, snapshot: CanonicalSnapshot) throws -> IndexGenerationDescriptor {
            let generation = try delegate.verifyPublished(at: root, snapshot: snapshot)
            guard try sqliteMetadataValue(at: LocalIndexLocation.url(projectRoot: root, documentID: snapshot.document.id),
                                           key: "shadowSourceCanonicalGeneration") == String(sourceGeneration(root)) else {
                throw IndexError.stale
            }
            return generation
        }
    }

    private static func sqliteMetadataValue(at url: URL, key: String) throws -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw IndexError.stale }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM metadata WHERE key = ?", -1, &statement, nil) == SQLITE_OK else {
            throw IndexError.stale
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = sqlite3_bind_text(statement, 1, key, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: bytes)
    }

    private func generationURL(_ root: URL) -> URL {
        root.appendingPathComponent(".hamii/shadow-canonical-generation.json")
    }

    private func persist(_ record: Record, at root: URL) throws {
        let url = generationURL(root)
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
        for path in [url, url.deletingLastPathComponent()] {
            let fd = open(path.path, O_RDONLY)
            guard fd >= 0 else { throw CocoaError(.fileReadUnknown) }
            defer { close(fd) }
            guard fsync(fd) == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
    }

    private func record(_ root: URL) throws -> Record {
        try JSONDecoder().decode(Record.self, from: Data(contentsOf: generationURL(root)))
    }

    private func canonicalFiles(_ root: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        var names = ["hamii.json"]
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("hamii-agent-profiles.json").path) {
            names.append("hamii-agent-profiles.json")
        }
        for folder in ["pages", "screens", "scopes", "components", "tokens", "assets", "interactions", "motions", "fixtures", "targets"] {
            let directory = root.appendingPathComponent(folder)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            names += try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasSuffix(".json") }.map { "\(folder)/\($0)" }
        }
        for name in names { files[name] = try Data(contentsOf: root.appendingPathComponent(name)) }
        return files
    }

    private func identity(_ files: [String: Data]) -> String {
        var hash = SHA256()
        for (path, bytes) in files.sorted(by: { $0.key < $1.key }) {
            for value in [Data(path.utf8), bytes] {
                var length = UInt64(value.count).bigEndian
                withUnsafeBytes(of: &length) { hash.update(data: $0) }
                hash.update(data: value)
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func candidateIdentity(_ root: URL) throws -> String {
        let preparing = root.appendingPathComponent(".hamii/transaction.prepare")
        let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: preparing.appendingPathComponent("plan.json")))
        var files = try canonicalFiles(root)
        for entry in plan.entries {
            if entry.newHash != nil {
                files[entry.path] = try Data(contentsOf: preparing.appendingPathComponent("new/\(entry.path)"))
            } else {
                files.removeValue(forKey: entry.path)
            }
        }
        return identity(files)
    }

    private func sqliteMetadata(_ url: URL, _ key: String) throws -> String? {
        try Self.sqliteMetadataValue(at: url, key: key)
    }

    private func putShadowSource(_ generation: Int, into url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw IndexError.sqlite("shadow metadata open") }
        defer { sqlite3_close(db) }
        let sql = "INSERT OR REPLACE INTO metadata(key, value) VALUES ('shadowSourceCanonicalGeneration', '\(generation)')"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw IndexError.sqlite("shadow metadata write") }
    }

    private func index(_ fixture: Fixture) throws -> LocalIndex {
        try LocalIndex(projectRoot: fixture.root, documentID: fixture.documentID,
                       revisionCalculator: GitCanonicalRevisionCalculator(), storageRoot: fixture.indexRoot)
    }

    private func rebuild(_ fixture: Fixture, snapshot: CanonicalSnapshot, generation: Int) throws -> IndexGenerationDescriptor {
        let calculator = GitCanonicalRevisionCalculator()
        let source = try calculator.current(at: fixture.root)
        let local = try index(fixture)
        let productionSource = try? CanonicalGenerationStore(root: fixture.root).requireMatchingStable(snapshot).generation
        let descriptor = try local.rebuild(from: snapshot, canonicalRevision: source,
                                           sourceGenerationBinding: productionSource.map(IndexSourceGenerationBinding.bound) ?? .explicitlyUnbound)
        try putShadowSource(generation, into: local.url)
        return descriptor
    }

    private func fixture() throws -> Fixture {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("hamii-production-shadow-\(UUID().uuidString)")
        let root = temporary.appendingPathComponent("Project")
        let indexRoot = temporary.appendingPathComponent("Indexes")
        let repository = CanonicalRepository(root: root)
        let created = try repository.create(name: "Shadow")
        let scope = try XCTUnwrap(created.scopes.first?.id)
        var document = created
        document.components = [ComponentDefinition(id: EntityID("component_probe"), name: "Alpha", ownerScopeID: scope,
            root: Layer(id: EntityID("layer_probe"), kind: .stack, name: "Root"))]
        document.revision = 1
        try repository.save(document, expected: created)
        try Data(".hamii/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try git(root, "init", "-q")
        try git(root, "add", "-A")
        try git(root, "-c", "user.name=Spike", "-c", "user.email=spike@example.invalid", "commit", "-qm", "initial")
        let snapshot = try repository.withCoordinatedSnapshot { $0 }
        let fixture = Fixture(root: root, indexRoot: indexRoot, documentID: document.id,
                              scopeID: scope, initialIdentity: snapshot.identity.rawValue)
        let probeFiles = try canonicalFiles(root)
        XCTAssertEqual(snapshot.identity.rawValue, identity(probeFiles))
        try persist(Record(phase: "stable", generation: 1, snapshotIdentity: snapshot.identity.rawValue,
                           proposedIdentity: nil, operationID: nil), at: root)
        _ = try rebuild(fixture, snapshot: snapshot, generation: 1)
        return fixture
    }

    @discardableResult
    private func git(_ root: URL, _ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw IndexError.sqlite(String(decoding: output, as: UTF8.self)) }
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shadow(_ fixture: Fixture, witness: Witness?) -> Verdict {
        guard let witness else { return .unknown }
        return (try? WorktreeCoordinator(root: fixture.root).withExclusive { () throws -> Verdict in
            let shared = try record(fixture.root)
            guard shared.phase == "stable", shared.proposedIdentity == nil else { return .unknown }
            guard shared.generation >= witness.generation else { return .unknown }
            guard shared.generation == witness.generation else { return .stale }
            guard shared.snapshotIdentity == witness.snapshotIdentity else { return .unknown }
            let local = try index(fixture)
            guard try sqliteMetadata(local.url, "indexGenerationID") == witness.indexGenerationID,
                  try sqliteMetadata(local.url, "sourceCanonicalIdentity") == witness.snapshotIdentity else { return .unknown }
            guard let source = try sqliteMetadata(local.url, "shadowSourceCanonicalGeneration"),
                  let sourceGeneration = Int(source) else { return .unknown }
            if sourceGeneration < shared.generation { return .stale }
            if sourceGeneration > shared.generation { return .unknown }
            return .knownCurrent
        }) ?? .unknown
    }

    private func productionBoot(_ fixture: Fixture,
                                duringCoordinatedVerification: (() throws -> Void)? = nil) throws -> ProductionWitness {
        try CanonicalRepository(root: fixture.root).withCoordinatedSnapshot { snapshot in
            try duringCoordinatedVerification?()
            let stable = try CanonicalGenerationStore(root: fixture.root).requireMatchingStable(snapshot)
            let published = try index(fixture).assertCurrent(documentID: snapshot.document.id,
                revision: snapshot.document.revision, expectedSourceIdentity: snapshot.identity)
            guard published.sourceGenerationBinding == .bound(stable.generation) else { throw IndexError.stale }
            return ProductionWitness(generation: stable.generation, snapshotIdentity: snapshot.identity,
                                     indexGenerationID: published.id)
        }
    }

    private func productionShadow(_ fixture: Fixture, witness: ProductionWitness?) -> Verdict {
        guard let witness else { return .unknown }
        return (try? WorktreeCoordinator(root: fixture.root).withExclusive { () throws -> Verdict in
            let coordinator = WorktreeCoordinator(root: fixture.root)
            try coordinator.requireReady()
            let stable = try CanonicalGenerationStore(root: fixture.root).readStable()
            guard stable.generation.lineage == witness.generation.lineage else { return .unknown }
            guard stable.generation.value >= witness.generation.value else { return .unknown }
            guard stable.generation == witness.generation else { return .stale }
            guard stable.snapshotIdentity == witness.snapshotIdentity else { return .unknown }
            let published = try index(fixture).publishedGeneration()
            guard published.id == witness.indexGenerationID,
                  published.sourceCanonicalIdentity == witness.snapshotIdentity else { return .unknown }
            guard case .bound(let source) = published.sourceGenerationBinding,
                  source.lineage == stable.generation.lineage else { return .unknown }
            if source.value < stable.generation.value { return .stale }
            if source.value > stable.generation.value { return .unknown }
            return .knownCurrent
        }) ?? .unknown
    }

    private func oracle(_ fixture: Fixture, text: String = "Alpha") -> Verdict {
        do {
            return try CanonicalRepository(root: fixture.root).withCoordinatedSnapshot { snapshot in
                _ = try index(fixture).components(matching: text, consumerScopeID: fixture.scopeID,
                    documentID: snapshot.document.id, revision: snapshot.document.revision,
                    expectedSourceIdentity: snapshot.identity)
                return .knownCurrent
            }
        } catch is IndexError { return .stale }
        catch { return .unknown }
    }

    /// Bootstrap reads the real Canonical journal and published Index. The
    /// candidate witness never authorizes a production Query in this Spike.
    private func boot(_ fixture: Fixture, rebuildIfStale: Bool) throws -> Witness? {
        try WorktreeCoordinator(root: fixture.root).withExclusive {
            let coordinator = WorktreeCoordinator(root: fixture.root)
            try coordinator.requireReady()
            let repository = CanonicalRepository(root: fixture.root)
            let snapshot = try repository.snapshotDuringManagedGitTransition()
            let productionStore = CanonicalGenerationStore(root: fixture.root)
            do { _ = try productionStore.readStable() }
            catch CanonicalGenerationError.pending { _ = try productionStore.reconcile(snapshot) }
            var shared = try record(fixture.root)
            if shared.phase == "pending" {
                if snapshot.identity.rawValue == shared.snapshotIdentity {
                    shared.phase = "stable"
                    shared.proposedIdentity = nil
                    shared.operationID = nil
                } else if snapshot.identity.rawValue == shared.proposedIdentity {
                    shared.phase = "stable"
                    shared.generation += 1
                    shared.snapshotIdentity = snapshot.identity.rawValue
                    shared.proposedIdentity = nil
                    shared.operationID = nil
                } else {
                    return nil
                }
                try persist(shared, at: fixture.root)
            }
            guard shared.phase == "stable", shared.snapshotIdentity == snapshot.identity.rawValue else { return nil }
            let local = try index(fixture)
            var descriptor: IndexGenerationDescriptor
            do {
                descriptor = try local.assertCurrent(documentID: snapshot.document.id,
                    revision: snapshot.document.revision, expectedSourceIdentity: snapshot.identity)
                guard try sqliteMetadata(local.url, "shadowSourceCanonicalGeneration") == String(shared.generation) else {
                    throw IndexError.stale
                }
            } catch {
                guard rebuildIfStale else { return nil }
                descriptor = try rebuild(fixture, snapshot: snapshot, generation: shared.generation)
            }
            guard try sqliteMetadata(local.url, "indexGenerationID") == descriptor.id.rawValue,
                  try sqliteMetadata(local.url, "sourceCanonicalIdentity") == snapshot.identity.rawValue,
                  try sqliteMetadata(local.url, "shadowSourceCanonicalGeneration") == String(shared.generation) else { return nil }
            _ = try local.assertCurrent(documentID: snapshot.document.id,
                revision: snapshot.document.revision, expectedSourceIdentity: snapshot.identity)
            return Witness(generation: shared.generation, snapshotIdentity: snapshot.identity.rawValue,
                           indexGenerationID: descriptor.id.rawValue)
        }
    }

    private func saveBeta(_ fixture: Fixture, stage: String?, marker: URL?) throws {
        let root = fixture.root
        func pause() -> Never {
            try! Data((stage ?? "unknown").utf8).write(to: marker!)
            while true { Thread.sleep(forTimeInterval: 1) }
        }
        let repository = CanonicalRepository(root: root) { step in
            switch step {
            case .prepared:
                let prior = try self.record(root)
                guard prior.phase == "stable", prior.snapshotIdentity == self.identity(try self.canonicalFiles(root)) else {
                    throw IndexError.stale
                }
                let next = try self.candidateIdentity(root)
                try self.persist(Record(phase: "pending", generation: prior.generation,
                    snapshotIdentity: prior.snapshotIdentity, proposedIdentity: next,
                    operationID: UUID().uuidString), at: root)
                if stage == "afterPending" { pause() }
            case .applied(let path):
                if stage == "duringShardApply" && path == "components/component_probe.json" { pause() }
            case .complete:
                if stage == "afterCanonicalCommit" { pause() }
                var pending = try self.record(root)
                guard pending.phase == "pending", pending.proposedIdentity == self.identity(try self.canonicalFiles(root)) else {
                    throw IndexError.stale
                }
                pending.phase = "stable"
                pending.generation += 1
                pending.snapshotIdentity = pending.proposedIdentity!
                pending.proposedIdentity = nil
                pending.operationID = nil
                try self.persist(pending, at: root)
                if stage == "afterFinalize" { pause() }
            default: break
            }
        }
        let old = try repository.load()
        if stage == "beforePending" { pause() }
        var next = old
        next.components[0].name = "Beta"
        next.revision += 1
        try repository.save(next, expected: old)
    }

    private func child(_ method: String, environment: [String: String]) throws -> Process {
        let bundle = Bundle(for: Self.self).bundleURL
        let xctest = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        let process = Process()
        process.executableURL = xctest
        process.arguments = ["-XCTest", "HamiiTests.ProductionGenerationShadowSpikeTests/\(method)", bundle.path]
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
        let deadline = Date().addingTimeInterval(12)
        while !FileManager.default.fileExists(atPath: url.path) && process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            let wasRunning = process.isRunning
            if wasRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            let output = String(decoding: (process.standardOutput as! Pipe).fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTFail("Missing barrier \(url.lastPathComponent): \(output)")
            throw CocoaError(.fileReadUnknown)
        }
    }

    func testWriterWorker() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rootPath = env["HAMII_SHADOW_ROOT"], let indexRoot = env["HAMII_SHADOW_INDEX_ROOT"],
              let stage = env["HAMII_SHADOW_STAGE"], let marker = env["HAMII_SHADOW_MARKER"] else {
            throw XCTSkip("Worker only")
        }
        let fixture = Fixture(root: URL(fileURLWithPath: rootPath), indexRoot: URL(fileURLWithPath: indexRoot),
            documentID: EntityID("unused"), scopeID: EntityID("unused"), initialIdentity: "")
        try saveBeta(fixture, stage: stage == "normal" ? nil : stage, marker: URL(fileURLWithPath: marker))
    }

    func testReaderWorker() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rootPath = env["HAMII_SHADOW_ROOT"], let attempt = env["HAMII_SHADOW_ATTEMPT"],
              let acquired = env["HAMII_SHADOW_ACQUIRED"] else { throw XCTSkip("Worker only") }
        try Data().write(to: URL(fileURLWithPath: attempt))
        try WorktreeCoordinator(root: URL(fileURLWithPath: rootPath)).withExclusive {
            try Data().write(to: URL(fileURLWithPath: acquired))
        }
    }

    func testStartupRaceWriterWorker() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rootPath = env["HAMII_WITNESS_ROOT"], let attempt = env["HAMII_WITNESS_ATTEMPT"],
              let acquired = env["HAMII_WITNESS_ACQUIRED"], let completed = env["HAMII_WITNESS_COMPLETED"] else {
            throw XCTSkip("Worker only")
        }
        let root = URL(fileURLWithPath: rootPath)
        try Data().write(to: URL(fileURLWithPath: attempt))
        try WorktreeCoordinator(root: root).withExclusive {
            try Data().write(to: URL(fileURLWithPath: acquired))
        }
        let repository = CanonicalRepository(root: root)
        let old = try repository.load()
        var next = old
        next.components[0].name = "Beta"
        next.revision += 1
        try repository.save(next, expected: old)
        try Data().write(to: URL(fileURLWithPath: completed))
    }

    func testProductionStartupWitnessWorker() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rootPath = env["HAMII_WITNESS_ROOT"], let indexRoot = env["HAMII_WITNESS_INDEX_ROOT"],
              let documentID = env["HAMII_WITNESS_DOCUMENT_ID"], let scopeID = env["HAMII_WITNESS_SCOPE_ID"],
              let resultPath = env["HAMII_WITNESS_RESULT"] else { throw XCTSkip("Worker only") }
        let fixture = Fixture(root: URL(fileURLWithPath: rootPath), indexRoot: URL(fileURLWithPath: indexRoot),
                              documentID: EntityID(documentID), scopeID: EntityID(scopeID), initialIdentity: "")
        XCTAssertEqual(productionShadow(fixture, witness: nil), .unknown)
        let witness = try productionBoot(fixture)
        XCTAssertEqual(productionShadow(fixture, witness: witness), .knownCurrent)
        let result = ["generation": witness.generation.serialized,
                      "identity": witness.snapshotIdentity.rawValue,
                      "indexGenerationID": witness.indexGenerationID.rawValue]
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            .write(to: URL(fileURLWithPath: resultPath))
    }

    func testSwitchWorker() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rootPath = env["HAMII_SHADOW_ROOT"], let indexRoot = env["HAMII_SHADOW_INDEX_ROOT"],
              let proposed = env["HAMII_SHADOW_PROPOSED"], let stage = env["HAMII_SHADOW_STAGE"],
              let marker = env["HAMII_SHADOW_MARKER"] else { throw XCTSkip("Worker only") }
        let fixture = Fixture(root: URL(fileURLWithPath: rootPath), indexRoot: URL(fileURLWithPath: indexRoot),
            documentID: EntityID("unused"), scopeID: EntityID("unused"), initialIdentity: "")
        try managedSwitch(fixture, branch: "feature", proposedIdentity: proposed,
            stopAt: stage, marker: URL(fileURLWithPath: marker))
    }

    func testMergeWorker() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rootPath = env["HAMII_SHADOW_ROOT"], let stage = env["HAMII_SHADOW_STAGE"],
              let marker = env["HAMII_SHADOW_MARKER"] else { throw XCTSkip("Worker only") }
        try mergePublish(URL(fileURLWithPath: rootPath), stopAt: stage, marker: URL(fileURLWithPath: marker))
    }

    func testBootWorker() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rootPath = env["HAMII_SHADOW_ROOT"], let indexRoot = env["HAMII_SHADOW_INDEX_ROOT"],
              let documentID = env["HAMII_SHADOW_DOCUMENT_ID"], let scopeID = env["HAMII_SHADOW_SCOPE_ID"],
              let resultPath = env["HAMII_SHADOW_BOOT_RESULT"] else { throw XCTSkip("Worker only") }
        let fixture = Fixture(root: URL(fileURLWithPath: rootPath), indexRoot: URL(fileURLWithPath: indexRoot),
            documentID: EntityID(documentID), scopeID: EntityID(scopeID), initialIdentity: "")
        XCTAssertEqual(shadow(fixture, witness: nil), .unknown)
        let witness = try XCTUnwrap(boot(fixture, rebuildIfStale: true))
        let result: [String: Any] = ["generation": witness.generation,
                                     "identity": witness.snapshotIdentity,
                                     "shadow": shadow(fixture, witness: witness).rawValue,
                                     "oracle": oracle(fixture, text: "Beta").rawValue]
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            .write(to: URL(fileURLWithPath: resultPath))
    }

    func testLongLivedReaderWorker() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rootPath = env["HAMII_SHADOW_ROOT"], let indexRoot = env["HAMII_SHADOW_INDEX_ROOT"],
              let documentID = env["HAMII_SHADOW_DOCUMENT_ID"], let scopeID = env["HAMII_SHADOW_SCOPE_ID"],
              let ready = env["HAMII_SHADOW_READY"], let proceed = env["HAMII_SHADOW_PROCEED"],
              let resultPath = env["HAMII_SHADOW_READER_RESULT"] else { throw XCTSkip("Worker only") }
        let fixture = Fixture(root: URL(fileURLWithPath: rootPath), indexRoot: URL(fileURLWithPath: indexRoot),
            documentID: EntityID(documentID), scopeID: EntityID(scopeID), initialIdentity: "")
        let witness = try XCTUnwrap(boot(fixture, rebuildIfStale: false))
        let productionBefore = try CanonicalGenerationStore(root: fixture.root).readStable().generation
        try Data().write(to: URL(fileURLWithPath: ready))
        let deadline = Date().addingTimeInterval(15)
        while !FileManager.default.fileExists(atPath: proceed) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: proceed))
        let result = ["shadow": shadow(fixture, witness: witness).rawValue,
                      "oracle": oracle(fixture).rawValue,
                      "productionChanged": String(try CanonicalGenerationStore(root: fixture.root).readStable().generation != productionBefore)]
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            .write(to: URL(fileURLWithPath: resultPath))
    }

    func testNormalSaveSIGKILLAndBootstrapMatrix() throws {
        for stage in ["beforePending", "afterPending", "duringShardApply", "afterCanonicalCommit", "afterFinalize"] {
            let f = try fixture()
            defer { try? FileManager.default.removeItem(at: f.root.deletingLastPathComponent()) }
            let productionBefore = try CanonicalGenerationStore(root: f.root).readStable()
            let productionWitness = try productionBoot(f)
            let marker = f.root.deletingLastPathComponent().appendingPathComponent("writer.stop")
            let attempt = f.root.deletingLastPathComponent().appendingPathComponent("reader.attempt")
            let acquired = f.root.deletingLastPathComponent().appendingPathComponent("reader.acquired")
            let common = ["HAMII_SHADOW_ROOT": f.root.path, "HAMII_SHADOW_INDEX_ROOT": f.indexRoot.path]
            let writer = try child("testWriterWorker", environment: common.merging([
                "HAMII_SHADOW_STAGE": stage, "HAMII_SHADOW_MARKER": marker.path]) { _, new in new })
            try awaitFile(marker, process: writer)
            let reader = try child("testReaderWorker", environment: common.merging([
                "HAMII_SHADOW_ATTEMPT": attempt.path, "HAMII_SHADOW_ACQUIRED": acquired.path]) { _, new in new })
            try awaitFile(attempt, process: reader)
            Thread.sleep(forTimeInterval: 0.12)
            let lockHeld = stage != "beforePending"
            XCTAssertEqual(FileManager.default.fileExists(atPath: acquired.path), !lockHeld, stage)
            kill(writer.processIdentifier, SIGKILL)
            writer.waitUntilExit()
            XCTAssertEqual(writer.terminationReason, .uncaughtSignal, stage)
            XCTAssertEqual(writer.terminationStatus, SIGKILL, stage)
            reader.waitUntilExit()
            XCTAssertEqual(reader.terminationStatus, 0, stage)
            XCTAssertTrue(FileManager.default.fileExists(atPath: acquired.path), stage)
            XCTAssertEqual(shadow(f, witness: nil), .unknown, stage)
            let firstBoot = try boot(f, rebuildIfStale: false)
            let expectedNew = stage == "afterCanonicalCommit" || stage == "afterFinalize"
            if expectedNew { XCTAssertNil(firstBoot, stage) }
            else { XCTAssertNotNil(firstBoot, stage) }
            let witness = try XCTUnwrap(boot(f, rebuildIfStale: true), stage)
            XCTAssertEqual(witness.generation, expectedNew ? 2 : 1, stage)
            XCTAssertEqual(shadow(f, witness: witness), .knownCurrent, stage)
            XCTAssertEqual(oracle(f, text: expectedNew ? "Beta" : "Alpha"), .knownCurrent, stage)
            let snapshot = try CanonicalRepository(root: f.root).withCoordinatedSnapshot { $0 }
            XCTAssertEqual(snapshot.document.components[0].name, expectedNew ? "Beta" : "Alpha", stage)
            XCTAssertEqual(witness.snapshotIdentity, snapshot.identity.rawValue, stage)
            let productionAfter = try CanonicalGenerationStore(root: f.root).readStable()
            XCTAssertEqual(productionAfter.generation.lineage, productionBefore.generation.lineage, stage)
            XCTAssertEqual(productionAfter.generation.value,
                           productionBefore.generation.value + (expectedNew ? 1 : 0), stage)
            XCTAssertEqual(productionAfter.snapshotIdentity, snapshot.identity, stage)
            XCTAssertEqual(productionShadow(f, witness: productionWitness), expectedNew ? .stale : .knownCurrent, stage)
            XCTAssertEqual(productionShadow(f, witness: try productionBoot(f)), .knownCurrent, stage)
        }
    }

    func testSecondProcessSaveAndShadowComparison() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root.deletingLastPathComponent()) }
        let productionBefore = try CanonicalGenerationStore(root: f.root).readStable()
        let productionWitness = try productionBoot(f)
        let first = try XCTUnwrap(boot(f, rebuildIfStale: false))
        XCTAssertEqual(shadow(f, witness: first), .knownCurrent)
        XCTAssertEqual(oracle(f), .knownCurrent)
        let writer = try child("testWriterWorker", environment: [
            "HAMII_SHADOW_ROOT": f.root.path, "HAMII_SHADOW_INDEX_ROOT": f.indexRoot.path,
            "HAMII_SHADOW_STAGE": "normal", "HAMII_SHADOW_MARKER": f.root.appendingPathComponent("unused").path])
        writer.waitUntilExit()
        XCTAssertEqual(writer.terminationStatus, 0)
        XCTAssertEqual(shadow(f, witness: first), .stale)
        XCTAssertEqual(oracle(f), .stale)
        let second = try XCTUnwrap(boot(f, rebuildIfStale: true))
        XCTAssertEqual(second.generation, first.generation + 1)
        XCTAssertNotEqual(second.snapshotIdentity, first.snapshotIdentity)
        XCTAssertNotEqual(second.indexGenerationID, first.indexGenerationID)
        XCTAssertEqual(shadow(f, witness: second), .knownCurrent)
        XCTAssertEqual(oracle(f, text: "Beta"), .knownCurrent)
        let productionAfter = try CanonicalGenerationStore(root: f.root).readStable()
        XCTAssertEqual(productionAfter.generation.value, productionBefore.generation.value + 1)
        XCTAssertEqual(productionAfter.generation.lineage, productionBefore.generation.lineage)
        XCTAssertEqual(productionShadow(f, witness: productionWitness), .stale)
        XCTAssertEqual(productionShadow(f, witness: try productionBoot(f)), .knownCurrent)
    }

    func testNewReaderProcessBootsUnknownThenRebuildsFromCommittedSave() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root.deletingLastPathComponent()) }
        let writer = try child("testWriterWorker", environment: [
            "HAMII_SHADOW_ROOT": f.root.path, "HAMII_SHADOW_INDEX_ROOT": f.indexRoot.path,
            "HAMII_SHADOW_STAGE": "normal", "HAMII_SHADOW_MARKER": f.root.appendingPathComponent("unused").path])
        writer.waitUntilExit()
        XCTAssertEqual(writer.terminationStatus, 0)
        let resultURL = f.root.deletingLastPathComponent().appendingPathComponent("boot-result.json")
        let reader = try child("testBootWorker", environment: [
            "HAMII_SHADOW_ROOT": f.root.path, "HAMII_SHADOW_INDEX_ROOT": f.indexRoot.path,
            "HAMII_SHADOW_DOCUMENT_ID": f.documentID.rawValue, "HAMII_SHADOW_SCOPE_ID": f.scopeID.rawValue,
            "HAMII_SHADOW_BOOT_RESULT": resultURL.path])
        reader.waitUntilExit()
        XCTAssertEqual(reader.terminationStatus, 0)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: resultURL)) as? [String: Any])
        XCTAssertEqual(result["generation"] as? Int, 2)
        XCTAssertEqual(result["shadow"] as? String, "knownCurrent")
        XCTAssertEqual(result["oracle"] as? String, "knownCurrent")
        XCTAssertEqual(result["identity"] as? String,
            try CanonicalRepository(root: f.root).withCoordinatedSnapshot { $0.identity.rawValue })
    }

    func testTwoLongLivedReaderProcessesObserveSecondProcessSave() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root.deletingLastPathComponent()) }
        let temporary = f.root.deletingLastPathComponent()
        let proceed = temporary.appendingPathComponent("proceed")
        let common = ["HAMII_SHADOW_ROOT": f.root.path, "HAMII_SHADOW_INDEX_ROOT": f.indexRoot.path,
                      "HAMII_SHADOW_DOCUMENT_ID": f.documentID.rawValue,
                      "HAMII_SHADOW_SCOPE_ID": f.scopeID.rawValue,
                      "HAMII_SHADOW_PROCEED": proceed.path]
        var readers: [(Process, URL)] = []
        for number in 0..<2 {
            let ready = temporary.appendingPathComponent("reader-\(number).ready")
            let result = temporary.appendingPathComponent("reader-\(number).json")
            let reader = try child("testLongLivedReaderWorker", environment: common.merging([
                "HAMII_SHADOW_READY": ready.path, "HAMII_SHADOW_READER_RESULT": result.path]) { _, new in new })
            try awaitFile(ready, process: reader)
            readers.append((reader, result))
        }
        let writer = try child("testWriterWorker", environment: [
            "HAMII_SHADOW_ROOT": f.root.path, "HAMII_SHADOW_INDEX_ROOT": f.indexRoot.path,
            "HAMII_SHADOW_STAGE": "normal", "HAMII_SHADOW_MARKER": temporary.appendingPathComponent("unused").path])
        writer.waitUntilExit()
        XCTAssertEqual(writer.terminationStatus, 0)
        try Data().write(to: proceed)
        for (reader, resultURL) in readers {
            reader.waitUntilExit()
            XCTAssertEqual(reader.terminationStatus, 0)
            let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: resultURL)) as? [String: String])
            XCTAssertEqual(result["shadow"], "stale")
            XCTAssertEqual(result["oracle"], "stale")
            XCTAssertEqual(result["productionChanged"], "true")
        }
    }

    func testRebuildMetadataAndExternalWriterNegativeControl() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root.deletingLastPathComponent()) }
        let first = try XCTUnwrap(boot(f, rebuildIfStale: false))
        let productionFirst = try productionBoot(f)
        let snapshot = try CanonicalRepository(root: f.root).withCoordinatedSnapshot { $0 }
        let rebuilt = try rebuild(f, snapshot: snapshot, generation: first.generation)
        XCTAssertNotEqual(rebuilt.id.rawValue, first.indexGenerationID)
        XCTAssertEqual(try record(f.root).generation, first.generation)
        XCTAssertEqual(shadow(f, witness: first), .unknown)
        XCTAssertEqual(productionShadow(f, witness: productionFirst), .unknown)
        let second = try XCTUnwrap(boot(f, rebuildIfStale: false))
        let productionSecond = try productionBoot(f)
        XCTAssertEqual(second.snapshotIdentity, first.snapshotIdentity)
        XCTAssertEqual(shadow(f, witness: second), .knownCurrent)
        XCTAssertEqual(productionShadow(f, witness: productionSecond), .knownCurrent)
        let file = f.root.appendingPathComponent("components/component_probe.json")
        let old = try String(contentsOf: file, encoding: .utf8)
        try old.replacingOccurrences(of: "Alpha", with: "External").write(to: file, atomically: true, encoding: .utf8)
        // Outside the coordinated writer contract, shared generation cannot
        // prove arbitrary working tree freshness. The production guard rejects.
        XCTAssertEqual(shadow(f, witness: second), .knownCurrent)
        XCTAssertEqual(productionShadow(f, witness: productionSecond), .knownCurrent)
        XCTAssertEqual(oracle(f), .stale)
    }

    func testProductionRecordAndIndexMetadataKeepShadowUnknownUntilVerified() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root.deletingLastPathComponent()) }
        let first = try productionBoot(f)
        XCTAssertEqual(productionShadow(f, witness: first), .knownCurrent)
        let recordURL = f.root.appendingPathComponent(".hamii/canonical-generation.json")
        let saved = try Data(contentsOf: recordURL)
        try FileManager.default.removeItem(at: recordURL)
        XCTAssertEqual(productionShadow(f, witness: first), .unknown)
        try Data("broken".utf8).write(to: recordURL)
        XCTAssertEqual(productionShadow(f, witness: first), .unknown)
        try saved.write(to: recordURL)

        let local = try index(f)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(local.url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "DELETE FROM metadata WHERE key='sourceGenerationBinding'", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(productionShadow(f, witness: first), .unknown)
        XCTAssertEqual(oracle(f), .stale)
        let snapshot = try CanonicalRepository(root: f.root).withCoordinatedSnapshot { $0 }
        _ = try rebuild(f, snapshot: snapshot, generation: try record(f.root).generation)
        let second = try productionBoot(f)
        XCTAssertEqual(productionShadow(f, witness: second), .knownCurrent)
        let generation = try CanonicalGenerationStore(root: f.root).readStable().generation
        let future = CanonicalGeneration(lineage: generation.lineage, value: generation.value + 1).serialized
        XCTAssertEqual(sqlite3_exec(db,
            "UPDATE metadata SET value='bound:\(future)' WHERE key='sourceGenerationBinding'", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(productionShadow(f, witness: second), .unknown)
        // The current production oracle still relies on Snapshot/Git identity,
        // and does not promote this shadow generation to a Query proof.
        XCTAssertEqual(oracle(f), .knownCurrent)
        _ = try rebuild(f, snapshot: snapshot, generation: try record(f.root).generation)
        let third = try productionBoot(f)
        let store = CanonicalGenerationStore(root: f.root)
        let old = try store.readStable()
        _ = try WorktreeCoordinator(root: f.root).withExclusive {
            try store.beginPending(old: old, expectedNewIdentity: nil)
        }
        XCTAssertEqual(productionShadow(f, witness: third), .unknown)
        _ = try WorktreeCoordinator(root: f.root).withExclusive { try store.reconcile(snapshot) }
        XCTAssertEqual(productionShadow(f, witness: third), .knownCurrent)
    }

    func testMissingAndCorruptSharedRecordOrIndexBindingNeverAuthorizeShadowQuery() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root.deletingLastPathComponent()) }
        let witness = try XCTUnwrap(boot(f, rebuildIfStale: false))
        XCTAssertEqual(shadow(f, witness: witness), .knownCurrent)
        let saved = try Data(contentsOf: generationURL(f.root))
        try FileManager.default.removeItem(at: generationURL(f.root))
        XCTAssertEqual(shadow(f, witness: witness), .unknown)
        XCTAssertThrowsError(try boot(f, rebuildIfStale: true))
        try Data("broken".utf8).write(to: generationURL(f.root))
        XCTAssertEqual(shadow(f, witness: witness), .unknown)
        XCTAssertThrowsError(try boot(f, rebuildIfStale: true))
        try saved.write(to: generationURL(f.root))

        let local = try index(f)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(local.url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "DELETE FROM metadata WHERE key='shadowSourceCanonicalGeneration'", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(shadow(f, witness: witness), .unknown)
        XCTAssertNil(try boot(f, rebuildIfStale: false))
        let restored = try XCTUnwrap(boot(f, rebuildIfStale: true))
        XCTAssertEqual(restored.generation, witness.generation)
        XCTAssertEqual(shadow(f, witness: restored), .knownCurrent)
        XCTAssertEqual(sqlite3_exec(db,
            "UPDATE metadata SET value='999' WHERE key='shadowSourceCanonicalGeneration'", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(shadow(f, witness: restored), .unknown)
        XCTAssertNil(try boot(f, rebuildIfStale: false))
        _ = try boot(f, rebuildIfStale: true)
        XCTAssertEqual(sqlite3_exec(db,
            "UPDATE metadata SET value='broken' WHERE key='indexGenerationID'", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(shadow(f, witness: restored), .unknown)
        XCTAssertEqual(oracle(f), .stale)
        XCTAssertNil(try boot(f, rebuildIfStale: false))
        _ = try boot(f, rebuildIfStale: true)
        sqlite3_close(db)
        db = nil
        try FileManager.default.removeItem(at: local.url)
        XCTAssertEqual(shadow(f, witness: restored), .unknown)
        XCTAssertNil(try boot(f, rebuildIfStale: false))
        XCTAssertEqual(shadow(f, witness: try boot(f, rebuildIfStale: true)), .knownCurrent)
    }

    func testPendingGenerationWithNeitherOldNorProposedSnapshotRemainsUnknown() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root.deletingLastPathComponent()) }
        let old = try XCTUnwrap(boot(f, rebuildIfStale: false))
        try persist(Record(phase: "pending", generation: old.generation,
            snapshotIdentity: old.snapshotIdentity, proposedIdentity: String(repeating: "b", count: 64),
            operationID: UUID().uuidString), at: f.root)
        let file = f.root.appendingPathComponent("components/component_probe.json")
        let original = try String(contentsOf: file, encoding: .utf8)
        try original.replacingOccurrences(of: "Alpha", with: "External")
            .write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(shadow(f, witness: old), .unknown)
        XCTAssertNil(try boot(f, rebuildIfStale: true))
        XCTAssertEqual(try record(f.root).phase, "pending")
        XCTAssertEqual(oracle(f), .stale)
    }

    private func branchFixture(_ f: Fixture) throws -> (source: String, featureIdentity: String) {
        let source = try git(f.root, "branch", "--show-current")
        try git(f.root, "switch", "-q", "-c", "feature")
        let component = f.root.appendingPathComponent("components/component_probe.json")
        let original = try String(contentsOf: component, encoding: .utf8)
        try original.replacingOccurrences(of: "Alpha", with: "Feature")
            .write(to: component, atomically: true, encoding: .utf8)
        try git(f.root, "add", "-A")
        try git(f.root, "-c", "user.name=Spike", "-c", "user.email=spike@example.invalid", "commit", "-qm", "feature")
        let featureIdentity = try CanonicalRepository(root: f.root).withCoordinatedSnapshot { $0.identity.rawValue }
        try git(f.root, "switch", "-q", source)
        XCTAssertEqual(try CanonicalRepository(root: f.root).withCoordinatedSnapshot { $0.identity.rawValue }, f.initialIdentity)
        return (source, featureIdentity)
    }

    private func managedSwitch(_ f: Fixture, branch: String, proposedIdentity: String,
                               stopAt: String? = nil, marker: URL? = nil) throws {
        let repository = CanonicalRepository(root: f.root)
        let expected = try repository.observe().statePrecondition
        func pause() -> Never {
            try! Data((stopAt ?? "unknown").utf8).write(to: marker!)
            while true { Thread.sleep(forTimeInterval: 1) }
        }
        let managed = ManagedGit(root: f.root) { step in
            switch step {
            case .pending:
                let prior = try self.record(f.root)
                XCTAssertEqual(prior.phase, "stable")
                try self.persist(Record(phase: "pending", generation: prior.generation,
                    snapshotIdentity: prior.snapshotIdentity, proposedIdentity: proposedIdentity,
                    operationID: UUID().uuidString), at: f.root)
                if stopAt == "switchPending" { pause() }
            case .switched:
                if stopAt == "switchApplied" { pause() }
            case .validated:
                var pending = try self.record(f.root)
                let actual = try repository.snapshotDuringManagedGitTransition().identity.rawValue
                XCTAssertEqual(actual, pending.proposedIdentity)
                pending.phase = "stable"
                pending.generation += 1
                pending.snapshotIdentity = actual
                pending.proposedIdentity = nil
                pending.operationID = nil
                try self.persist(pending, at: f.root)
                if stopAt == "switchValidated" { pause() }
            }
        }
        _ = try managed.switchBranch(branch, expectedState: expected)
    }

    func testManagedSwitchBackToSameCanonicalBytesAdvancesGeneration() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root.deletingLastPathComponent()) }
        let branch = try branchFixture(f)
        let first = try XCTUnwrap(boot(f, rebuildIfStale: false))
        let productionFirst = try CanonicalGenerationStore(root: f.root).readStable()
        let productionFirstWitness = try productionBoot(f)
        let revision = try CanonicalRepository(root: f.root).load().revision
        XCTAssertEqual(shadow(f, witness: first), .knownCurrent)
        try managedSwitch(f, branch: "feature", proposedIdentity: branch.featureIdentity)
        XCTAssertEqual(try CanonicalRepository(root: f.root).load().revision, revision)
        XCTAssertEqual(shadow(f, witness: first), .stale)
        XCTAssertEqual(oracle(f), .stale)
        let second = try XCTUnwrap(boot(f, rebuildIfStale: true))
        let productionSecond = try CanonicalGenerationStore(root: f.root).readStable()
        XCTAssertEqual(productionSecond.generation.value, productionFirst.generation.value + 1)
        XCTAssertEqual(productionShadow(f, witness: productionFirstWitness), .stale)
        let productionSecondWitness = try productionBoot(f)
        XCTAssertEqual(second.generation, first.generation + 1)
        XCTAssertEqual(second.snapshotIdentity, branch.featureIdentity)
        try managedSwitch(f, branch: branch.source, proposedIdentity: f.initialIdentity)
        XCTAssertEqual(shadow(f, witness: second), .stale)
        let third = try XCTUnwrap(boot(f, rebuildIfStale: true))
        let productionThird = try CanonicalGenerationStore(root: f.root).readStable()
        XCTAssertEqual(productionThird.generation.value, productionFirst.generation.value + 2)
        XCTAssertEqual(productionThird.snapshotIdentity, productionFirst.snapshotIdentity)
        XCTAssertEqual(productionShadow(f, witness: productionFirstWitness), .stale)
        XCTAssertEqual(productionShadow(f, witness: productionSecondWitness), .stale)
        XCTAssertEqual(productionShadow(f, witness: try productionBoot(f)), .knownCurrent)
        XCTAssertEqual(third.snapshotIdentity, first.snapshotIdentity)
        XCTAssertEqual(third.generation, first.generation + 2)
        XCTAssertEqual(shadow(f, witness: first), .stale)
        XCTAssertEqual(shadow(f, witness: third), .knownCurrent)
        XCTAssertEqual(oracle(f), .knownCurrent)
        // A no-op managed switch has no Canonical transition.
        try managedSwitch(f, branch: branch.source, proposedIdentity: f.initialIdentity)
        XCTAssertEqual(try record(f.root).generation, third.generation)
        XCTAssertEqual(try CanonicalGenerationStore(root: f.root).readStable(), productionThird)
    }

    func testRawGitSwitchBypassesSharedGenerationNegativeControl() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root.deletingLastPathComponent()) }
        _ = try branchFixture(f)
        let productionBefore = try CanonicalGenerationStore(root: f.root).readStable()
        let productionWitness = try productionBoot(f)
        let old = try XCTUnwrap(boot(f, rebuildIfStale: false))
        try git(f.root, "switch", "-q", "feature")
        XCTAssertEqual(try CanonicalGenerationStore(root: f.root).readStable(), productionBefore)
        XCTAssertEqual(try record(f.root).generation, old.generation)
        XCTAssertEqual(shadow(f, witness: old), .knownCurrent)
        XCTAssertEqual(productionShadow(f, witness: productionWitness), .knownCurrent)
        XCTAssertEqual(oracle(f), .stale)
    }

    func testNoOpSemanticMutationDoesNotAdvanceSharedGeneration() throws {
        let f = try starterFixture()
        defer { try? FileManager.default.removeItem(at: f.root.deletingLastPathComponent()) }
        let productionBefore = try CanonicalGenerationStore(root: f.root).readStable()
        let witness = try XCTUnwrap(boot(f, rebuildIfStale: false))
        let productionWitness = try productionBoot(f)
        let repository = CanonicalRepository(root: f.root)
        let service = ProjectService(repository: repository)
        let observed = try service.observe()
        let screen = try XCTUnwrap(observed.document.screens.first)
        let textLayer = try XCTUnwrap(screen.root.children.first(where: { $0.kind == .text }))
        let text = try XCTUnwrap(textLayer.text)
        let result = try service.mutate(.setText(screenID: screen.id, layerID: textLayer.id, text: text),
                                        expectedState: observed.statePrecondition, author: .human)
        XCTAssertTrue(result.patches.isEmpty)
        XCTAssertEqual(result.revision, observed.document.revision)
        XCTAssertEqual(try record(f.root).generation, witness.generation)
        XCTAssertEqual(try CanonicalGenerationStore(root: f.root).readStable(), productionBefore)
        XCTAssertEqual(try repository.withCoordinatedSnapshot { $0.identity.rawValue }, witness.snapshotIdentity)
        XCTAssertEqual(shadow(f, witness: witness), .knownCurrent)
        XCTAssertEqual(productionShadow(f, witness: productionWitness), .knownCurrent)
        XCTAssertEqual(oracle(f), .knownCurrent)
    }

    func testManagedSwitchSIGKILLRequiresRecoveryBeforeBootWitness() throws {
        for stage in ["switchPending", "switchApplied", "switchValidated"] {
            let f = try fixture()
            defer { try? FileManager.default.removeItem(at: f.root.deletingLastPathComponent()) }
            let productionBefore = try CanonicalGenerationStore(root: f.root).readStable()
            let productionWitness = try productionBoot(f)
            let branch = try branchFixture(f)
            let old = try XCTUnwrap(boot(f, rebuildIfStale: false))
            let marker = f.root.deletingLastPathComponent().appendingPathComponent("switch.stop")
            let worker = try child("testSwitchWorker", environment: [
                "HAMII_SHADOW_ROOT": f.root.path, "HAMII_SHADOW_INDEX_ROOT": f.indexRoot.path,
                "HAMII_SHADOW_PROPOSED": branch.featureIdentity,
                "HAMII_SHADOW_STAGE": stage, "HAMII_SHADOW_MARKER": marker.path])
            try awaitFile(marker, process: worker)
            kill(worker.processIdentifier, SIGKILL)
            worker.waitUntilExit()
            XCTAssertEqual(worker.terminationReason, .uncaughtSignal, stage)
            XCTAssertThrowsError(try CanonicalRepository(root: f.root).observe(), stage)
            XCTAssertEqual(shadow(f, witness: old), stage == "switchValidated" ? .stale : .unknown, stage)
            XCTAssertThrowsError(try boot(f, rebuildIfStale: true), stage)
            _ = try ManagedGit(root: f.root).recover()
            let expectedNew = stage != "switchPending"
            if expectedNew { XCTAssertNil(try boot(f, rebuildIfStale: false), stage) }
            let restored = try XCTUnwrap(boot(f, rebuildIfStale: true), stage)
            XCTAssertEqual(restored.generation, old.generation + (expectedNew ? 1 : 0), stage)
            XCTAssertEqual(restored.snapshotIdentity, expectedNew ? branch.featureIdentity : f.initialIdentity, stage)
            XCTAssertEqual(shadow(f, witness: restored), .knownCurrent, stage)
            XCTAssertEqual(oracle(f, text: expectedNew ? "Feature" : "Alpha"), .knownCurrent, stage)
            let productionAfter = try CanonicalGenerationStore(root: f.root).readStable()
            XCTAssertEqual(productionAfter.generation.value,
                           productionBefore.generation.value + (expectedNew ? 1 : 0), stage)
            XCTAssertEqual(productionAfter.snapshotIdentity.rawValue, restored.snapshotIdentity, stage)
            XCTAssertEqual(productionShadow(f, witness: productionWitness), expectedNew ? .stale : .knownCurrent, stage)
            XCTAssertEqual(productionShadow(f, witness: try productionBoot(f)), .knownCurrent, stage)
        }
    }

    private func mergeFixture() throws -> (Fixture, String) {
        let initial = try fixture()
        _ = try branchFixture(initial)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("hamii/indexes", isDirectory: true)
        let source = Fixture(root: initial.root, indexRoot: base, documentID: initial.documentID,
                             scopeID: initial.scopeID, initialIdentity: initial.initialIdentity)
        let snapshot = try CanonicalRepository(root: source.root).withCoordinatedSnapshot { $0 }
        _ = try rebuild(source, snapshot: snapshot, generation: 1)
        return (source, try git(source.root, "branch", "--show-current"))
    }

    private func mergeIndex() -> ShadowMergeIndex {
        ShadowMergeIndex(sourceGeneration: { root in
            let record = try self.record(root)
            guard record.phase == "pending" else { throw IndexError.stale }
            return record.generation + 1
        }, attach: { generation, url in
            try self.putShadowSource(generation, into: url)
        })
    }

    private func mergePublish(_ root: URL, stopAt: String? = nil, marker: URL? = nil) throws {
        func pause() -> Never {
            try! Data((stopAt ?? "unknown").utf8).write(to: marker!)
            while true { Thread.sleep(forTimeInterval: 1) }
        }
        let publisher = ValidatedMergePublisher(root: root, index: mergeIndex()) { step in
            if step == .pending {
                let candidate = try JSONDecoder().decode(CandidateRecord.self,
                    from: try Data(contentsOf: WorktreeCoordinator(root: root).mergePublicationURL))
                let prior = try self.record(root)
                try self.persist(Record(phase: "pending", generation: prior.generation,
                    snapshotIdentity: prior.snapshotIdentity, proposedIdentity: candidate.candidateCanonicalIdentity,
                    operationID: UUID().uuidString), at: root)
            }
            if step == .gateReleased {
                var pending = try self.record(root)
                pending.phase = "stable"
                pending.generation += 1
                pending.snapshotIdentity = pending.proposedIdentity!
                pending.proposedIdentity = nil
                pending.operationID = nil
                try self.persist(pending, at: root)
            }
            if (stopAt == "mergePending" && step == .pending) ||
                (stopAt == "mergeAfterCAS" && step == .afterRefCAS) ||
                (stopAt == "mergeBeforeIndex" && step == .beforeIndexBuild) ||
                (stopAt == "mergeBeforeRelease" && step == .beforeGateRelease) ||
                (stopAt == "mergeReleased" && step == .gateReleased) { pause() }
        }
        let expected = try CanonicalRepository(root: root).observe().statePrecondition
        _ = try publisher.publish("feature", expectedState: expected)
    }

    private func recoverMerge(_ root: URL) throws {
        let publisher = ValidatedMergePublisher(root: root, index: mergeIndex()) { step in
            if step == .gateReleased {
                var pending = try self.record(root)
                pending.phase = "stable"
                pending.generation += 1
                pending.snapshotIdentity = pending.proposedIdentity!
                pending.proposedIdentity = nil
                pending.operationID = nil
                try self.persist(pending, at: root)
            }
        }
        _ = try publisher.recover()
    }

    func testValidatedMergeShadowGenerationAndRecoveryStops() throws {
        for stage in ["mergePending", "mergeAfterCAS", "mergeBeforeIndex", "mergeBeforeRelease", "mergeReleased"] {
            let (f, sourceBranch) = try mergeFixture()
            let productionBefore = try CanonicalGenerationStore(root: f.root).readStable()
            let productionWitness = try productionBoot(f)
            defer {
                let indexURL = LocalIndexLocation.url(projectRoot: f.root, documentID: f.documentID)
                try? FileManager.default.removeItem(at: indexURL.deletingLastPathComponent())
                try? FileManager.default.removeItem(at: f.root.deletingLastPathComponent())
            }
            let old = try XCTUnwrap(boot(f, rebuildIfStale: false))
            let marker = f.root.deletingLastPathComponent().appendingPathComponent("merge.stop")
            let worker = try child("testMergeWorker", environment: [
                "HAMII_SHADOW_ROOT": f.root.path, "HAMII_SHADOW_STAGE": stage,
                "HAMII_SHADOW_MARKER": marker.path])
            try awaitFile(marker, process: worker)
            kill(worker.processIdentifier, SIGKILL)
            worker.waitUntilExit()
            XCTAssertEqual(worker.terminationReason, .uncaughtSignal, stage)
            if stage != "mergeReleased" {
                XCTAssertThrowsError(try CanonicalRepository(root: f.root).observe(), stage)
                XCTAssertThrowsError(try boot(f, rebuildIfStale: true), stage)
            }
            try recoverMerge(f.root)
            let expectedOld = stage == "mergePending"
            XCTAssertEqual(try git(f.root, "branch", "--show-current"), sourceBranch, stage)
            let restored = try XCTUnwrap(boot(f, rebuildIfStale: true), stage)
            XCTAssertEqual(restored.generation, expectedOld ? old.generation : old.generation + 1, stage)
            XCTAssertEqual(shadow(f, witness: restored), .knownCurrent, stage)
            XCTAssertEqual(oracle(f, text: expectedOld ? "Alpha" : "Feature"), .knownCurrent, stage)
            let productionAfter = try CanonicalGenerationStore(root: f.root).readStable()
            XCTAssertEqual(productionAfter.generation.value,
                           productionBefore.generation.value + (expectedOld ? 0 : 1), stage)
            XCTAssertEqual(productionAfter.snapshotIdentity.rawValue, restored.snapshotIdentity, stage)
            XCTAssertEqual(productionShadow(f, witness: productionWitness), expectedOld ? .knownCurrent : .stale, stage)
            XCTAssertEqual(productionShadow(f, witness: try productionBoot(f)), .knownCurrent, stage)
        }
    }

    private func starterFixture() throws -> Fixture {
        let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = repositoryRoot.appendingPathComponent("Samples/Starter")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("hamii-shadow-starter-\(UUID().uuidString)")
        let root = temporary.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: root)
        try? FileManager.default.removeItem(at: root.appendingPathComponent(".hamii"))
        try Data(".hamii/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try git(root, "init", "-q")
        try git(root, "add", "-A")
        try git(root, "-c", "user.name=Spike", "-c", "user.email=spike@example.invalid", "commit", "-qm", "starter")
        let repository = CanonicalRepository(root: root)
        let snapshot = try repository.withCoordinatedSnapshot { $0 }
        let fixture = Fixture(root: root, indexRoot: temporary.appendingPathComponent("Indexes"),
            documentID: snapshot.document.id, scopeID: try XCTUnwrap(snapshot.document.scopes.first?.id),
            initialIdentity: snapshot.identity.rawValue)
        try persist(Record(phase: "stable", generation: 1, snapshotIdentity: snapshot.identity.rawValue,
                           proposedIdentity: nil, operationID: nil), at: root)
        _ = try rebuild(fixture, snapshot: snapshot, generation: 1)
        return fixture
    }

    private func largeFixture() throws -> Fixture {
        let initial = try fixture()
        let repository = CanonicalRepository(root: initial.root)
        let old = try repository.load()
        var next = old
        next.components = (0..<1000).map { number in
            ComponentDefinition(id: EntityID("component_\(number)"), name: "Component \(number)",
                ownerScopeID: initial.scopeID,
                root: Layer(id: EntityID("layer_\(number)"), kind: .stack, name: "Root"))
        }
        next.revision += 1
        try repository.save(next, expected: old)
        try git(initial.root, "add", "-A")
        try git(initial.root, "-c", "user.name=Spike", "-c", "user.email=spike@example.invalid", "commit", "-qm", "large")
        let snapshot = try repository.withCoordinatedSnapshot { $0 }
        try persist(Record(phase: "stable", generation: 1, snapshotIdentity: snapshot.identity.rawValue,
                           proposedIdentity: nil, operationID: nil), at: initial.root)
        _ = try rebuild(initial, snapshot: snapshot, generation: 1)
        return Fixture(root: initial.root, indexRoot: initial.indexRoot, documentID: initial.documentID,
                       scopeID: initial.scopeID, initialIdentity: snapshot.identity.rawValue)
    }

    func testMeasuredSteadyStateAndBootCost() throws {
        guard let output = ProcessInfo.processInfo.environment["HAMII_SHADOW_BENCHMARK_RESULT"] else {
            throw XCTSkip("Run with HAMII_SHADOW_BENCHMARK_RESULT for measurements")
        }
        func milliseconds(_ operation: () throws -> Void) throws -> Double {
            let begin = ProcessInfo.processInfo.systemUptime
            try operation()
            return (ProcessInfo.processInfo.systemUptime - begin) * 1000
        }
        func distribution(_ values: [Double]) -> [String: Double] {
            let sorted = values.sorted()
            func quantile(_ value: Double) -> Double {
                let index = max(0, Int(ceil(Double(sorted.count) * value)) - 1)
                return (sorted[index] * 1000).rounded() / 1000
            }
            return ["p50": quantile(0.50), "p95": quantile(0.95)]
        }
        var report: [String: [String: [String: Double]]] = [:]
        for (name, create) in [("starter", starterFixture), ("1000-components", largeFixture)] {
            let f = try create()
            defer { try? FileManager.default.removeItem(at: f.root.deletingLastPathComponent()) }
            var stages: [String: [String: Double]] = [:]
            stages["bootVerification"] = distribution(try (0..<5).map { _ in
                try milliseconds { _ = try XCTUnwrap(boot(f, rebuildIfStale: false)) }
            })
            let witness = try XCTUnwrap(boot(f, rebuildIfStale: false))
            stages["lock"] = distribution(try (0..<40).map { _ in
                try milliseconds { try WorktreeCoordinator(root: f.root).withExclusive { } }
            })
            stages["lockAndGenerationRead"] = distribution(try (0..<40).map { _ in
                try milliseconds {
                    _ = try WorktreeCoordinator(root: f.root).withExclusive { try record(f.root) }
                }
            })
            let stable = try record(f.root)
            stages["generationPersistence"] = distribution(try (0..<20).map { _ in
                try milliseconds {
                    try WorktreeCoordinator(root: f.root).withExclusive { try persist(stable, at: f.root) }
                }
            })
            let local = try index(f)
            stages["sqliteMetadataRead"] = distribution(try (0..<40).map { _ in
                try milliseconds {
                    _ = try sqliteMetadata(local.url, "shadowSourceCanonicalGeneration")
                    _ = try sqliteMetadata(local.url, "indexGenerationID")
                    _ = try sqliteMetadata(local.url, "sourceCanonicalIdentity")
                }
            })
            stages["shadowVerdict"] = distribution(try (0..<40).map { _ in
                try milliseconds { XCTAssertEqual(shadow(f, witness: witness), .knownCurrent) }
            })
            stages["productionOracle"] = distribution(try (0..<20).map { _ in
                try milliseconds { XCTAssertEqual(oracle(f, text: name == "starter" ? "" : "Component"), .knownCurrent) }
            })
            stages["revisionCalculation"] = distribution(try (0..<20).map { _ in
                try milliseconds { _ = try GitCanonicalRevisionCalculator().current(at: f.root) }
            })
            stages["snapshotAcquisition"] = distribution(try (0..<20).map { _ in
                try milliseconds { _ = try CanonicalRepository(root: f.root).withCoordinatedSnapshot { $0.identity } }
            })
            let snapshot = try CanonicalRepository(root: f.root).withCoordinatedSnapshot { $0 }
            stages["fullRebuild"] = distribution(try (0..<5).map { _ in
                try milliseconds { _ = try rebuild(f, snapshot: snapshot, generation: stable.generation) }
            })
            report[name] = stages
        }
        let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try bytes.write(to: URL(fileURLWithPath: output))
    }

    func testP4StartupWitnessIsProcessLocalAndIndexRebuildInvalidatesIt() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root.deletingLastPathComponent()) }
        XCTAssertEqual(productionShadow(f, witness: nil), .unknown)
        let initial = try productionBoot(f)
        XCTAssertEqual(productionShadow(f, witness: initial), .knownCurrent)

        let resultURL = f.root.deletingLastPathComponent().appendingPathComponent("production-boot.json")
        let reader = try child("testProductionStartupWitnessWorker", environment: [
            "HAMII_WITNESS_ROOT": f.root.path, "HAMII_WITNESS_INDEX_ROOT": f.indexRoot.path,
            "HAMII_WITNESS_DOCUMENT_ID": f.documentID.rawValue,
            "HAMII_WITNESS_SCOPE_ID": f.scopeID.rawValue, "HAMII_WITNESS_RESULT": resultURL.path])
        reader.waitUntilExit()
        XCTAssertEqual(reader.terminationStatus, 0)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: resultURL)) as? [String: String])
        XCTAssertEqual(result["generation"], initial.generation.serialized)
        XCTAssertEqual(result["indexGenerationID"], initial.indexGenerationID.rawValue)

        let snapshot = try CanonicalRepository(root: f.root).withCoordinatedSnapshot { $0 }
        let rebuilt = try rebuild(f, snapshot: snapshot, generation: try record(f.root).generation)
        XCTAssertEqual(try CanonicalGenerationStore(root: f.root).readStable().generation, initial.generation)
        XCTAssertNotEqual(rebuilt.id, initial.indexGenerationID)
        XCTAssertEqual(productionShadow(f, witness: initial), .unknown)
        XCTAssertEqual(oracle(f), .knownCurrent)
        let renewed = try productionBoot(f)
        XCTAssertEqual(renewed.generation, initial.generation)
        XCTAssertEqual(renewed.snapshotIdentity, initial.snapshotIdentity)
        XCTAssertEqual(renewed.indexGenerationID, rebuilt.id)
        XCTAssertEqual(productionShadow(f, witness: renewed), .knownCurrent)
    }

    func testP4StartupWitnessMissingAndCorruptGenerationNeverAutoTrust() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root.deletingLastPathComponent()) }
        let old = try productionBoot(f)
        let generationURL = f.root.appendingPathComponent(".hamii/canonical-generation.json")
        try FileManager.default.removeItem(at: generationURL)
        XCTAssertEqual(productionShadow(f, witness: old), .unknown)
        // A coordinated full parse may bootstrap a new lineage, but the old
        // Index source generation cannot authorize the new startup session.
        XCTAssertThrowsError(try productionBoot(f))
        let fresh = try CanonicalGenerationStore(root: f.root).readStable()
        XCTAssertNotEqual(fresh.generation.lineage, old.generation.lineage)
        XCTAssertEqual(fresh.snapshotIdentity, old.snapshotIdentity)
        XCTAssertEqual(productionShadow(f, witness: old), .unknown)
        let snapshot = try CanonicalRepository(root: f.root).withCoordinatedSnapshot { $0 }
        _ = try rebuild(f, snapshot: snapshot, generation: try record(f.root).generation)
        XCTAssertEqual(productionShadow(f, witness: try productionBoot(f)), .knownCurrent)
        try Data("corrupt".utf8).write(to: generationURL)
        XCTAssertThrowsError(try productionBoot(f))
        XCTAssertEqual(productionShadow(f, witness: old), .unknown)
    }

    func testP4StartupWitnessRejectsIncompleteIndexBindingAndUnverifiableOracle() throws {
        let cases: [(String, String)] = [
            ("missing ID", "DELETE FROM metadata WHERE key='indexGenerationID'"),
            ("bad ID", "UPDATE metadata SET value='bad' WHERE key='indexGenerationID'"),
            ("wrong source", "UPDATE metadata SET value='0000000000000000000000000000000000000000000000000000000000000000' WHERE key='sourceCanonicalIdentity'"),
            ("missing source generation", "DELETE FROM metadata WHERE key='sourceGenerationBinding'"),
            ("empty source generation", "UPDATE metadata SET value='' WHERE key='sourceGenerationBinding'")
        ]
        for (name, sql) in cases {
            let f = try fixture()
            defer { try? FileManager.default.removeItem(at: f.root.deletingLastPathComponent()) }
            let prior = try productionBoot(f)
            var database: OpaquePointer?
            let url = try index(f).url
            XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK, name)
            XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK, name)
            sqlite3_close(database)
            XCTAssertEqual(productionShadow(f, witness: prior), .unknown, name)
            XCTAssertThrowsError(try productionBoot(f), name)
        }

        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root.deletingLastPathComponent()) }
        let prior = try productionBoot(f)
        let source = try CanonicalGenerationStore(root: f.root).readStable().generation
        for (name, value) in [("old", CanonicalGeneration(lineage: source.lineage, value: source.value - 1)),
                              ("future", CanonicalGeneration(lineage: source.lineage, value: source.value + 1))] {
            let url = try index(f).url
            var database: OpaquePointer?
            XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK, name)
            let sql = "UPDATE metadata SET value='bound:\(value.serialized)' WHERE key='sourceGenerationBinding'"
            XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK, name)
            sqlite3_close(database)
            XCTAssertThrowsError(try productionBoot(f), name)
            XCTAssertNotEqual(productionShadow(f, witness: prior), .knownCurrent, name)
        }
        let current = try CanonicalRepository(root: f.root).withCoordinatedSnapshot { $0 }
        _ = try rebuild(f, snapshot: current, generation: try record(f.root).generation)
        try git(f.root, "update-index", "--assume-unchanged", "components/component_probe.json")
        XCTAssertThrowsError(try productionBoot(f), "Git oracle must refuse hidden canonical state")

        let missing = try fixture()
        defer { try? FileManager.default.removeItem(at: missing.root.deletingLastPathComponent()) }
        let missingURL = try index(missing).url
        try FileManager.default.removeItem(at: missingURL)
        XCTAssertThrowsError(try productionBoot(missing), "Missing Index cannot issue a witness")
    }

    func testP4SlowVerificationAndCoordinatedWriterCannotInterleave() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root.deletingLastPathComponent()) }
        let directory = f.root.deletingLastPathComponent()
        let attempt = directory.appendingPathComponent("witness-writer.attempt")
        let acquired = directory.appendingPathComponent("witness-writer.acquired")
        let completed = directory.appendingPathComponent("witness-writer.completed")
        var worker: Process?
        let witness = try productionBoot(f) {
            worker = try self.child("testStartupRaceWriterWorker", environment: [
                "HAMII_WITNESS_ROOT": f.root.path, "HAMII_WITNESS_ATTEMPT": attempt.path,
                "HAMII_WITNESS_ACQUIRED": acquired.path, "HAMII_WITNESS_COMPLETED": completed.path])
            try self.awaitFile(attempt, process: worker!)
            // The worker is ready to take the same flock, but the full
            // Snapshot / generation / SQLite / Git verification still owns it.
            XCTAssertFalse(FileManager.default.fileExists(atPath: acquired.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: completed.path))
        }
        let writer = try XCTUnwrap(worker)
        try awaitFile(acquired, process: writer)
        try awaitFile(completed, process: writer)
        writer.waitUntilExit()
        XCTAssertEqual(writer.terminationStatus, 0)
        XCTAssertEqual(productionShadow(f, witness: witness), .stale)
        XCTAssertEqual(oracle(f), .stale)
        // Writer-first ordering sees the new state; its old Index cannot
        // produce a mixed or falsely current startup witness.
        XCTAssertThrowsError(try productionBoot(f))
        let snapshot = try CanonicalRepository(root: f.root).withCoordinatedSnapshot { $0 }
        _ = try rebuild(f, snapshot: snapshot, generation: try record(f.root).generation)
        let next = try productionBoot(f)
        XCTAssertNotEqual(next.generation, witness.generation)
        XCTAssertEqual(next.snapshotIdentity, snapshot.identity)
        XCTAssertEqual(productionShadow(f, witness: next), .knownCurrent)
    }

    func testMeasuredP4StartupWitnessCost() throws {
        guard let output = ProcessInfo.processInfo.environment["HAMII_STARTUP_WITNESS_BENCHMARK_RESULT"] else {
            throw XCTSkip("Run with HAMII_STARTUP_WITNESS_BENCHMARK_RESULT for measurements")
        }
        func milliseconds(_ operation: () throws -> Void) throws -> Double {
            let begin = ProcessInfo.processInfo.systemUptime
            try operation()
            return (ProcessInfo.processInfo.systemUptime - begin) * 1000
        }
        func distribution(_ values: [Double]) -> [String: Double] {
            let sorted = values.sorted()
            func quantile(_ probability: Double) -> Double {
                let index = max(0, Int(ceil(Double(sorted.count) * probability)) - 1)
                return Double(String(format: "%.3f", sorted[index]))!
            }
            return ["p50": quantile(0.5), "p95": quantile(0.95)]
        }
        var report: [String: [String: [String: Double]]] = [:]
        for (name, make) in [("starter", starterFixture), ("1000-components", largeFixture)] {
            let f = try make()
            defer { try? FileManager.default.removeItem(at: f.root.deletingLastPathComponent()) }
            var stages: [String: [String: Double]] = [:]
            stages["coordinatedSlowWitnessIssue"] = distribution(try (0..<10).map { _ in
                try milliseconds { _ = try productionBoot(f) }
            })
            let witness = try productionBoot(f)
            stages["warmShadowVerdict"] = distribution(try (0..<40).map { _ in
                try milliseconds { XCTAssertEqual(productionShadow(f, witness: witness), .knownCurrent) }
            })
            stages["productionOracleQuery"] = distribution(try (0..<10).map { _ in
                try milliseconds { XCTAssertEqual(oracle(f, text: name == "starter" ? "" : "Component"), .knownCurrent) }
            })
            stages["freshProcessStartAndWitness"] = distribution(try (0..<5).map { number in
                try milliseconds {
                    let resultURL = f.root.deletingLastPathComponent().appendingPathComponent("witness-bench-\(number).json")
                    let reader = try self.child("testProductionStartupWitnessWorker", environment: [
                        "HAMII_WITNESS_ROOT": f.root.path, "HAMII_WITNESS_INDEX_ROOT": f.indexRoot.path,
                        "HAMII_WITNESS_DOCUMENT_ID": f.documentID.rawValue,
                        "HAMII_WITNESS_SCOPE_ID": f.scopeID.rawValue, "HAMII_WITNESS_RESULT": resultURL.path])
                    reader.waitUntilExit()
                    XCTAssertEqual(reader.terminationStatus, 0)
                    XCTAssertTrue(FileManager.default.fileExists(atPath: resultURL.path))
                }
            })
            report[name] = stages
        }
        let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try bytes.write(to: URL(fileURLWithPath: output))
    }

    func testMeasuredProductionGenerationShadowCost() throws {
        guard let output = ProcessInfo.processInfo.environment["HAMII_PRODUCTION_GENERATION_BENCHMARK_RESULT"] else {
            throw XCTSkip("Run with HAMII_PRODUCTION_GENERATION_BENCHMARK_RESULT for measurements")
        }
        func milliseconds(_ operation: () throws -> Void) throws -> Double {
            let begin = ProcessInfo.processInfo.systemUptime
            try operation()
            return (ProcessInfo.processInfo.systemUptime - begin) * 1000
        }
        func distribution(_ values: [Double]) -> [String: Double] {
            let sorted = values.sorted()
            func quantile(_ value: Double) -> Double {
                let index = max(0, Int(ceil(Double(sorted.count) * value)) - 1)
                return Double(String(format: "%.3f", sorted[index]))!
            }
            return ["p50": quantile(0.50), "p95": quantile(0.95)]
        }
        var report: [String: [String: [String: Double]]] = [:]
        for (name, create) in [("starter", starterFixture), ("1000-components", largeFixture)] {
            let f = try create()
            defer { try? FileManager.default.removeItem(at: f.root.deletingLastPathComponent()) }
            let repository = CanonicalRepository(root: f.root)
            let store = CanonicalGenerationStore(root: f.root)
            let snapshot = try repository.withCoordinatedSnapshot { $0 }
            let source = try store.requireMatchingStable(snapshot).generation
            let local = try index(f)
            let calculator = GitCanonicalRevisionCalculator()
            _ = try local.rebuild(from: snapshot, canonicalRevision: calculator.current(at: f.root),
                                  sourceGenerationBinding: .bound(source))
            let candidateWitness = try productionBoot(f)
            var stages: [String: [String: Double]] = [:]
            stages["coordinatedGenerationRead"] = distribution(try (0..<40).map { _ in
                try milliseconds {
                    _ = try WorktreeCoordinator(root: f.root).withExclusive { try store.readStable() }
                }
            })
            stages["productionShadowVerdict"] = distribution(try (0..<40).map { _ in
                try milliseconds { XCTAssertEqual(productionShadow(f, witness: candidateWitness), .knownCurrent) }
            })
            stages["snapshotAcquisition"] = distribution(try (0..<20).map { _ in
                try milliseconds { _ = try repository.withCoordinatedSnapshot { $0.identity } }
            })
            stages["revisionCalculation"] = distribution(try (0..<20).map { _ in
                try milliseconds { _ = try calculator.current(at: f.root) }
            })
            stages["productionOracleQuery"] = distribution(try (0..<20).map { _ in
                try milliseconds { XCTAssertEqual(oracle(f, text: name == "starter" ? "" : "Component"), .knownCurrent) }
            })
            stages["verifiedBindingCheck"] = distribution(try (0..<5).map { _ in
                try milliseconds {
                    try repository.withCoordinatedSnapshot { current in
                        let stable = try store.requireMatchingStable(current)
                        let indexed = try local.assertCurrent(documentID: current.document.id,
                            revision: current.document.revision, expectedSourceIdentity: current.identity)
                        XCTAssertEqual(indexed.sourceGenerationBinding, .bound(stable.generation))
                    }
                }
            })
            stages["fullRebuildFromPreacquiredSnapshot"] = distribution(try (0..<5).map { _ in
                try milliseconds {
                    _ = try local.rebuild(from: snapshot, canonicalRevision: calculator.current(at: f.root),
                                          sourceGenerationBinding: .bound(source))
                }
            })
            report[name] = stages
        }
        let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try bytes.write(to: URL(fileURLWithPath: output))
    }
}
