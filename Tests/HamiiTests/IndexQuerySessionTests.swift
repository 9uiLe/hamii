import Darwin
import Foundation
import SQLite3
import XCTest
import HamiiApplication
import HamiiCore
@testable import HamiiFormat
@testable import HamiiIndex

final class IndexQuerySessionTests: XCTestCase {
    private final class CountingRevisionCalculator: CanonicalRevisionCalculating {
        private let wrapped = GitCanonicalRevisionCalculator()
        private(set) var calls = 0

        func current(at root: URL) throws -> CanonicalRevision {
            calls += 1
            return try wrapped.current(at: root)
        }
    }

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

    private struct RecoveryBenchmarkSample: Codable {
        let components: Int
        let condition: String
        let phase1LockMS: Double
        let offLockBuildAndValidationMS: Double
        let phase2LockMS: Double
        let maxContiguousLockMS: Double
        let totalRecoveryMS: Double
        let firstQueryMS: Double
        let recoveredQueryMS: Double
    }

    private struct ObservationHandoffBenchmarkSample: Codable {
        let components: Int
        let condition: String
        let mode: String
        let recoveredQueryMS: Double
        let initialObservationMS: Double
        let offLockBuildMS: Double
        let phase2LockMS: Double
        let retryVerificationMS: Double
        let maxMeasuredLockMS: Double
        let querySnapshotCount: Int
        let recoveryPhase1Count: Int
        let gitOracleCount: Int
        let lockAcquisitionCount: Int
    }

    private struct CanonicalObservationProfileSample: Codable {
        let fixture: String
        let iteration: Int
        let phase1Milliseconds: Double
        let totalRecoveryMilliseconds: Double
        let canonical: [CanonicalObservationMeasurement]
        let recovery: [RecoveryObservationMeasurement]
        let resultCount: Int
    }

    private struct CanonicalPathProfileSample: Codable {
        let fixture: String
        let iteration: Int
        let measurements: [CanonicalObservationMeasurement]
        let snapshotIdentity: String
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

    private func addMixedSemanticContent(_ fixture: Fixture) throws {
        let repository = CanonicalRepository(root: fixture.root)
        let old = try repository.load()
        var next = old
        let commerce = EntityID("scope_commerce")
        next.scopes.append(ArchitectureScope(id: commerce, name: "Commerce", parentID: fixture.scopeID))
        next.screens = [Screen(id: EntityID("screen_mixed"), name: "Mixed", scopeID: commerce,
            root: Layer(id: EntityID("screen_mixed_root"), kind: .stack, name: "Root"))]
        next.revision += 1
        try repository.save(next, expected: old)
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
        XCTAssertThrowsError(try LocalIndex.openExisting(projectRoot: fixture.root,
            documentID: fixture.documentID, revisionCalculator: GitCanonicalRevisionCalculator(),
            storageRoot: fixture.indexRoot))
        XCTAssertFalse(FileManager.default.fileExists(atPath: published.path))

        _ = try rebuild(fixture)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(published.path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA user_version = 7", nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        let before = try Data(contentsOf: published)
        XCTAssertThrowsError(try LocalIndex.openExisting(projectRoot: fixture.root,
            documentID: fixture.documentID, revisionCalculator: GitCanonicalRevisionCalculator(),
            storageRoot: fixture.indexRoot))
        XCTAssertEqual(try Data(contentsOf: published), before)
    }

    func testMissingObsoleteAndCorruptIndexesRecoverToCompleteBoundGeneration() throws {
        for damage in ["missing", "obsolete", "corrupt", "incomplete"] {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let published = LocalIndexLocation.url(projectRoot: fixture.root,
                documentID: fixture.documentID, storageRoot: fixture.indexRoot)
            switch damage {
            case "missing": try FileManager.default.removeItem(at: published)
            case "obsolete":
                var database: OpaquePointer?
                XCTAssertEqual(sqlite3_open(published.path, &database), SQLITE_OK)
                XCTAssertEqual(sqlite3_exec(database, "PRAGMA user_version = 7", nil, nil, nil), SQLITE_OK)
                sqlite3_close(database)
            case "incomplete":
                var database: OpaquePointer?
                XCTAssertEqual(sqlite3_open(published.path, &database), SQLITE_OK)
                XCTAssertEqual(sqlite3_exec(database, "DROP TABLE components", nil, nil, nil), SQLITE_OK)
                sqlite3_close(database)
            default: try Data("not a SQLite database".utf8).write(to: published)
            }
            let querySession = session(fixture)
            let recovered = try query(querySession, fixture)
            XCTAssertEqual(recovered.path, .fast, damage)
            XCTAssertEqual(recovered.hits.map(\.name), ["Alpha"], damage)
            XCTAssertEqual(try query(querySession, fixture).path, .fast, damage)
            let stable = try CanonicalGenerationStore(root: fixture.root).readStable()
            XCTAssertEqual(try index(fixture).publishedGeneration().sourceGenerationBinding,
                           .bound(stable.generation), damage)
        }
    }

    func testPublishedIndexClassificationDoesNotChangeInvalidDatabaseBytes() throws {
        for damage in ["obsolete", "malformed", "corrupt"] {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let published = try index(fixture).url
            if damage == "corrupt" {
                try Data("invalid SQLite".utf8).write(to: published)
            } else {
                var database: OpaquePointer?
                XCTAssertEqual(sqlite3_open(published.path, &database), SQLITE_OK)
                let sql = damage == "obsolete" ? "PRAGMA user_version = 7"
                    : "DELETE FROM metadata WHERE key='sourceGenerationBinding'"
                XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
                sqlite3_close(database)
            }
            let before = try Data(contentsOf: published)
            let assessment = try PublishedIndexProbe().inspect(at: published).assessment
            switch (damage, assessment) {
            case ("obsolete", .obsolete), ("malformed", .malformed), ("corrupt", .corrupt): break
            default: XCTFail("Wrong read-only classification for \(damage)")
            }
            XCTAssertEqual(try Data(contentsOf: published), before, damage)
        }
    }

    func testRecoveryCandidateIsDiscardedWhenWriterChangesSourceDuringBuild() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try saveComponent(fixture, as: "BeforeBuild")
        let published = try index(fixture).url
        let oldBytes = try Data(contentsOf: published)
        let service = IndexRecoveryService(projectRoot: fixture.root,
            revisionCalculator: GitCanonicalRevisionCalculator(), storageRoot: fixture.indexRoot) { step in
            if case .candidateBuilt = step { try self.saveComponent(fixture, as: "Beta") }
        }
        XCTAssertThrowsError(try service.recoverOnce()) { error in
            guard case IndexError.stale = error else { return XCTFail("Wrong error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: published), oldBytes)
        XCTAssertEqual(try query(session(fixture), fixture).hits.map(\.name), ["Beta"])
    }

    func testExternalEditAndMissingGenerationDoNotStartAutomaticRecovery() throws {
        let external = try fixture()
        defer { try? FileManager.default.removeItem(at: external.directory) }
        let externalIndex = try index(external).url
        let original = try Data(contentsOf: externalIndex)
        try changeComponent(external, from: "Alpha", to: "External")
        XCTAssertThrowsError(try query(session(external), external))
        XCTAssertEqual(try Data(contentsOf: externalIndex), original)
        let manual = try rebuild(external)
        XCTAssertEqual(manual.sourceGenerationBinding, .explicitlyUnbound)
        XCTAssertEqual(try query(session(external), external).path, .slowUnbound)

        let missing = try fixture()
        defer { try? FileManager.default.removeItem(at: missing.directory) }
        let missingIndex = try index(missing).url
        let generation = missing.root.appendingPathComponent(".hamii/canonical-generation.json")
        try FileManager.default.removeItem(at: missingIndex)
        try FileManager.default.removeItem(at: generation)
        XCTAssertThrowsError(try query(session(missing), missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingIndex.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: generation.path))
    }

    func testHiddenGitFlagsAndFiltersDoNotStartAutomaticRecovery() throws {
        for condition in ["assume-unchanged", "skip-worktree", "filter"] {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let published = try index(fixture).url
            try FileManager.default.removeItem(at: published)
            let canonicalPath = "components/component_alpha.json"
            if condition == "filter" {
                let attributes = fixture.root.appendingPathComponent(".git/info/attributes")
                try Data("\(canonicalPath) filter=hamii-test\n".utf8).write(to: attributes)
                try git(fixture.root, ["config", "filter.hamii-test.clean", "cat"])
            } else {
                try git(fixture.root, ["update-index", "--\(condition)", canonicalPath])
            }
            XCTAssertThrowsError(try query(session(fixture), fixture), condition)
            XCTAssertFalse(FileManager.default.fileExists(atPath: published.path), condition)
        }
    }

    func testRecoveredQueryObservationBaselineCounts() throws {
        for condition in ["missing", "staleBound"] {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            if condition == "missing" {
                try FileManager.default.removeItem(at: index(fixture).url)
            } else {
                try saveComponent(fixture, as: "Beta")
            }
            let calculator = CountingRevisionCalculator()
            var querySteps: [QueryObservationStep] = []
            var recoverySteps: [IndexRecoveryStep] = []
            let querySession = IndexQuerySession(projectRoot: fixture.root,
                revisionCalculator: calculator, storageRoot: fixture.indexRoot,
                afterFastVerdict: nil,
                onRecoveryStep: { recoverySteps.append($0) },
                onObservationStep: { querySteps.append($0) },
                observationHandoffEnabled: false)
            XCTAssertEqual(try query(querySession, fixture).hits.count, 1, condition)
            XCTAssertEqual(querySteps.filter { $0 == .slowSnapshotAcquired }.count, 2, condition)
            XCTAssertEqual(querySteps.filter { $0 == .slowLockAcquired }.count, 2, condition)
            XCTAssertEqual(querySteps.filter { $0 == .fastLockAcquired }.count, 2, condition)
            XCTAssertEqual(querySteps.filter { $0 == .slowRowsRead }.count, 1, condition)
            XCTAssertEqual(querySteps.filter { $0 == .fastRowsRead }.count, 0, condition)
            XCTAssertEqual(querySteps.filter { $0 == .retryStarted }.count, 1, condition)
            XCTAssertEqual(recoverySteps.filter { $0 == .phase1LockAcquired }.count, 1, condition)
            XCTAssertEqual(recoverySteps.filter { $0 == .phase2LockAcquired }.count, 1, condition)
            XCTAssertEqual(calculator.calls, 3, condition)
        }
    }

    func testObservationHandoffCandidateReducesVerifiedObservationCounts() throws {
        for condition in ["missing", "staleBound"] {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            if condition == "missing" {
                try FileManager.default.removeItem(at: index(fixture).url)
            } else {
                try saveComponent(fixture, as: "Beta")
            }
            let calculator = CountingRevisionCalculator()
            var querySteps: [QueryObservationStep] = []
            var recoverySteps: [IndexRecoveryStep] = []
            let querySession = IndexQuerySession(projectRoot: fixture.root,
                revisionCalculator: calculator, storageRoot: fixture.indexRoot,
                afterFastVerdict: nil,
                onRecoveryStep: { recoverySteps.append($0) },
                onObservationStep: { querySteps.append($0) },
                observationHandoffEnabled: true)
            XCTAssertEqual(try query(querySession, fixture).hits.count, 1, condition)
            XCTAssertEqual(querySteps.filter { $0 == .slowSnapshotAcquired }.count, 1, condition)
            XCTAssertEqual(querySteps.filter { $0 == .slowLockAcquired }.count, 1, condition)
            XCTAssertEqual(querySteps.filter { $0 == .fastLockAcquired }.count, 2, condition)
            XCTAssertEqual(querySteps.filter { $0 == .slowRowsRead }.count, 0, condition)
            XCTAssertEqual(querySteps.filter { $0 == .fastRowsRead }.count, 1, condition)
            XCTAssertEqual(querySteps.filter { $0 == .retryStarted }.count, 1, condition)
            XCTAssertEqual(recoverySteps.filter { $0 == .phase1LockAcquired }.count, 0, condition)
            XCTAssertEqual(recoverySteps.filter { $0 == .phase2LockAcquired }.count, 1, condition)
            XCTAssertEqual(calculator.calls, 2, condition)
        }
    }

    func testObservationHandoffCandidateMatchesProductionRowsForRecoverableDamage() throws {
        for condition in ["missing", "staleBound", "obsolete", "malformed", "corrupt"] {
            let fixture = try fixture(componentCount: 3)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let published = try index(fixture).url
            switch condition {
            case "missing": try FileManager.default.removeItem(at: published)
            case "staleBound": try saveComponent(fixture, as: "Beta")
            case "corrupt": try Data("invalid SQLite".utf8).write(to: published)
            default:
                var database: OpaquePointer?
                XCTAssertEqual(sqlite3_open(published.path, &database), SQLITE_OK)
                let sql = condition == "obsolete" ? "PRAGMA user_version = 7"
                    : "DELETE FROM metadata WHERE key='sourceGenerationBinding'"
                XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
                sqlite3_close(database)
            }
            let damagedBytes = condition == "missing" ? nil : try Data(contentsOf: published)
            let baseline = try query(session(fixture), fixture).hits
            if let damagedBytes {
                try damagedBytes.write(to: published, options: .atomic)
            } else {
                try FileManager.default.removeItem(at: published)
            }
            let candidate = IndexQuerySession(projectRoot: fixture.root,
                revisionCalculator: GitCanonicalRevisionCalculator(),
                storageRoot: fixture.indexRoot, afterFastVerdict: nil,
                observationHandoffEnabled: true)
            let result = try query(candidate, fixture)
            XCTAssertEqual(result.hits, baseline, condition)
            XCTAssertEqual(result.path, .fast, condition)
        }
    }

    func testObservationHandoffCandidateRejectsWriterDuringBuild() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try saveComponent(fixture, as: "BeforeBuild")
        let published = try index(fixture).url
        let oldBytes = try Data(contentsOf: published)
        var recoverySteps: [IndexRecoveryStep] = []
        let candidate = IndexQuerySession(projectRoot: fixture.root,
            revisionCalculator: GitCanonicalRevisionCalculator(),
            storageRoot: fixture.indexRoot, afterFastVerdict: nil,
            onRecoveryStep: { step in
                recoverySteps.append(step)
                if step == .candidateBuilt { try self.saveComponent(fixture, as: "AfterBuild") }
            }, observationHandoffEnabled: true)
        XCTAssertThrowsError(try query(candidate, fixture)) { error in
            guard case IndexError.stale = error else { return XCTFail("Wrong error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: published), oldBytes)
        XCTAssertEqual(recoverySteps.filter { $0 == .sourceCaptured }.count, 1)
        XCTAssertEqual(recoverySteps.filter { $0 == .phase1LockAcquired }.count, 0)
        XCTAssertEqual(recoverySteps.filter { $0 == .phase2LockAcquired }.count, 1)
    }

    func testObservationHandoffCandidateRejectsWriterBeforeFastRetryWithoutSecondRecovery() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try FileManager.default.removeItem(at: index(fixture).url)
        var recoverySteps: [IndexRecoveryStep] = []
        let candidate = IndexQuerySession(projectRoot: fixture.root,
            revisionCalculator: GitCanonicalRevisionCalculator(),
            storageRoot: fixture.indexRoot, afterFastVerdict: nil,
            onRecoveryStep: { recoverySteps.append($0) },
            onBeforeRecoveryRetry: { try self.saveComponent(fixture, as: "AfterPublish") },
            observationHandoffEnabled: true)
        XCTAssertThrowsError(try query(candidate, fixture)) { error in
            guard case IndexError.stale = error else { return XCTFail("Wrong error: \(error)") }
        }
        XCTAssertEqual(recoverySteps.filter { $0 == .sourceCaptured }.count, 1)
        XCTAssertEqual(recoverySteps.filter { $0 == .published }.count, 1)
        XCTAssertEqual(recoverySteps.filter { $0 == .phase1LockAcquired }.count, 0)
        XCTAssertEqual(try CanonicalRepository(root: fixture.root).load().components[0].name,
                       "AfterPublish")
    }

    func testObservationHandoffCandidateVerifiesReplacementGenerationWithoutSecondRecovery() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try FileManager.default.removeItem(at: index(fixture).url)
        var recoverySteps: [IndexRecoveryStep] = []
        var querySteps: [QueryObservationStep] = []
        let candidate = IndexQuerySession(projectRoot: fixture.root,
            revisionCalculator: GitCanonicalRevisionCalculator(),
            storageRoot: fixture.indexRoot, afterFastVerdict: nil,
            onRecoveryStep: { recoverySteps.append($0) },
            onBeforeRecoveryRetry: { _ = try self.rebuild(fixture) },
            onObservationStep: { querySteps.append($0) },
            observationHandoffEnabled: true)
        let result = try query(candidate, fixture)
        XCTAssertEqual(result.hits.map(\.name), ["Alpha"])
        XCTAssertEqual(result.path, .slowBound)
        XCTAssertEqual(recoverySteps.filter { $0 == .sourceCaptured }.count, 1)
        XCTAssertEqual(querySteps.filter { $0 == .retryStarted }.count, 1)
        XCTAssertEqual(querySteps.filter { $0 == .slowRowsRead }.count, 1)
    }

    func testObservationHandoffCandidateExcludesExternalUnboundAndBlockedSources() throws {
        let external = try fixture()
        defer { try? FileManager.default.removeItem(at: external.directory) }
        try changeComponent(external, from: "Alpha", to: "External")
        var externalSteps: [IndexRecoveryStep] = []
        let externalSession = IndexQuerySession(projectRoot: external.root,
            revisionCalculator: GitCanonicalRevisionCalculator(),
            storageRoot: external.indexRoot, afterFastVerdict: nil,
            onRecoveryStep: { externalSteps.append($0) },
            observationHandoffEnabled: true)
        XCTAssertThrowsError(try query(externalSession, external))
        XCTAssertFalse(externalSteps.contains(.sourceCaptured))
        _ = try rebuild(external)
        XCTAssertEqual(try query(externalSession, external).path, .slowUnbound)
        XCTAssertFalse(externalSteps.contains(.sourceCaptured))

        let hidden = try fixture()
        defer { try? FileManager.default.removeItem(at: hidden.directory) }
        let hiddenIndex = try index(hidden).url
        try FileManager.default.removeItem(at: hiddenIndex)
        try git(hidden.root, ["update-index", "--assume-unchanged",
                              "components/component_alpha.json"])
        var hiddenSteps: [IndexRecoveryStep] = []
        let hiddenSession = IndexQuerySession(projectRoot: hidden.root,
            revisionCalculator: GitCanonicalRevisionCalculator(),
            storageRoot: hidden.indexRoot, afterFastVerdict: nil,
            onRecoveryStep: { hiddenSteps.append($0) },
            observationHandoffEnabled: true)
        XCTAssertThrowsError(try query(hiddenSession, hidden))
        XCTAssertFalse(hiddenSteps.contains(.sourceCaptured))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hiddenIndex.path))

        let pending = try fixture()
        defer { try? FileManager.default.removeItem(at: pending.directory) }
        let gate = pending.root.appendingPathComponent(".hamii/merge-publication.pending.json")
        try Data("{}".utf8).write(to: gate)
        var pendingSteps: [IndexRecoveryStep] = []
        let pendingSession = IndexQuerySession(projectRoot: pending.root,
            revisionCalculator: GitCanonicalRevisionCalculator(),
            storageRoot: pending.indexRoot, afterFastVerdict: nil,
            onRecoveryStep: { pendingSteps.append($0) },
            observationHandoffEnabled: true)
        XCTAssertThrowsError(try query(pendingSession, pending))
        XCTAssertTrue(pendingSteps.isEmpty)
    }

    func testStoragePathFailureIsNotClassifiedAsDisposableIndexCorruption() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let destination = try index(fixture).url
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        XCTAssertThrowsError(try query(session(fixture), fixture)) { error in
            guard case IndexError.sqlite = error else { return XCTFail("Wrong error: \(error)") }
        }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testProductionRecoveryFailureInjectionLeavesOldPublishedBytesUntouched() throws {
        for failure in ["candidateCreated", "candidateWriting", "beforePublish"] {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            try saveComponent(fixture, as: "Beta")
            let destination = try index(fixture).url
            let before = try Data(contentsOf: destination)
            let service = IndexRecoveryService(projectRoot: fixture.root,
                revisionCalculator: GitCanonicalRevisionCalculator(), storageRoot: fixture.indexRoot) { step in
                if String(describing: step) == failure { throw CocoaError(.fileWriteUnknown) }
            }
            XCTAssertThrowsError(try service.recoverOnce(), failure)
            XCTAssertEqual(try Data(contentsOf: destination), before, failure)
            let published = try LocalIndex.openExisting(projectRoot: fixture.root,
                documentID: fixture.documentID, revisionCalculator: GitCanonicalRevisionCalculator(),
                storageRoot: fixture.indexRoot).publishedGeneration()
            XCTAssertEqual(published.documentRevision, 1, failure)
            XCTAssertEqual(try query(session(fixture), fixture).hits.map(\.name), ["Beta"], failure)
        }
    }

    func testProductionQueryRecoveryAndRetryAreEachBoundedToOne() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try saveComponent(fixture, as: "Beta")
        var sourceCaptures = 0
        var publications = 0
        var retries = 0
        let querySession = IndexQuerySession(projectRoot: fixture.root,
            revisionCalculator: GitCanonicalRevisionCalculator(), storageRoot: fixture.indexRoot,
            afterFastVerdict: nil, onRecoveryStep: { step in
                if case .sourceCaptured = step { sourceCaptures += 1 }
                if case .published = step { publications += 1 }
            }, onBeforeRecoveryRetry: {
                retries += 1
                try self.saveComponent(fixture, as: "Gamma")
            })
        XCTAssertThrowsError(try query(querySession, fixture)) { error in
            guard case IndexError.stale = error else { return XCTFail("Wrong error: \(error)") }
        }
        XCTAssertEqual(sourceCaptures, 1)
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(retries, 1)
        XCTAssertEqual(try query(session(fixture), fixture).hits.map(\.name), ["Gamma"])
    }

    func testProductionRecoveryMatchesManualProjectionForMixedScopeFixture() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let repository = CanonicalRepository(root: fixture.root)
        let old = try repository.load()
        var document = old
        let app = fixture.scopeID
        let commerce = EntityID("scope_commerce")
        let checkout = EntityID("scope_checkout")
        let account = EntityID("scope_account")
        document.scopes += [
            ArchitectureScope(id: commerce, name: "Commerce", parentID: app),
            ArchitectureScope(id: checkout, name: "Checkout", parentID: commerce),
            ArchitectureScope(id: account, name: "Account", parentID: app)
        ]
        var shared = document.components[0]
        shared.availability = AvailabilityPolicy(denyScopeIDs: [account])
        let commerceOnly = ComponentDefinition(id: EntityID("component_commerce"),
            name: "CommerceOnly", ownerScopeID: commerce,
            root: Layer(id: EntityID("layer_commerce"), kind: .stack, name: "Commerce"))
        document.components = [shared, commerceOnly]
        document.screens = [Screen(id: EntityID("screen_checkout"), name: "Checkout", scopeID: checkout,
            root: Layer(id: EntityID("screen_root"), kind: .stack, name: "Root", children: [
                Layer(id: EntityID("instance_shared"), kind: .componentInstance, name: "Shared",
                    component: ComponentInstance(definitionID: shared.id)),
                Layer(id: EntityID("instance_commerce"), kind: .componentInstance, name: "Commerce",
                    component: ComponentInstance(definitionID: commerceOnly.id))
            ]))]
        document.revision += 1
        try repository.save(document, expected: old)
        let manualRoot = fixture.directory.appendingPathComponent("ManualIndex")
        let manual = try LocalIndex(projectRoot: fixture.root, documentID: fixture.documentID,
            revisionCalculator: GitCanonicalRevisionCalculator(), storageRoot: manualRoot)
        let manualGeneration = try repository.withStableSnapshotForDerivedRecovery { snapshot, stable in
            try manual.rebuild(from: snapshot,
                canonicalRevision: GitCanonicalRevisionCalculator().current(at: fixture.root),
                sourceGenerationBinding: .bound(stable.generation))
        }
        let session = session(fixture)
        XCTAssertEqual(try query(session, fixture).path, .fast)
        let published = try LocalIndex.openExisting(projectRoot: fixture.root,
            documentID: fixture.documentID, revisionCalculator: GitCanonicalRevisionCalculator(),
            storageRoot: fixture.indexRoot)
        let generation = try published.publishedGeneration()
        for scope in [app, commerce, checkout, account] {
            XCTAssertEqual(try published.components(matching: "", consumerScopeID: scope,
                verifiedGeneration: generation),
                try manual.components(matching: "", consumerScopeID: scope,
                    verifiedGeneration: manualGeneration))
        }
        XCTAssertEqual(try session.components(matching: "", consumerScopeID: checkout).count, 2)
        XCTAssertTrue(try session.components(matching: "", consumerScopeID: account).isEmpty)
    }

    func testMeasuredProductionFullRecoveryCost() throws {
        guard let output = ProcessInfo.processInfo.environment["HAMII_PRODUCTION_RECOVERY_BENCHMARK_RESULT"] else {
            throw XCTSkip("Set HAMII_PRODUCTION_RECOVERY_BENCHMARK_RESULT for production recovery measurements")
        }
        var samples: [RecoveryBenchmarkSample] = []
        func milliseconds(_ start: Double, _ end: Double) -> Double { (end - start) * 1_000 }
        for count in [1, 1_000, 5_000] {
            for condition in ["missing", "staleBound"] {
                for _ in 0..<3 {
                    let fixture = try fixture(componentCount: count)
                    defer { try? FileManager.default.removeItem(at: fixture.directory) }
                    if condition == "missing" {
                        try FileManager.default.removeItem(at: index(fixture).url)
                    } else {
                        try saveComponent(fixture, as: "Beta")
                    }
                    var marks: [IndexRecoveryStep: Double] = [:]
                    let service = IndexRecoveryService(projectRoot: fixture.root,
                        revisionCalculator: GitCanonicalRevisionCalculator(), storageRoot: fixture.indexRoot) { step in
                        marks[step] = ProcessInfo.processInfo.systemUptime
                    }
                    let started = ProcessInfo.processInfo.systemUptime
                    guard case .published = try service.recoverOnce() else {
                        return XCTFail("Expected one published production recovery")
                    }
                    let finished = ProcessInfo.processInfo.systemUptime
                    let queryStarted = ProcessInfo.processInfo.systemUptime
                    let hits = try query(session(fixture), fixture).hits
                    let queried = ProcessInfo.processInfo.systemUptime
                    XCTAssertEqual(hits.count, count)
                    if condition == "missing" {
                        try FileManager.default.removeItem(at: index(fixture).url)
                    } else {
                        try saveComponent(fixture, as: "Gamma")
                    }
                    let recoveredQueryStarted = ProcessInfo.processInfo.systemUptime
                    XCTAssertEqual(try query(session(fixture), fixture).hits.count, count)
                    let recoveredQueryFinished = ProcessInfo.processInfo.systemUptime
                    let phase1 = milliseconds(try XCTUnwrap(marks[.phase1LockAcquired]),
                                              try XCTUnwrap(marks[.phase1Complete]))
                    let build = milliseconds(try XCTUnwrap(marks[.sourceCaptured]),
                                             try XCTUnwrap(marks[.candidateValidated]))
                    let phase2 = milliseconds(try XCTUnwrap(marks[.phase2LockAcquired]),
                                              try XCTUnwrap(marks[.phase2Complete]))
                    samples.append(RecoveryBenchmarkSample(components: count, condition: condition,
                        phase1LockMS: phase1, offLockBuildAndValidationMS: build,
                        phase2LockMS: phase2, maxContiguousLockMS: max(phase1, phase2),
                        totalRecoveryMS: milliseconds(started, finished),
                        firstQueryMS: milliseconds(queryStarted, queried),
                        recoveredQueryMS: milliseconds(recoveredQueryStarted, recoveredQueryFinished)))
                }
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(samples).write(to: URL(fileURLWithPath: output), options: .atomic)
    }

    func testMeasuredObservationHandoffCandidate() throws {
        guard let output = ProcessInfo.processInfo.environment["HAMII_OBSERVATION_HANDOFF_BENCHMARK_RESULT"] else {
            throw XCTSkip("Set HAMII_OBSERVATION_HANDOFF_BENCHMARK_RESULT for handoff mechanism measurements")
        }
        var samples: [ObservationHandoffBenchmarkSample] = []
        func milliseconds(_ start: Double, _ end: Double) -> Double { (end - start) * 1_000 }
        for count in [1, 1_000, 5_000] {
            for condition in ["missing", "staleBound"] {
                for mode in ["baseline", "handoff"] {
                    for _ in 0..<3 {
                        let fixture = try fixture(componentCount: count)
                        defer { try? FileManager.default.removeItem(at: fixture.directory) }
                        if condition == "missing" {
                            try FileManager.default.removeItem(at: index(fixture).url)
                        } else {
                            try saveComponent(fixture, as: "Beta")
                        }
                        let calculator = CountingRevisionCalculator()
                        var queryMarks: [(QueryObservationStep, Double)] = []
                        var recoveryMarks: [(IndexRecoveryStep, Double)] = []
                        let querySession = IndexQuerySession(projectRoot: fixture.root,
                            revisionCalculator: calculator, storageRoot: fixture.indexRoot,
                            afterFastVerdict: nil,
                            onRecoveryStep: { recoveryMarks.append(($0, ProcessInfo.processInfo.systemUptime)) },
                            onObservationStep: { queryMarks.append(($0, ProcessInfo.processInfo.systemUptime)) },
                            observationHandoffEnabled: mode == "handoff")
                        let started = ProcessInfo.processInfo.systemUptime
                        XCTAssertEqual(try query(querySession, fixture).hits.count, count)
                        let finished = ProcessInfo.processInfo.systemUptime
                        func queryTime(_ step: QueryObservationStep, occurrence: Int = 0) throws -> Double {
                            let times = queryMarks.filter { $0.0 == step }.map(\.1)
                            guard times.indices.contains(occurrence) else { throw IndexError.stale }
                            return times[occurrence]
                        }
                        func recoveryTime(_ step: IndexRecoveryStep) throws -> Double {
                            try XCTUnwrap(recoveryMarks.first { $0.0 == step }?.1)
                        }
                        var lockTimes = [milliseconds(try queryTime(.slowLockAcquired),
                                                      try queryTime(.slowAttemptFailed)),
                                         milliseconds(try recoveryTime(.phase2LockAcquired),
                                                      try recoveryTime(.phase2Complete))]
                        if mode == "baseline" {
                            lockTimes.append(milliseconds(try recoveryTime(.phase1LockAcquired),
                                                          try recoveryTime(.phase1Complete)))
                            lockTimes.append(milliseconds(try queryTime(.slowLockAcquired, occurrence: 1),
                                                          try queryTime(.slowRowsRead)))
                        } else {
                            lockTimes.append(milliseconds(try queryTime(.fastLockAcquired, occurrence: 1),
                                                          try queryTime(.fastRowsRead)))
                        }
                        samples.append(ObservationHandoffBenchmarkSample(components: count,
                            condition: condition, mode: mode,
                            recoveredQueryMS: milliseconds(started, finished),
                            initialObservationMS: milliseconds(started, try recoveryTime(.sourceCaptured)),
                            offLockBuildMS: milliseconds(try recoveryTime(.sourceCaptured),
                                                         try recoveryTime(.candidateValidated)),
                            phase2LockMS: milliseconds(try recoveryTime(.phase2LockAcquired),
                                                       try recoveryTime(.phase2Complete)),
                            retryVerificationMS: milliseconds(try queryTime(.retryStarted), finished),
                            maxMeasuredLockMS: try XCTUnwrap(lockTimes.max()),
                            querySnapshotCount: queryMarks.filter { $0.0 == .slowSnapshotAcquired }.count,
                            recoveryPhase1Count: recoveryMarks.filter { $0.0 == .phase1LockAcquired }.count,
                            gitOracleCount: calculator.calls,
                            lockAcquisitionCount: queryMarks.filter { $0.0 == .fastLockAcquired || $0.0 == .slowLockAcquired }.count +
                                recoveryMarks.filter { $0.0 == .phase1LockAcquired || $0.0 == .phase2LockAcquired }.count))
                    }
                }
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(samples).write(to: URL(fileURLWithPath: output), options: .atomic)
    }

    func testCanonicalObservationProfilingPreservesSnapshotAndQueryResults() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let repository = CanonicalRepository(root: fixture.root)
        let canonicalBefore = try Data(contentsOf: fixture.root.appendingPathComponent("hamii.json"))
        let diagnosticsBefore = try repository.diagnostics()
        let revisionBefore = try GitCanonicalRevisionCalculator().current(at: fixture.root)
        let ordinary = try repository.withStableSnapshotForDerivedRecovery { snapshot, stable in
            (snapshot, stable)
        }
        var measurements: [CanonicalObservationMeasurement] = []
        let profiled = try repository.withStableSnapshotForDerivedRecovery(
            onObservation: { measurements.append($0) }) { snapshot, stable in
                (snapshot, stable)
            }
        XCTAssertEqual(profiled.0.identity, ordinary.0.identity)
        XCTAssertEqual(profiled.0.document, ordinary.0.document)
        XCTAssertEqual(profiled.1, ordinary.1)
        XCTAssertEqual(try repository.diagnostics(), diagnosticsBefore)
        XCTAssertEqual(try GitCanonicalRevisionCalculator().current(at: fixture.root), revisionBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("hamii.json")),
                       canonicalBefore)
        let stages = Set(measurements.map(\.stage))
        let requiredStages: [CanonicalObservationStage] = [
            .transactionRecovery, .readyGate, .stableGenerationRead, .snapshotAcquisition,
            .manifestRead, .directoryEnumeration, .entityBytesRead, .entityDecode,
            .documentValidation, .assetIntegrityValidation, .agentProfilesReadValidation,
            .canonicalPathEnumerationAndSymlinkCheck, .identityBytesRead, .identityHash
        ]
        for stage in requiredStages {
            XCTAssertTrue(stages.contains(stage), "Missing profile stage \(stage)")
        }
        XCTAssertEqual(measurements.filter { $0.stage == .directoryEnumeration }.count, 10)
        XCTAssertEqual(measurements.filter { $0.stage == .entityBytesRead }.count, 10)
        XCTAssertEqual(measurements.filter { $0.stage == .entityDecode }.count, 10)
        XCTAssertGreaterThan(measurements.first { $0.stage == .identityBytesRead }?.bytes ?? 0, 0)
        let revision = try GitCanonicalRevisionCalculator().current(at: fixture.root)
        let sourceIndex = try index(fixture)
        let recovery = IndexRecoveryService(projectRoot: fixture.root,
            revisionCalculator: GitCanonicalRevisionCalculator(), storageRoot: fixture.indexRoot)
        let eligibilityBefore = recovery.eligibility(
            try PublishedIndexProbe().inspect(at: sourceIndex.url), snapshot: ordinary.0,
            stable: ordinary.1, revision: revision)
        let eligibilityAfter = recovery.eligibility(
            try PublishedIndexProbe().inspect(at: sourceIndex.url), snapshot: profiled.0,
            stable: profiled.1, revision: revision)
        XCTAssertEqual(eligibilityBefore, eligibilityAfter)
        try FileManager.default.removeItem(at: sourceIndex.url)
        guard case .published = try recovery.recoverOnce() else { return XCTFail("Expected plain recovery") }
        let plainHits = try query(session(fixture), fixture).hits
        try FileManager.default.removeItem(at: sourceIndex.url)
        let profiledRecovery = IndexRecoveryService(projectRoot: fixture.root,
            revisionCalculator: GitCanonicalRevisionCalculator(), storageRoot: fixture.indexRoot,
            onCanonicalObservation: { measurements.append($0) })
        guard case .published = try profiledRecovery.recoverOnce() else {
            return XCTFail("Expected profiled recovery")
        }
        XCTAssertEqual(try query(session(fixture), fixture).hits, plainHits)
        XCTAssertEqual(plainHits, try oracle(fixture, matching: ""))
    }

    func testMeasuredCanonicalObservationStages() throws {
        guard let output = ProcessInfo.processInfo.environment["HAMII_CANONICAL_OBSERVATION_PROFILE_RESULT"] else {
            throw XCTSkip("Set HAMII_CANONICAL_OBSERVATION_PROFILE_RESULT for stage profiling")
        }
        var samples: [CanonicalObservationProfileSample] = []
        for kind in ["1", "1000", "5000", "mixed"] {
            let count = kind == "mixed" ? 20 : Int(kind)!
            let fixture = try fixture(componentCount: count)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            if kind == "mixed" { try addMixedSemanticContent(fixture) }
            let published = try index(fixture).url
            for iteration in 0..<5 {
                try FileManager.default.removeItem(at: published)
                var canonical: [CanonicalObservationMeasurement] = []
                var recovery: [RecoveryObservationMeasurement] = []
                let service = IndexRecoveryService(projectRoot: fixture.root,
                    revisionCalculator: GitCanonicalRevisionCalculator(), storageRoot: fixture.indexRoot,
                    onCanonicalObservation: { canonical.append($0) },
                    onRecoveryObservation: { recovery.append($0) })
                let start = ProcessInfo.processInfo.systemUptime
                guard case .published = try service.recoverOnce() else {
                    return XCTFail("Expected profiled publication")
                }
                let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1_000
                let hits = try query(session(fixture), fixture).hits
                XCTAssertEqual(hits.count, count)
                let phase1 = recovery.filter { $0.stage == .phase1LockWait || $0.stage == .phase1LockHeld }
                    .reduce(0) { $0 + $1.milliseconds }
                samples.append(CanonicalObservationProfileSample(fixture: kind, iteration: iteration,
                    phase1Milliseconds: phase1, totalRecoveryMilliseconds: elapsed,
                    canonical: canonical, recovery: recovery,
                    resultCount: hits.count))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(samples).write(to: URL(fileURLWithPath: output), options: .atomic)
    }

    func testMeasuredCanonicalPathBreakdown() throws {
        guard let output = ProcessInfo.processInfo.environment["HAMII_CANONICAL_PATH_PROFILE_RESULT"] else {
            throw XCTSkip("Set HAMII_CANONICAL_PATH_PROFILE_RESULT for path breakdown")
        }
        var samples: [CanonicalPathProfileSample] = []
        for kind in ["1", "1000", "5000", "mixed"] {
            let count = kind == "mixed" ? 20 : Int(kind)!
            let fixture = try fixture(componentCount: count)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            if kind == "mixed" { try addMixedSemanticContent(fixture) }
            let repository = CanonicalRepository(root: fixture.root)
            let baseline = try repository.withStableSnapshotForDerivedRecovery { snapshot, stable in
                (snapshot, stable)
            }
            for iteration in 0..<5 {
                var measurements: [CanonicalObservationMeasurement] = []
                let profiled = try repository.withStableSnapshotForDerivedRecovery(
                    onObservation: { measurements.append($0) }) { snapshot, stable in
                        (snapshot, stable)
                    }
                XCTAssertEqual(profiled.0.identity, baseline.0.identity)
                XCTAssertEqual(profiled.0.document, baseline.0.document)
                XCTAssertEqual(profiled.1, baseline.1)
                let symlinks = try XCTUnwrap(measurements.first {
                    $0.stage == .symlinkResourceValueChecks
                })
                XCTAssertEqual(symlinks.folderCount, 10)
                XCTAssertEqual(measurements.filter { $0.stage == .folderExistenceChecks }.count, 10)
                XCTAssertEqual(measurements.first { $0.stage == .contentsOfDirectory &&
                    $0.detail == "components" }?.pathCount, count)
                XCTAssertEqual(measurements.first { $0.stage == .rootBasedURLReconstruction &&
                    $0.detail == "components" }?.pathCount, count)
                XCTAssertNotNil(measurements.first { $0.stage == .pathSorting })
                samples.append(CanonicalPathProfileSample(fixture: kind, iteration: iteration,
                    measurements: measurements, snapshotIdentity: profiled.0.identity.rawValue))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(samples).write(to: URL(fileURLWithPath: output), options: .atomic)
    }

    private func legacyCanonicalSort(_ paths: [URL]) -> [URL] {
        paths.sorted { $0.path < $1.path }
    }

    func testProductionCanonicalPathSortPreservesLegacyOrderAndSnapshot() throws {
        let names = ["component_1.json", "component_10.json", "component_2.json",
                     "A.json", "a.json", "a-b.json", "a_b.json",
                     "prefix.json", "prefix-long.json"]
        let synthetic = names.map { URL(fileURLWithPath: "/tmp/hamii-sort-order/components/\($0)") }
        XCTAssertEqual(Set(synthetic.map(\.path)).count, synthetic.count)
        XCTAssertEqual(sortCanonicalPaths(synthetic), legacyCanonicalSort(synthetic))

        for kind in ["1", "1000", "5000", "mixed"] {
            let fixture = try fixture(componentCount: kind == "mixed" ? 20 : Int(kind)!)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            if kind == "mixed" { try addMixedSemanticContent(fixture) }
            let repository = CanonicalRepository(root: fixture.root)
            try repository.withStableSnapshotForDerivedRecovery { snapshot, stable in
                var unsorted: [URL] = []
                let production = try repository.canonicalJSONPaths(onUnsortedPaths: { unsorted = $0 })
                XCTAssertEqual(Set(unsorted.map(\.path)).count, unsorted.count)
                XCTAssertEqual(production, legacyCanonicalSort(unsorted))
                XCTAssertEqual(snapshot.identity, stable.snapshotIdentity)
                XCTAssertEqual(snapshot.document.components.count, kind == "mixed" ? 20 : Int(kind)!)
            }
            XCTAssertEqual(try repository.diagnostics(), [])
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hamii-sort-alias-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try CanonicalRepository(root: root).create(name: "Sort alias")
        let alternatePath: String
        if root.path.hasPrefix("/var/") {
            alternatePath = "/private" + root.path
        } else if root.path.hasPrefix("/private/var/") {
            alternatePath = String(root.path.dropFirst("/private".count))
        } else {
            throw XCTSkip("No /var and /private/var alias on this host")
        }
        func identityAndPaths(at path: URL) throws -> (CanonicalSnapshotIdentity, [String]) {
            let repository = CanonicalRepository(root: path)
            return try repository.withStableSnapshotForDerivedRecovery { snapshot, _ in
                var unsorted: [URL] = []
                let sorted = try repository.canonicalJSONPaths(onUnsortedPaths: { unsorted = $0 })
                XCTAssertEqual(sorted, legacyCanonicalSort(unsorted))
                let prefix = repository.root.path + "/"
                return (snapshot.identity, sorted.map {
                    $0.path.replacingOccurrences(of: prefix, with: "")
                })
            }
        }
        let direct = try identityAndPaths(at: root)
        let alias = try identityAndPaths(at: URL(fileURLWithPath: alternatePath))
        XCTAssertEqual(direct.0, alias.0)
        XCTAssertEqual(direct.1, alias.1)
    }

    func testProductionCanonicalPathSortPreservesClientPreconditionAndMutation() throws {
        for count in [1, 5_000] {
            let fixture = try fixture(componentCount: count)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let repository = CanonicalRepository(root: fixture.root)
            XCTAssertTrue(FileManager.default.fileExists(atPath:
                fixture.root.appendingPathComponent("hamii-agent-profiles.json").path))
            let (current, legacy) = try WorktreeCoordinator(root: fixture.root).withExclusive {
                var unsorted: [URL] = []
                let currentPaths = try repository.canonicalJSONPaths(onUnsortedPaths: { unsorted = $0 })
                XCTAssertEqual(currentPaths, legacyCanonicalSort(unsorted))
                return (try repository.clientPreconditionForCanonicalPaths(currentPaths),
                        try repository.clientPreconditionForCanonicalPaths(legacyCanonicalSort(unsorted)))
            }
            XCTAssertEqual(current.rawValue, legacy.rawValue)
            XCTAssertEqual(try repository.observe().statePrecondition.rawValue, legacy.rawValue)

            if count == 1 {
                let service = ProjectService(repository: repository)
                let mutation = try service.mutate(.createPage(name: "Keyed state"),
                    expectedState: current, author: .human)
                XCTAssertEqual(mutation.revision, 2)
                XCTAssertNotEqual(mutation.statePrecondition?.rawValue, current.rawValue)
                let after = try WorktreeCoordinator(root: fixture.root).withExclusive {
                    var unsorted: [URL] = []
                    let currentPaths = try repository.canonicalJSONPaths(onUnsortedPaths: { unsorted = $0 })
                    return (try repository.clientPreconditionForCanonicalPaths(currentPaths),
                            try repository.clientPreconditionForCanonicalPaths(legacyCanonicalSort(unsorted)))
                }
                XCTAssertEqual(after.0.rawValue, after.1.rawValue)
                XCTAssertEqual(mutation.statePrecondition?.rawValue, after.1.rawValue)
            }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hamii-sort-token-alias-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try CanonicalRepository(root: root).create(name: "Token alias")
        let alias: String
        if root.path.hasPrefix("/var/") {
            alias = "/private" + root.path
        } else if root.path.hasPrefix("/private/var/") {
            alias = String(root.path.dropFirst("/private".count))
        } else {
            throw XCTSkip("No /var and /private/var alias on this host")
        }
        func tokens(_ root: URL) throws -> (ClientPrecondition, ClientPrecondition) {
            let repository = CanonicalRepository(root: root)
            return try WorktreeCoordinator(root: root).withExclusive {
                var unsorted: [URL] = []
                let currentPaths = try repository.canonicalJSONPaths(onUnsortedPaths: { unsorted = $0 })
                return (try repository.clientPreconditionForCanonicalPaths(currentPaths),
                        try repository.clientPreconditionForCanonicalPaths(legacyCanonicalSort(unsorted)))
            }
        }
        let direct = try tokens(root)
        let alternate = try tokens(URL(fileURLWithPath: alias))
        XCTAssertEqual(direct.0.rawValue, direct.1.rawValue)
        XCTAssertEqual(alternate.0.rawValue, alternate.1.rawValue)
        XCTAssertEqual(direct.0.rawValue, alternate.0.rawValue)
    }

    func testProductionCanonicalPathSortPreservesSymlinkAndFilenameRejections() throws {
        for relativePath in ["hamii.json", "components/component_alpha.json",
                             "hamii-agent-profiles.json"] {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let file = fixture.root.appendingPathComponent(relativePath)
            let copy = fixture.directory.appendingPathComponent("symlink-target.json")
            try Data(contentsOf: file).write(to: copy)
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: copy)
            let repository = CanonicalRepository(root: fixture.root)
            try WorktreeCoordinator(root: fixture.root).withExclusive {
                XCTAssertThrowsError(try repository.snapshotDuringManagedGitTransition())
            }
        }

        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let file = fixture.root.appendingPathComponent("components/component_alpha.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        object["id"] = ["rawValue": "component_other"]
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        let repository = CanonicalRepository(root: fixture.root)
        try WorktreeCoordinator(root: fixture.root).withExclusive {
            XCTAssertThrowsError(try repository.snapshotDuringManagedGitTransition()) { error in
                guard case CanonicalError.filenameMismatch = error else {
                    return XCTFail("Wrong error: \(error)")
                }
            }
        }
    }

    func testProductionPathSortKeepsCoordinatedWriterBehindSnapshot() throws {
        let fixture = try fixture(componentCount: 5_000)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let attempt = fixture.directory.appendingPathComponent("candidate-sort-writer-attempt")
        let result = fixture.directory.appendingPathComponent("candidate-sort-writer-result.json")
        var worker: Process?
        defer {
            if let worker, worker.isRunning {
                kill(worker.processIdentifier, SIGKILL)
                worker.waitUntilExit()
            }
        }
        let repository = CanonicalRepository(root: fixture.root)
        var snapshotComplete = 0.0
        try WorktreeCoordinator(root: fixture.root).withExclusive {
            worker = try child("testRecoveryLockProbeWorker", environment: [
                "HAMII_LOCK_PROBE_PROJECT": fixture.root.path,
                "HAMII_LOCK_PROBE_ATTEMPT": attempt.path,
                "HAMII_LOCK_PROBE_RESULT": result.path
            ])
            try awaitFile(attempt, process: worker!)
            let snapshot = try repository.snapshotDuringManagedGitTransition()
            XCTAssertEqual(snapshot.document.components.count, 5_000)
            snapshotComplete = ProcessInfo.processInfo.systemUptime
            XCTAssertFalse(FileManager.default.fileExists(atPath: result.path))
        }
        let child = try XCTUnwrap(worker)
        try awaitFile(result, process: child)
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        let observed = try JSONDecoder().decode([String: Double].self, from: Data(contentsOf: result))
        XCTAssertLessThan(try XCTUnwrap(observed["attemptedAt"]), snapshotComplete)
        XCTAssertLessThan(snapshotComplete, try XCTUnwrap(observed["acquiredAt"]))
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
        let renewed = try query(querySession, fixture)
        XCTAssertEqual(renewed.path, .fast)
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

    func testMalformedBindingIsReplacedBeforeRowsAreReturned() throws {
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
            XCTAssertEqual(try query(querySession, fixture).path, .fast, sql)
            XCTAssertEqual(try query(querySession, fixture).path, .fast, sql)
            XCTAssertEqual(try query(session(fixture), fixture).path, .slowBound, sql)
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
        XCTAssertEqual(try query(firstSession, first).path, .fast)
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
        XCTAssertEqual(try query(XCTUnwrap(opened), fixture).path, .fast)
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

    func testProductionRecoveryWorker() throws {
        let env = ProcessInfo.processInfo.environment
        guard let project = env["HAMII_RECOVERY_PROJECT"],
              let indexes = env["HAMII_RECOVERY_INDEXES"],
              let ready = env["HAMII_RECOVERY_READY"],
              let release = env["HAMII_RECOVERY_RELEASE"],
              let result = env["HAMII_RECOVERY_RESULT"] else {
            throw XCTSkip("Production recovery worker only")
        }
        let service = IndexRecoveryService(projectRoot: URL(fileURLWithPath: project),
            revisionCalculator: GitCanonicalRevisionCalculator(),
            storageRoot: URL(fileURLWithPath: indexes)) { step in
            guard case .candidateBuilt = step else { return }
            try Data().write(to: URL(fileURLWithPath: ready))
            let deadline = Date().addingTimeInterval(20)
            while !FileManager.default.fileExists(atPath: release) && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            guard FileManager.default.fileExists(atPath: release) else { throw CocoaError(.fileReadUnknown) }
        }
        let outcome = try service.recoverOnce()
        let label: String
        let id: IndexGenerationID
        switch outcome {
        case .published(let value): label = "published"; id = value
        case .reused(let value): label = "reused"; id = value
        case .notEligible: throw IndexError.stale
        }
        try JSONEncoder().encode(["outcome": label, "id": id.rawValue])
            .write(to: URL(fileURLWithPath: result), options: .atomic)
    }

    func testRecoveryLockProbeWorker() throws {
        let env = ProcessInfo.processInfo.environment
        guard let project = env["HAMII_LOCK_PROBE_PROJECT"],
              let attempt = env["HAMII_LOCK_PROBE_ATTEMPT"],
              let result = env["HAMII_LOCK_PROBE_RESULT"] else {
            throw XCTSkip("Recovery lock probe worker only")
        }
        let attemptedAt = ProcessInfo.processInfo.systemUptime
        try Data().write(to: URL(fileURLWithPath: attempt))
        let started = ProcessInfo.processInfo.systemUptime
        var acquiredAt = started
        try WorktreeCoordinator(root: URL(fileURLWithPath: project)).withExclusive {
            acquiredAt = ProcessInfo.processInfo.systemUptime
        }
        let completedAt = ProcessInfo.processInfo.systemUptime
        let waited = (acquiredAt - started) * 1_000
        try JSONEncoder().encode(["writerLockWaitMS": waited, "attemptedAt": attemptedAt,
                                  "acquiredAt": acquiredAt, "completedAt": completedAt])
            .write(to: URL(fileURLWithPath: result), options: .atomic)
    }

    func testMeasuredCanonicalObservationWriterTimeline() throws {
        guard let output = ProcessInfo.processInfo.environment["HAMII_CANONICAL_OBSERVATION_WRITER_TIMELINE_RESULT"] else {
            throw XCTSkip("Set HAMII_CANONICAL_OBSERVATION_WRITER_TIMELINE_RESULT for timeline")
        }
        let fixture = try fixture(componentCount: 5_000)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try FileManager.default.removeItem(at: index(fixture).url)
        let attempt = fixture.directory.appendingPathComponent("profile-writer-attempt")
        let result = fixture.directory.appendingPathComponent("profile-writer-result.json")
        var worker: Process?
        defer {
            if let worker, worker.isRunning {
                kill(worker.processIdentifier, SIGKILL)
                worker.waitUntilExit()
            }
        }
        var timeline: [String: Double] = [:]
        let service = IndexRecoveryService(projectRoot: fixture.root,
            revisionCalculator: GitCanonicalRevisionCalculator(), storageRoot: fixture.indexRoot,
            hook: { step in
                timeline["recovery.\(step)"] = ProcessInfo.processInfo.systemUptime
                if step == .phase1LockAcquired {
                    worker = try self.child("testRecoveryLockProbeWorker", environment: [
                        "HAMII_LOCK_PROBE_PROJECT": fixture.root.path,
                        "HAMII_LOCK_PROBE_ATTEMPT": attempt.path,
                        "HAMII_LOCK_PROBE_RESULT": result.path
                    ])
                    try self.awaitFile(attempt, process: worker!)
                }
            }, onCanonicalObservation: { measurement in
                timeline["canonical.\(measurement.stage.rawValue).\(measurement.detail ?? "all")"] =
                    ProcessInfo.processInfo.systemUptime
            }, onRecoveryObservation: { measurement in
                timeline["phase1.\(measurement.stage.rawValue)"] = ProcessInfo.processInfo.systemUptime
            })
        guard case .published = try service.recoverOnce() else { return XCTFail("Expected publication") }
        let child = try XCTUnwrap(worker)
        try awaitFile(result, process: child)
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        let childTimes = try JSONDecoder().decode([String: Double].self, from: Data(contentsOf: result))
        timeline.merge(childTimes) { _, new in new }
        XCTAssertLessThan(try XCTUnwrap(timeline["recovery.phase1LockAcquired"]),
                          try XCTUnwrap(timeline["attemptedAt"]))
        XCTAssertLessThan(try XCTUnwrap(timeline["attemptedAt"]),
                          try XCTUnwrap(timeline["canonical.snapshotAcquisition.all"]))
        XCTAssertLessThan(try XCTUnwrap(timeline["phase1.phase1LockHeld"]),
                          try XCTUnwrap(timeline["acquiredAt"]))
        XCTAssertLessThanOrEqual(try XCTUnwrap(timeline["acquiredAt"]),
                                 try XCTUnwrap(timeline["completedAt"]))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(timeline).write(to: URL(fileURLWithPath: output), options: .atomic)
    }

    func testProductionCandidateBuildLeavesCoordinatedWriterAvailable() throws {
        let fixture = try fixture(componentCount: 1_000)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try saveComponent(fixture, as: "Beta")
        let attempt = fixture.directory.appendingPathComponent("writer-attempt")
        let result = fixture.directory.appendingPathComponent("writer-result.json")
        var worker: Process?
        defer {
            if let worker, worker.isRunning {
                kill(worker.processIdentifier, SIGKILL)
                worker.waitUntilExit()
            }
        }
        let service = IndexRecoveryService(projectRoot: fixture.root,
            revisionCalculator: GitCanonicalRevisionCalculator(), storageRoot: fixture.indexRoot) { step in
            guard case .candidateWriting = step else { return }
            worker = try self.child("testRecoveryLockProbeWorker", environment: [
                "HAMII_LOCK_PROBE_PROJECT": fixture.root.path,
                "HAMII_LOCK_PROBE_ATTEMPT": attempt.path,
                "HAMII_LOCK_PROBE_RESULT": result.path
            ])
            try self.awaitFile(attempt, process: worker!)
            try self.awaitFile(result, process: worker!)
        }
        guard case .published = try service.recoverOnce() else { return XCTFail("Expected publication") }
        let child = try XCTUnwrap(worker)
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        let measurement = try JSONDecoder().decode([String: Double].self, from: Data(contentsOf: result))
        XCTAssertNotNil(measurement["writerLockWaitMS"])
        XCTAssertEqual(try query(session(fixture), fixture).hits.count, 1_000)
        if let output = ProcessInfo.processInfo.environment["HAMII_PRODUCTION_RECOVERY_WRITER_WAIT_RESULT"] {
            try Data(contentsOf: result).write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }

    func testMeasuredProductionPhase1WriterWait() throws {
        guard let output = ProcessInfo.processInfo.environment["HAMII_PRODUCTION_PHASE1_WRITER_WAIT_RESULT"] else {
            throw XCTSkip("Set HAMII_PRODUCTION_PHASE1_WRITER_WAIT_RESULT for contention measurement")
        }
        let fixture = try fixture(componentCount: 5_000)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try saveComponent(fixture, as: "Beta")
        let attempt = fixture.directory.appendingPathComponent("phase1-writer-attempt")
        let result = fixture.directory.appendingPathComponent("phase1-writer-result.json")
        var worker: Process?
        defer {
            if let worker, worker.isRunning {
                kill(worker.processIdentifier, SIGKILL)
                worker.waitUntilExit()
            }
        }
        let service = IndexRecoveryService(projectRoot: fixture.root,
            revisionCalculator: GitCanonicalRevisionCalculator(), storageRoot: fixture.indexRoot) { step in
            guard case .phase1LockAcquired = step else { return }
            worker = try self.child("testRecoveryLockProbeWorker", environment: [
                "HAMII_LOCK_PROBE_PROJECT": fixture.root.path,
                "HAMII_LOCK_PROBE_ATTEMPT": attempt.path,
                "HAMII_LOCK_PROBE_RESULT": result.path
            ])
            try self.awaitFile(attempt, process: worker!)
        }
        guard case .published = try service.recoverOnce() else { return XCTFail("Expected publication") }
        let child = try XCTUnwrap(worker)
        try awaitFile(result, process: child)
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        try Data(contentsOf: result).write(to: URL(fileURLWithPath: output), options: .atomic)
    }

    func testMeasuredHandoffInitialObservationWriterWait() throws {
        guard let output = ProcessInfo.processInfo.environment["HAMII_HANDOFF_WRITER_WAIT_RESULT"] else {
            throw XCTSkip("Set HAMII_HANDOFF_WRITER_WAIT_RESULT for handoff contention measurement")
        }
        var waits: [Double] = []
        for _ in 0..<3 {
            let fixture = try fixture(componentCount: 5_000)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            try FileManager.default.removeItem(at: index(fixture).url)
            let attempt = fixture.directory.appendingPathComponent("handoff-writer-attempt")
            let result = fixture.directory.appendingPathComponent("handoff-writer-result.json")
            var worker: Process?
            var setupError: Error?
            defer {
                if let worker, worker.isRunning {
                    kill(worker.processIdentifier, SIGKILL)
                    worker.waitUntilExit()
                }
            }
            let candidate = IndexQuerySession(projectRoot: fixture.root,
                revisionCalculator: GitCanonicalRevisionCalculator(),
                storageRoot: fixture.indexRoot, afterFastVerdict: nil,
                onObservationStep: { step in
                    guard step == .slowLockAcquired else { return }
                    do {
                        let child = try self.child("testRecoveryLockProbeWorker", environment: [
                            "HAMII_LOCK_PROBE_PROJECT": fixture.root.path,
                            "HAMII_LOCK_PROBE_ATTEMPT": attempt.path,
                            "HAMII_LOCK_PROBE_RESULT": result.path
                        ])
                        worker = child
                        try self.awaitFile(attempt, process: child)
                    } catch { setupError = error }
                }, observationHandoffEnabled: true)
            XCTAssertEqual(try query(candidate, fixture).hits.count, 5_000)
            if let setupError { throw setupError }
            let child = try XCTUnwrap(worker)
            try awaitFile(result, process: child)
            child.waitUntilExit()
            XCTAssertEqual(child.terminationStatus, 0)
            let measurement = try JSONDecoder().decode([String: Double].self,
                from: Data(contentsOf: result))
            waits.append(try XCTUnwrap(measurement["writerLockWaitMS"]))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try encoder.encode(waits).write(to: URL(fileURLWithPath: output), options: .atomic)
    }

    func testTwoOSProcessRecoveriesPublishOnceAndReuseOneGeneration() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try saveComponent(fixture, as: "Beta")
        let before = try index(fixture).publishedGeneration()
        let release = fixture.directory.appendingPathComponent("recovery-release")
        var workers: [Process] = []
        var results: [URL] = []
        defer {
            for worker in workers where worker.isRunning {
                kill(worker.processIdentifier, SIGKILL)
                worker.waitUntilExit()
            }
        }
        for number in 0..<2 {
            let ready = fixture.directory.appendingPathComponent("recovery-ready-\(number)")
            let result = fixture.directory.appendingPathComponent("recovery-result-\(number).json")
            let worker = try child("testProductionRecoveryWorker", environment: [
                "HAMII_RECOVERY_PROJECT": fixture.root.path,
                "HAMII_RECOVERY_INDEXES": fixture.indexRoot.path,
                "HAMII_RECOVERY_READY": ready.path,
                "HAMII_RECOVERY_RELEASE": release.path,
                "HAMII_RECOVERY_RESULT": result.path
            ])
            workers.append(worker)
            results.append(result)
            try awaitFile(ready, process: worker)
        }
        XCTAssertEqual(try LocalIndex.openExisting(projectRoot: fixture.root,
            documentID: fixture.documentID, revisionCalculator: GitCanonicalRevisionCalculator(),
            storageRoot: fixture.indexRoot).publishedGeneration().id, before.id)
        try Data().write(to: release)
        for (worker, result) in zip(workers, results) {
            try awaitFile(result, process: worker)
            worker.waitUntilExit()
            XCTAssertEqual(worker.terminationStatus, 0)
        }
        let outcomes = try results.map { try JSONDecoder().decode([String: String].self,
            from: Data(contentsOf: $0)) }
        XCTAssertEqual(Set(outcomes.compactMap { $0["outcome"] }), ["published", "reused"])
        XCTAssertEqual(Set(outcomes.compactMap { $0["id"] }).count, 1)
        XCTAssertEqual(try index(fixture).publishedGeneration().id.rawValue, outcomes[0]["id"])
        let reader = session(fixture)
        XCTAssertEqual(try query(reader, fixture).hits.map(\.name), ["Beta"])
        XCTAssertEqual(try query(reader, fixture).path, .fast)
    }

    func testProductionRecoveryCrashWorker() throws {
        let env = ProcessInfo.processInfo.environment
        guard let project = env["HAMII_CRASH_PROJECT"],
              let indexes = env["HAMII_CRASH_INDEXES"],
              let stopped = env["HAMII_CRASH_STOPPED"],
              let selected = env["HAMII_CRASH_PHASE"] else {
            throw XCTSkip("Production recovery crash worker only")
        }
        let service = IndexRecoveryService(projectRoot: URL(fileURLWithPath: project),
            revisionCalculator: GitCanonicalRevisionCalculator(),
            storageRoot: URL(fileURLWithPath: indexes)) { step in
            let phase = String(describing: step)
            guard phase == selected else { return }
            try Data(phase.utf8).write(to: URL(fileURLWithPath: stopped), options: .atomic)
            while true { Thread.sleep(forTimeInterval: 0.1) }
        }
        _ = try service.recoverOnce()
    }

    func testProductionSIGKILLRecoveryKeepsOldOrCompleteNewGeneration() throws {
        for phase in ["sourceCaptured", "candidateCreated", "candidateWriting",
                      "candidateBuilt", "beforePublish", "published"] {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            try saveComponent(fixture, as: "Beta")
            let old = try index(fixture).publishedGeneration().id
            let stopped = fixture.directory.appendingPathComponent("stopped-\(phase)")
            let worker = try child("testProductionRecoveryCrashWorker", environment: [
                "HAMII_CRASH_PROJECT": fixture.root.path,
                "HAMII_CRASH_INDEXES": fixture.indexRoot.path,
                "HAMII_CRASH_STOPPED": stopped.path,
                "HAMII_CRASH_PHASE": phase
            ])
            try awaitFile(stopped, process: worker)
            XCTAssertTrue(worker.isRunning)
            kill(worker.processIdentifier, SIGKILL)
            worker.waitUntilExit()
            XCTAssertEqual(worker.terminationReason, .uncaughtSignal)
            XCTAssertEqual(worker.terminationStatus, SIGKILL)
            let beforeRestart = try index(fixture).publishedGeneration().id
            if phase == "published" { XCTAssertNotEqual(beforeRestart, old) }
            else { XCTAssertEqual(beforeRestart, old) }
            XCTAssertEqual(try query(session(fixture), fixture).hits.map(\.name), ["Beta"])
            XCTAssertNotEqual(try index(fixture).publishedGeneration().id, old)
        }
    }

    private func awaitFile(_ url: URL, process: Process) throws {
        let deadline = Date().addingTimeInterval(15)
        while !FileManager.default.fileExists(atPath: url.path) && process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            let output = (process.standardOutput as? Pipe)?
                .fileHandleForReading.readDataToEndOfFile() ?? Data()
            XCTFail("Missing worker barrier \(url.lastPathComponent): \(String(decoding: output, as: UTF8.self))")
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
            XCTAssertEqual(try query(querySession, fixture).path, .fast)
        } else {
            XCTAssertEqual(try query(querySession, fixture).path, .slowBound)
            XCTAssertEqual(try query(querySession, fixture).path, .fast)
        }
    }

    func testProductionFastReadBlocksCoordinatedSave() throws { try race("save") }
    func testProductionFastReadBlocksIndexRebuild() throws { try race("rebuild") }
}

extension IndexQuerySessionTests {
    func testSinglePassCandidateMatchesSnapshotAndReadsEachCanonicalJSONOnce() throws {
        for kind in ["1", "1000", "5000", "mixed"] {
            let count = kind == "mixed" ? 20 : Int(kind)!
            let fixture = try fixture(componentCount: count)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            if kind == "mixed" { try addMixedSemanticContent(fixture) }
            let repository = CanonicalRepository(root: fixture.root)
            try repository.withStableSnapshotForDerivedRecovery { legacy, stable in
                let candidate = try repository.singlePassSnapshotCandidate()
                XCTAssertEqual(candidate.snapshot.document, legacy.document)
                XCTAssertEqual(candidate.snapshot.identity, legacy.identity)
                XCTAssertEqual(candidate.snapshot.identity, stable.snapshotIdentity)
                XCTAssertEqual(candidate.snapshot.document.components.map(\.id),
                               legacy.document.components.map(\.id))
                XCTAssertEqual(candidate.snapshot.document.scopes.map(\.id),
                               legacy.document.scopes.map(\.id))
                let expectedPaths = try repository.canonicalJSONPaths().map {
                    $0.path.replacingOccurrences(of: repository.root.path + "/", with: "")
                }
                XCTAssertEqual(candidate.relativePaths, expectedPaths)
                XCTAssertEqual(Set(candidate.readCounts.keys), Set(expectedPaths))
                XCTAssertTrue(candidate.readCounts.values.allSatisfy { $0 == 1 })
                let uniqueBytes = try expectedPaths.reduce(0) {
                    $0 + (try Data(contentsOf: repository.root.appendingPathComponent($1))).count
                }
                XCTAssertEqual(candidate.capturedBytes, uniqueBytes)
            }
            let accepted = try repository.withStableSinglePassCandidate { candidate, stable in
                XCTAssertEqual(candidate.snapshot.identity, stable.snapshotIdentity)
                return candidate.snapshot.document.components.count
            }
            XCTAssertEqual(accepted, count)
        }
    }

    func testSinglePassCandidatePreservesRepositoryAssetAndAliasIdentity() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let repository = CanonicalRepository(root: fixture.root)
        let service = ProjectService(repository: repository)
        let data = Data("image bytes".utf8)
        _ = try service.importRepositoryAsset(data, name: "Avatar", scopeID: fixture.scopeID,
            mediaType: "image/png", expectedState: service.observe().statePrecondition,
            author: .human, blobs: CanonicalBlobStore(root: fixture.root))
        try repository.withStableSnapshotForDerivedRecovery { legacy, stable in
            let candidate = try repository.singlePassSnapshotCandidate()
            XCTAssertEqual(candidate.snapshot.document, legacy.document)
            XCTAssertEqual(candidate.snapshot.identity, legacy.identity)
            XCTAssertEqual(candidate.snapshot.identity, stable.snapshotIdentity)
            XCTAssertEqual(candidate.snapshot.document.assets.count, 1)
            XCTAssertEqual(candidate.readCounts["assets/\(legacy.document.assets[0].id.rawValue).json"], 1)
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hamii-single-pass-alias-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try CanonicalRepository(root: root).create(name: "Snapshot alias")
        let alias: String
        if root.path.hasPrefix("/var/") {
            alias = "/private" + root.path
        } else if root.path.hasPrefix("/private/var/") {
            alias = String(root.path.dropFirst("/private".count))
        } else {
            throw XCTSkip("No /var and /private/var alias on this host")
        }
        func observation(_ root: URL) throws -> SinglePassCandidateResult {
            let repository = CanonicalRepository(root: root)
            return try repository.withStableSinglePassCandidate { result, _ in result }
        }
        let direct = try observation(root)
        let alternate = try observation(URL(fileURLWithPath: alias))
        XCTAssertEqual(direct.snapshot.identity, alternate.snapshot.identity)
        XCTAssertEqual(direct.relativePaths, alternate.relativePaths)
    }

    func testSinglePassCandidateIdentityTracksExactCanonicalBytes() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let repository = CanonicalRepository(root: fixture.root)
        let file = fixture.root.appendingPathComponent("components/component_alpha.json")
        let before = try repository.withStableSnapshotForDerivedRecovery { snapshot, _ in
            let candidate = try repository.singlePassSnapshotCandidate()
            XCTAssertEqual(candidate.snapshot.identity, snapshot.identity)
            return snapshot
        }
        let bytes = try Data(contentsOf: file)
        try Data([0x20] + bytes).write(to: file, options: .atomic)
        let after = try WorktreeCoordinator(root: fixture.root).withExclusive {
            let legacy = try repository.snapshotDuringManagedGitTransition()
            let candidate = try repository.singlePassSnapshotCandidate()
            XCTAssertEqual(candidate.snapshot.identity, legacy.identity)
            XCTAssertEqual(candidate.snapshot.document, legacy.document)
            return legacy
        }
        XCTAssertEqual(before.document, after.document)
        XCTAssertNotEqual(before.identity, after.identity)
        XCTAssertThrowsError(try repository.withStableSinglePassCandidate { _, _ in }) { error in
            guard case CanonicalGenerationError.unknownState = error else {
                return XCTFail("Wrong stale-generation error: \(error)")
            }
        }
    }

    private func singlePassErrorCategory(_ error: Error) -> String {
        switch error {
        case CanonicalError.unsupportedFormat: return "unsupportedFormat"
        case CanonicalError.filenameMismatch: return "filenameMismatch"
        case CanonicalError.invalidClientEpoch: return "symlinkRejected"
        case CanonicalError.invalid(let diagnostics):
            return "invalid:\(diagnostics.map(\.rule).sorted().joined(separator: ","))"
        case AgentProfileError.unsupportedFormat: return "agentProfileFormat"
        case AgentProfileError.duplicateProfile: return "agentProfileDuplicate"
        case is DecodingError: return "decoding"
        default:
            let ns = error as NSError
            return "\(ns.domain):\(ns.code)"
        }
    }

    func testSinglePassCandidatePreservesErrorCategories() throws {
        let cases = ["missingManifest", "unsupportedManifest", "malformedManifest", "malformedEntity",
                     "filenameMismatch", "brokenScope", "missingAssetBlob",
                     "unsupportedProfiles", "duplicateProfiles", "missingProfiles",
                     "manifestSymlink", "componentSymlink", "profileSymlink"]
        for scenario in cases {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let manifest = fixture.root.appendingPathComponent("hamii.json")
            let component = fixture.root.appendingPathComponent("components/component_alpha.json")
            let profiles = fixture.root.appendingPathComponent("hamii-agent-profiles.json")
            func changeJSON(_ file: URL, _ change: (inout [String: Any]) -> Void) throws {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
                change(&object)
                try JSONSerialization.data(withJSONObject: object).write(to: file)
            }
            func symlink(_ file: URL) throws {
                let copy = fixture.directory.appendingPathComponent("symlink-target.json")
                try Data(contentsOf: file).write(to: copy)
                try FileManager.default.removeItem(at: file)
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: copy)
            }
            switch scenario {
            case "missingManifest":
                try FileManager.default.removeItem(at: manifest)
            case "unsupportedManifest":
                try changeJSON(manifest) { $0["formatVersion"] = 2 }
            case "malformedManifest":
                try Data("{".utf8).write(to: manifest)
            case "malformedEntity":
                try Data("{".utf8).write(to: component)
            case "filenameMismatch":
                try changeJSON(component) { $0["id"] = ["rawValue": "component_other"] }
            case "brokenScope":
                try changeJSON(component) { $0["ownerScopeID"] = ["rawValue": "scope_missing"] }
            case "missingAssetBlob":
                let service = ProjectService(repository: CanonicalRepository(root: fixture.root))
                _ = try service.importRepositoryAsset(Data("blob".utf8), name: "Avatar",
                    scopeID: fixture.scopeID, mediaType: "image/png",
                    expectedState: service.observe().statePrecondition, author: .human,
                    blobs: CanonicalBlobStore(root: fixture.root))
                let asset = try XCTUnwrap(CanonicalRepository(root: fixture.root).load().assets.first)
                guard case .repository(let path) = asset.source else { return XCTFail("Expected blob") }
                try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(path))
            case "unsupportedProfiles":
                try changeJSON(profiles) { $0["formatVersion"] = 2 }
            case "duplicateProfiles":
                try changeJSON(profiles) { object in
                    var values = object["profiles"] as! [[String: Any]]
                    values.append(values[0])
                    object["profiles"] = values
                }
            case "missingProfiles":
                try FileManager.default.removeItem(at: profiles)
            case "manifestSymlink": try symlink(manifest)
            case "componentSymlink": try symlink(component)
            case "profileSymlink": try symlink(profiles)
            default: XCTFail("Unknown scenario")
            }
            let repository = CanonicalRepository(root: fixture.root)
            let categories = try WorktreeCoordinator(root: fixture.root).withExclusive { () -> (String, String) in
                func legacy() -> String {
                    do {
                        _ = try repository.snapshotDuringManagedGitTransition()
                        return "accepted"
                    } catch { return singlePassErrorCategory(error) }
                }
                func candidate() -> String {
                    do {
                        _ = try repository.singlePassSnapshotCandidate()
                        return "accepted"
                    } catch { return singlePassErrorCategory(error) }
                }
                return (legacy(), candidate())
            }
            XCTAssertNotEqual(categories.0, "accepted", scenario)
            XCTAssertEqual(categories.0, categories.1, scenario)
        }
    }

    func testSinglePassCandidateRejectsRawEditAgainstStableGeneration() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try changeComponent(fixture, from: "Alpha", to: "Externally edited")
        let repository = CanonicalRepository(root: fixture.root)
        XCTAssertThrowsError(try repository.withStableSinglePassCandidate { _, _ in }) { error in
            guard case CanonicalGenerationError.unknownState = error else {
                return XCTFail("Wrong candidate error: \(error)")
            }
        }
        XCTAssertThrowsError(try repository.withStableSnapshotForDerivedRecovery { _, _ in }) { error in
            guard case CanonicalGenerationError.unknownState = error else {
                return XCTFail("Wrong production error: \(error)")
            }
        }
    }

    func testSinglePassCandidateKeepsCoordinatedWriterOutsideSnapshot() throws {
        let fixture = try fixture(componentCount: 5_000)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let attempt = fixture.directory.appendingPathComponent("single-pass-writer-attempt")
        let result = fixture.directory.appendingPathComponent("single-pass-writer-result.json")
        var worker: Process?
        defer {
            if let worker, worker.isRunning {
                kill(worker.processIdentifier, SIGKILL)
                worker.waitUntilExit()
            }
        }
        let repository = CanonicalRepository(root: fixture.root)
        var completed = 0.0
        var candidateSnapshotMS = 0.0
        try repository.withStableSinglePassCandidate(onLockAcquired: {
            worker = try self.child("testRecoveryLockProbeWorker", environment: [
                "HAMII_LOCK_PROBE_PROJECT": fixture.root.path,
                "HAMII_LOCK_PROBE_ATTEMPT": attempt.path,
                "HAMII_LOCK_PROBE_RESULT": result.path
            ])
            try self.awaitFile(attempt, process: worker!)
        }) { candidate, _ in
            _ = try GitCanonicalRevisionCalculator().current(at: fixture.root)
            completed = ProcessInfo.processInfo.systemUptime
            candidateSnapshotMS = try XCTUnwrap(candidate.milliseconds["snapshotTotal"])
            XCTAssertEqual(candidate.snapshot.document.components.count, 5_000)
            XCTAssertFalse(FileManager.default.fileExists(atPath: result.path))
        }
        let child = try XCTUnwrap(worker)
        try awaitFile(result, process: child)
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        let observed = try JSONDecoder().decode([String: Double].self, from: Data(contentsOf: result))
        XCTAssertLessThan(try XCTUnwrap(observed["attemptedAt"]), completed)
        XCTAssertLessThan(completed, try XCTUnwrap(observed["acquiredAt"]))
        if let output = ProcessInfo.processInfo.environment["HAMII_SINGLE_PASS_WRITER_WAIT_RESULT"] {
            let legacyAttempt = fixture.directory.appendingPathComponent("legacy-writer-attempt")
            let legacyResult = fixture.directory.appendingPathComponent("legacy-writer-result.json")
            var legacyWorker: Process?
            defer {
                if let legacyWorker, legacyWorker.isRunning {
                    kill(legacyWorker.processIdentifier, SIGKILL)
                    legacyWorker.waitUntilExit()
                }
            }
            var legacySnapshotMS = 0.0
            var legacyCompleted = 0.0
            try repository.withStableSnapshotForDerivedRecovery(onLockAcquired: {
                legacyWorker = try self.child("testRecoveryLockProbeWorker", environment: [
                    "HAMII_LOCK_PROBE_PROJECT": fixture.root.path,
                    "HAMII_LOCK_PROBE_ATTEMPT": legacyAttempt.path,
                    "HAMII_LOCK_PROBE_RESULT": legacyResult.path
                ])
                try self.awaitFile(legacyAttempt, process: legacyWorker!)
            }, onObservation: { observation in
                if observation.stage == .snapshotAcquisition {
                    legacySnapshotMS = observation.milliseconds
                }
            }) { snapshot, _ in
                _ = try GitCanonicalRevisionCalculator().current(at: fixture.root)
                legacyCompleted = ProcessInfo.processInfo.systemUptime
                XCTAssertEqual(snapshot.document.components.count, 5_000)
            }
            let secondChild = try XCTUnwrap(legacyWorker)
            try awaitFile(legacyResult, process: secondChild)
            secondChild.waitUntilExit()
            XCTAssertEqual(secondChild.terminationStatus, 0)
            let legacy = try JSONDecoder().decode([String: Double].self, from: Data(contentsOf: legacyResult))
            XCTAssertLessThan(try XCTUnwrap(legacy["attemptedAt"]), legacyCompleted)
            XCTAssertLessThan(legacyCompleted, try XCTUnwrap(legacy["acquiredAt"]))
            let times = ["writerLockWaitMS": try XCTUnwrap(observed["writerLockWaitMS"]),
                         "candidateSnapshotMS": candidateSnapshotMS,
                         "attemptedAt": try XCTUnwrap(observed["attemptedAt"]),
                         "snapshotAndOracleCompletedAt": completed,
                         "acquiredAt": try XCTUnwrap(observed["acquiredAt"]),
                         "legacyWriterLockWaitMS": try XCTUnwrap(legacy["writerLockWaitMS"]),
                         "legacySnapshotMS": legacySnapshotMS,
                         "legacyAttemptedAt": try XCTUnwrap(legacy["attemptedAt"]),
                         "legacySnapshotAndOracleCompletedAt": legacyCompleted,
                         "legacyAcquiredAt": try XCTUnwrap(legacy["acquiredAt"])]
            try JSONEncoder().encode(times).write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }
}

extension IndexQuerySessionTests {
    func testSinglePassCandidateDoesNotBypassHiddenGitSourceRejection() throws {
        for condition in ["assume-unchanged", "skip-worktree", "filter"] {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let canonicalPath = "components/component_alpha.json"
            if condition == "filter" {
                try Data("\(canonicalPath) filter=hamii-test\n".utf8)
                    .write(to: fixture.root.appendingPathComponent(".git/info/attributes"))
                try git(fixture.root, ["config", "filter.hamii-test.clean", "cat"])
            } else {
                try git(fixture.root, ["update-index", "--\(condition)", canonicalPath])
            }
            let repository = CanonicalRepository(root: fixture.root)
            try repository.withStableSinglePassCandidate { candidate, stable in
                XCTAssertEqual(candidate.snapshot.identity, stable.snapshotIdentity)
                XCTAssertThrowsError(try GitCanonicalRevisionCalculator().current(at: fixture.root), condition) { error in
                    guard case IndexError.unverifiableSource = error else {
                        return XCTFail("Wrong Git oracle error for \(condition): \(error)")
                    }
                }
            }
            let published = try index(fixture).url
            try FileManager.default.removeItem(at: published)
            XCTAssertThrowsError(try query(session(fixture), fixture), condition)
            XCTAssertFalse(FileManager.default.fileExists(atPath: published.path), condition)
        }
    }

    private struct SinglePassBenchmarkSample: Codable {
        let fixture: String
        let iteration: Int
        let legacySnapshotMS: Double
        let candidateSnapshotMS: Double
        let legacyPhase1MS: Double
        let candidatePhase1MS: Double
        let candidateStages: [String: Double]
        let capturedBytes: Int
        let canonicalFileCount: Int
    }

    func testMeasuredSinglePassSnapshotCandidate() throws {
        guard let output = ProcessInfo.processInfo.environment["HAMII_SINGLE_PASS_CANDIDATE_RESULT"] else {
            throw XCTSkip("Set HAMII_SINGLE_PASS_CANDIDATE_RESULT for paired Snapshot measurements")
        }
        var samples: [SinglePassBenchmarkSample] = []
        for kind in ["1", "1000", "5000", "mixed"] {
            let count = kind == "mixed" ? 20 : Int(kind)!
            let fixture = try fixture(componentCount: count)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            if kind == "mixed" { try addMixedSemanticContent(fixture) }
            let repository = CanonicalRepository(root: fixture.root)
            for iteration in 0..<5 {
                var legacySnapshotMS = 0.0
                var candidateSnapshotMS = 0.0
                var legacyPhase1MS = 0.0
                var candidatePhase1MS = 0.0
                var legacy: CanonicalSnapshot?
                var candidate: SinglePassCandidateResult?
                func measureLegacy() throws {
                    let started = ProcessInfo.processInfo.systemUptime
                    var observations: [CanonicalObservationMeasurement] = []
                    legacy = try repository.withStableSnapshotForDerivedRecovery(
                        onObservation: { observations.append($0) }) { snapshot, _ in
                        _ = try GitCanonicalRevisionCalculator().current(at: fixture.root)
                        return snapshot
                    }
                    legacyPhase1MS = (ProcessInfo.processInfo.systemUptime - started) * 1_000
                    legacySnapshotMS = try XCTUnwrap(observations.first(where: {
                        $0.stage == .snapshotAcquisition
                    })?.milliseconds)
                }
                func measureCandidate() throws {
                    let started = ProcessInfo.processInfo.systemUptime
                    candidate = try repository.withStableSinglePassCandidate { result, _ in
                        _ = try GitCanonicalRevisionCalculator().current(at: fixture.root)
                        return result
                    }
                    candidatePhase1MS = (ProcessInfo.processInfo.systemUptime - started) * 1_000
                    candidateSnapshotMS = try XCTUnwrap(candidate?.milliseconds["snapshotTotal"])
                }
                if iteration.isMultiple(of: 2) {
                    try measureLegacy(); try measureCandidate()
                } else {
                    try measureCandidate(); try measureLegacy()
                }
                let measured = try XCTUnwrap(candidate)
                XCTAssertEqual(measured.snapshot.document, legacy?.document)
                XCTAssertEqual(measured.snapshot.identity, legacy?.identity)
                XCTAssertTrue(measured.readCounts.values.allSatisfy { $0 == 1 })
                samples.append(SinglePassBenchmarkSample(fixture: kind, iteration: iteration,
                    legacySnapshotMS: legacySnapshotMS, candidateSnapshotMS: candidateSnapshotMS,
                    legacyPhase1MS: legacyPhase1MS, candidatePhase1MS: candidatePhase1MS,
                    candidateStages: measured.milliseconds, capturedBytes: measured.capturedBytes,
                    canonicalFileCount: measured.readCounts.count))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(samples).write(to: URL(fileURLWithPath: output), options: .atomic)
    }
}
