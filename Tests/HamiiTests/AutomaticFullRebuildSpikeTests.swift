import Darwin
import Foundation
import SQLite3
import XCTest
import HamiiCore
@testable import HamiiFormat
@testable import HamiiIndex

/// Test-only recovery candidates. Production queries still reject stale Indexes.
final class AutomaticFullRebuildSpikeTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let indexRoot: URL
        let documentID: EntityID
        let scopeID: EntityID
        var directory: URL { root.deletingLastPathComponent() }
    }

    private struct Source {
        let snapshot: CanonicalSnapshot
        let stable: StableCanonicalGeneration
        let revision: CanonicalRevision
    }

    private struct Candidate {
        let root: URL
        let url: URL
        let descriptor: IndexGenerationDescriptor
    }

    private enum PublishedState: Equatable {
        case missing
        case generation(IndexGenerationID)
    }

    private enum PublicationOutcome: Equatable {
        case published(IndexGenerationID)
        case reused(IndexGenerationID)
    }

    private enum ReadOnlyIndexStatus: Equatable {
        case missing
        case currentSchema
        case obsoleteSchema(Int32)
        case corruptSQLite
    }

    private struct TimingRecord: Codable {
        let components: Int
        let strategy: String
        let snapshotAndRevisionMS: Double
        let candidateBuildMS: Double
        let publicationMS: Double
        let lockHeldMS: Double
        let maximumContiguousLockMS: Double
        let totalRecoveryMS: Double
        let firstQueryMS: Double
    }

    private struct StoppingRevisionCalculator: CanonicalRevisionCalculating {
        let stop: () -> Void
        func current(at root: URL) throws -> CanonicalRevision {
            stop()
            return try GitCanonicalRevisionCalculator().current(at: root)
        }
    }

    private let calculator = GitCanonicalRevisionCalculator()

    private func fixture(componentCount: Int = 1) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hamii-auto-rebuild-spike-\(UUID().uuidString)")
        let root = directory.appendingPathComponent("Project")
        let repository = CanonicalRepository(root: root)
        let created = try repository.create(name: "Auto rebuild spike")
        let scope = try XCTUnwrap(created.scopes.first?.id)
        var changed = created
        changed.components = (0..<componentCount).map { number in
            let suffix = number == 0 ? "alpha" : String(number)
            return ComponentDefinition(id: EntityID("component_\(suffix)"),
                name: number == 0 ? "Alpha" : "Component \(number)", ownerScopeID: scope,
                root: Layer(id: EntityID("layer_\(suffix)"), kind: .stack, name: "Root"))
        }
        changed.revision += 1
        try repository.save(changed, expected: created)
        try Data(".hamii/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try git(root, ["init", "-q"])
        try git(root, ["add", "-A"])
        try git(root, ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                       "commit", "-qm", "initial"])
        return Fixture(root: root, indexRoot: directory.appendingPathComponent("Indexes"),
                       documentID: changed.id, scopeID: scope)
    }

    private func git(_ root: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
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
                       revisionCalculator: calculator, storageRoot: storageRoot ?? fixture.indexRoot)
    }

    private func capture(_ fixture: Fixture) throws -> Source {
        try CanonicalRepository(root: fixture.root).withCoordinatedSnapshot { snapshot in
            let stable = try CanonicalGenerationStore(root: fixture.root).requireMatchingStable(snapshot)
            return Source(snapshot: snapshot, stable: stable, revision: try calculator.current(at: fixture.root))
        }
    }

    private func build(_ fixture: Fixture, from source: Source,
                       transactionHook: (() -> Void)? = nil) throws -> Candidate {
        let root = fixture.directory.appendingPathComponent("Candidate-\(UUID().uuidString)")
        let descriptor: IndexGenerationDescriptor
        let candidateURL: URL
        do {
            let candidate = try index(fixture, storageRoot: root)
            descriptor = try candidate.rebuild(from: source.snapshot, canonicalRevision: source.revision,
                sourceGenerationBinding: .bound(source.stable.generation), transactionHook: transactionHook)
            candidateURL = candidate.url
            guard try candidate.assertCurrent(documentID: fixture.documentID,
                revision: source.snapshot.document.revision,
                expectedSourceIdentity: source.snapshot.identity) == descriptor else {
                throw IndexError.stale
            }
        }
        return Candidate(root: root, url: candidateURL, descriptor: descriptor)
    }

    private func buildFromImmutableSnapshot(_ fixture: Fixture, from source: Source,
                                            transactionHook: (() -> Void)? = nil) throws -> Candidate {
        let root = fixture.directory.appendingPathComponent("ImmutableCandidate-\(UUID().uuidString)")
        let descriptor: IndexGenerationDescriptor
        let candidateURL: URL
        do {
            let candidate = try index(fixture, storageRoot: root)
            descriptor = try candidate.rebuild(from: source.snapshot, canonicalRevision: source.revision,
                sourceGenerationBinding: .bound(source.stable.generation), transactionHook: transactionHook)
            XCTAssertEqual(try candidate.publishedGeneration(), descriptor)
            let actual = try candidate.components(matching: "", consumerScopeID: fixture.scopeID,
                verifiedGeneration: descriptor)
            let expected = IndexProjection(document: source.snapshot.document).components.map {
                ComponentHit(id: $0.id, name: $0.name, ownerScopeID: $0.ownerScopeID,
                             usageCount: $0.usageCount)
            }.sorted { $0.name < $1.name }
            XCTAssertEqual(actual, expected)
            candidateURL = candidate.url
        }
        return Candidate(root: root, url: candidateURL, descriptor: descriptor)
    }

    private func publish(_ fixture: Fixture, source: Source, candidate: Candidate) throws {
        try CanonicalRepository(root: fixture.root).withCoordinatedSnapshot { current in
            guard current.identity == source.snapshot.identity,
                  try CanonicalGenerationStore(root: fixture.root).requireMatchingStable(current) == source.stable,
                  try calculator.current(at: fixture.root) == source.revision else {
                throw IndexError.stale
            }
            let destination = LocalIndexLocation.url(projectRoot: fixture.root,
                documentID: fixture.documentID, storageRoot: fixture.indexRoot)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            guard rename(candidate.url.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
            XCTAssertEqual(try index(fixture).assertCurrent(documentID: fixture.documentID,
                revision: current.document.revision, expectedSourceIdentity: current.identity),
                candidate.descriptor)
        }
    }

    private func publishedState(_ fixture: Fixture) throws -> PublishedState {
        let destination = LocalIndexLocation.url(projectRoot: fixture.root,
            documentID: fixture.documentID, storageRoot: fixture.indexRoot)
        guard FileManager.default.fileExists(atPath: destination.path) else { return .missing }
        return .generation(try index(fixture).publishedGeneration().id)
    }

    private func inspectIndexWithoutMutation(_ fixture: Fixture) throws -> ReadOnlyIndexStatus {
        let url = LocalIndexLocation.url(projectRoot: fixture.root,
            documentID: fixture.documentID, storageRoot: fixture.indexRoot)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(database) }
        guard opened == SQLITE_OK else {
            if opened == SQLITE_CORRUPT || opened == SQLITE_NOTADB { return .corruptSQLite }
            throw IndexError.sqlite("Read-only status probe could not open Index: \(opened)")
        }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard prepared == SQLITE_OK else {
            if prepared == SQLITE_CORRUPT || prepared == SQLITE_NOTADB { return .corruptSQLite }
            throw IndexError.sqlite("Read-only status probe could not inspect schema: \(prepared)")
        }
        let stepped = sqlite3_step(statement)
        guard stepped == SQLITE_ROW else {
            if stepped == SQLITE_CORRUPT || stepped == SQLITE_NOTADB { return .corruptSQLite }
            throw IndexError.sqlite("Read-only status probe could not read schema: \(stepped)")
        }
        let version = sqlite3_column_int(statement, 0)
        return version == LocalIndex.schemaVersion ? .currentSchema : .obsoleteSchema(version)
    }

    /// Test-only compare-and-publish candidate. A competing successful recovery
    /// is reused instead of invalidating long-lived witnesses again.
    private func publishIfExpected(_ fixture: Fixture, source: Source, candidate: Candidate,
                                   expected: PublishedState,
                                   phaseHook: ((String) -> Void)? = nil) throws -> PublicationOutcome {
        try WorktreeCoordinator(root: fixture.root).withReadyExclusive {
            phaseHook?("lockAcquired")
            try CanonicalTransaction(root: fixture.root).recoverIfNeeded()
            let current = try CanonicalRepository(root: fixture.root).snapshotDuringManagedGitTransition()
            guard current.identity == source.snapshot.identity,
                  try CanonicalGenerationStore(root: fixture.root).requireMatchingStable(current) == source.stable,
                  try calculator.current(at: fixture.root) == source.revision else {
                throw IndexError.stale
            }
            let state = try publishedState(fixture)
            if state != expected {
                let existing = try index(fixture).assertCurrent(documentID: fixture.documentID,
                    revision: current.document.revision, expectedSourceIdentity: current.identity)
                guard existing.sourceGenerationBinding == .bound(source.stable.generation) else {
                    throw IndexError.stale
                }
                return .reused(existing.id)
            }
            phaseHook?("sourceVerified")
            let destination = LocalIndexLocation.url(projectRoot: fixture.root,
                documentID: fixture.documentID, storageRoot: fixture.indexRoot)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            guard rename(candidate.url.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
            phaseHook?("renamed")
            let published = try index(fixture).assertCurrent(documentID: fixture.documentID,
                revision: current.document.revision, expectedSourceIdentity: current.identity)
            guard published == candidate.descriptor else { throw IndexError.stale }
            return .published(published.id)
        }
    }

    /// Phase 2 candidate: coordinated Stable G/S + Git R, without a second
    /// Canonical Document parse. It is only evaluated inside the writer contract.
    private func publishWithGenerationAndGitRecheck(_ fixture: Fixture, source: Source,
        candidate: Candidate, expected: PublishedState) throws -> PublicationOutcome {
        try WorktreeCoordinator(root: fixture.root).withReadyExclusive {
            try CanonicalTransaction(root: fixture.root).recoverIfNeeded()
            let stable = try CanonicalGenerationStore(root: fixture.root).readStable()
            guard stable == source.stable,
                  try calculator.current(at: fixture.root) == source.revision else {
                throw IndexError.stale
            }
            let state = try publishedState(fixture)
            if state != expected {
                let existing = try index(fixture).publishedGeneration()
                guard existing.sourceCanonicalIdentity == source.snapshot.identity,
                      existing.sourceGenerationBinding == .bound(source.stable.generation),
                      try calculator.current(at: fixture.root) == source.revision else {
                    throw IndexError.stale
                }
                return .reused(existing.id)
            }
            let destination = LocalIndexLocation.url(projectRoot: fixture.root,
                documentID: fixture.documentID, storageRoot: fixture.indexRoot)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            guard rename(candidate.url.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
            let published = try index(fixture).publishedGeneration()
            guard published == candidate.descriptor else { throw IndexError.stale }
            return .published(published.id)
        }
    }

    private func query(_ fixture: Fixture, with session: IndexQuerySession) throws
        -> (hits: [ComponentHit], path: QueryVerificationPath) {
        try session.componentsWithVerification(matching: "", consumerScopeID: fixture.scopeID)
    }

    private func session(_ fixture: Fixture) -> IndexQuerySession {
        IndexQuerySession(projectRoot: fixture.root, revisionCalculator: calculator,
                          storageRoot: fixture.indexRoot, afterFastVerdict: nil)
    }

    private func saveComponent(_ fixture: Fixture, as name: String) throws {
        let repository = CanonicalRepository(root: fixture.root)
        let old = try repository.load()
        var next = old
        next.components[0].name = name
        next.revision += 1
        try repository.save(next, expected: old)
    }

    private func queryWithOneRecoveryAttempt(_ query: () throws -> [ComponentHit],
                                             recovery: () throws -> Void) throws -> [ComponentHit] {
        do { return try query() }
        catch IndexError.stale {
            try recovery()
            return try query()
        }
    }

    func testMissingIndexCanBeRebuiltUnderLockOrFromCapturedSnapshot() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let source = try capture(fixture)
        let destination = try index(fixture).url
        XCTAssertThrowsError(try query(fixture, with: session(fixture)))

        // Candidate A: hold the coordinated boundary through build and publish.
        try CanonicalRepository(root: fixture.root).withCoordinatedSnapshot { snapshot in
            let stable = try CanonicalGenerationStore(root: fixture.root).requireMatchingStable(snapshot)
            let lockedSource = Source(snapshot: snapshot, stable: stable,
                                      revision: try calculator.current(at: fixture.root))
            let candidate = try build(fixture, from: lockedSource)
            defer { try? FileManager.default.removeItem(at: candidate.root) }
            guard rename(candidate.url.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
        let locked = session(fixture)
        XCTAssertEqual(try query(fixture, with: locked).path, .slowBound)
        XCTAssertEqual(try query(fixture, with: locked).path, .fast)

        // Candidate B: the immutable source is captured under the lock, built
        // outside it, and revalidated before the replacement is published.
        let candidate = try build(fixture, from: source)
        defer { try? FileManager.default.removeItem(at: candidate.root) }
        let priorID = try index(fixture).publishedGeneration().id
        try publish(fixture, source: source, candidate: candidate)
        XCTAssertNotEqual(try index(fixture).publishedGeneration().id, priorID)
        XCTAssertEqual(try query(fixture, with: locked).path, .slowBound)
        XCTAssertEqual(try query(fixture, with: locked).path, .fast)
    }

    func testTwoPhaseRejectsWriterChangeDuringBuildWithoutPublishingOldRows() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let source = try capture(fixture)
        let candidate = try build(fixture, from: source)
        defer { try? FileManager.default.removeItem(at: candidate.root) }
        try saveComponent(fixture, as: "Beta")
        XCTAssertThrowsError(try publish(fixture, source: source, candidate: candidate))
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.url.path))
        XCTAssertThrowsError(try query(fixture, with: session(fixture)))
        let current = try capture(fixture)
        XCTAssertNotEqual(current.snapshot.identity, source.snapshot.identity)
        XCTAssertNotEqual(current.stable.generation, source.stable.generation)
    }

    func testTwoCandidatesForSameSourceProduceWholeGenerations() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let source = try capture(fixture)
        let first = try build(fixture, from: source)
        let second = try build(fixture, from: source)
        defer {
            try? FileManager.default.removeItem(at: first.root)
            try? FileManager.default.removeItem(at: second.root)
        }
        let reader = session(fixture)
        try publish(fixture, source: source, candidate: first)
        XCTAssertEqual(try query(fixture, with: reader).hits.map(\.name), ["Alpha"])
        XCTAssertEqual(try query(fixture, with: reader).path, .fast)
        try publish(fixture, source: source, candidate: second)
        XCTAssertNotEqual(first.descriptor.id, second.descriptor.id)
        XCTAssertEqual(try query(fixture, with: reader).path, .slowBound)
        XCTAssertEqual(try query(fixture, with: reader).hits.map(\.name), ["Alpha"])
    }

    func testAbandonedCandidateDoesNotBecomePublishedIndex() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let candidate = try build(fixture, from: capture(fixture))
        defer { try? FileManager.default.removeItem(at: candidate.root) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.url.path))
        XCTAssertThrowsError(try query(fixture, with: session(fixture)))
        XCTAssertNotEqual(candidate.url.path, LocalIndexLocation.url(projectRoot: fixture.root,
            documentID: fixture.documentID, storageRoot: fixture.indexRoot).path)
    }

    func testUnknownExternalStateAndPendingTransitionAreNotAutoCandidates() throws {
        let externalFixture = try fixture()
        defer { try? FileManager.default.removeItem(at: externalFixture.directory) }
        let component = externalFixture.root.appendingPathComponent("components/component_alpha.json")
        let original = try String(contentsOf: component, encoding: .utf8)
        try Data(original.replacingOccurrences(of: "Alpha", with: "External").utf8).write(to: component)
        XCTAssertThrowsError(try capture(externalFixture))
        XCTAssertThrowsError(try query(externalFixture, with: session(externalFixture)))

        let pendingFixture = try fixture()
        defer { try? FileManager.default.removeItem(at: pendingFixture.directory) }
        try Data("{}".utf8).write(to: pendingFixture.root
            .appendingPathComponent(".hamii/merge-publication.pending.json"))
        XCTAssertThrowsError(try capture(pendingFixture))
        XCTAssertThrowsError(try query(pendingFixture, with: session(pendingFixture)))
    }

    func testMeasuredLockHeldAndTwoPhaseFullRebuild() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["HAMII_AUTO_REBUILD_BENCHMARK_RESULT"] else {
            throw XCTSkip("Set HAMII_AUTO_REBUILD_BENCHMARK_RESULT to measure")
        }
        func ms(_ start: TimeInterval, _ end: TimeInterval) -> Double { (end - start) * 1_000 }
        func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
        var records: [TimingRecord] = []
        for count in [1, 1_000, 5_000] {
            let fixture = try fixture(componentCount: count)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let destination = LocalIndexLocation.url(projectRoot: fixture.root,
                documentID: fixture.documentID, storageRoot: fixture.indexRoot)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            for strategy in ["lockHeld", "twoPhase", "optimizedTwoPhase"] {
                for _ in 0..<5 {
                    try? FileManager.default.removeItem(at: destination)
                    let started = now()
                    let source: Source
                    let candidate: Candidate
                    let captured: TimeInterval
                    let built: TimeInterval
                    let published: TimeInterval
                    if strategy == "lockHeld" {
                        (source, candidate, captured, built, published) = try CanonicalRepository(root: fixture.root)
                            .withCoordinatedSnapshot { snapshot in
                                let stable = try CanonicalGenerationStore(root: fixture.root)
                                    .requireMatchingStable(snapshot)
                                let source = Source(snapshot: snapshot, stable: stable,
                                    revision: try calculator.current(at: fixture.root))
                                let captured = now()
                                let candidate = try build(fixture, from: source)
                                let built = now()
                                guard rename(candidate.url.path, destination.path) == 0 else {
                                    throw CocoaError(.fileWriteUnknown)
                                }
                                return (source, candidate, captured, built, now())
                            }
                    } else if strategy == "twoPhase" {
                        source = try capture(fixture)
                        captured = now()
                        candidate = try build(fixture, from: source)
                        built = now()
                        try publish(fixture, source: source, candidate: candidate)
                        published = now()
                    } else {
                        let capturedSource = try CanonicalRepository(root: fixture.root)
                            .withCoordinatedSnapshot { snapshot -> (Source, PublishedState) in
                                let stable = try CanonicalGenerationStore(root: fixture.root)
                                    .requireMatchingStable(snapshot)
                                let source = Source(snapshot: snapshot, stable: stable,
                                    revision: try calculator.current(at: fixture.root))
                                return (source, try publishedState(fixture))
                            }
                        source = capturedSource.0
                        captured = now()
                        candidate = try buildFromImmutableSnapshot(fixture, from: source)
                        built = now()
                        guard case .published = try publishWithGenerationAndGitRecheck(fixture,
                            source: source, candidate: candidate, expected: capturedSource.1) else {
                            throw IndexError.stale
                        }
                        published = now()
                    }
                    defer { try? FileManager.default.removeItem(at: candidate.root) }
                    XCTAssertEqual(try index(fixture).publishedGeneration(), candidate.descriptor)
                    let queryStarted = now()
                    XCTAssertEqual(try query(fixture, with: session(fixture)).path, .slowBound)
                    let queried = now()
                    records.append(TimingRecord(components: count, strategy: strategy,
                        snapshotAndRevisionMS: ms(started, captured),
                        candidateBuildMS: ms(captured, built),
                        publicationMS: ms(built, published),
                        lockHeldMS: strategy == "lockHeld" ? ms(started, published)
                            : ms(started, captured) + ms(built, published),
                        maximumContiguousLockMS: strategy == "lockHeld" ? ms(started, published)
                            : max(ms(started, captured), ms(built, published)),
                        totalRecoveryMS: ms(started, published),
                        firstQueryMS: ms(queryStarted, queried)))
                    _ = source
                }
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }

    func testConcurrentRecoveryWorker() throws {
        let env = ProcessInfo.processInfo.environment
        guard let project = env["HAMII_AUTO_RECOVERY_PROJECT"],
              let indexes = env["HAMII_AUTO_RECOVERY_INDEXES"],
              let documentID = env["HAMII_AUTO_RECOVERY_DOCUMENT"],
              let scopeID = env["HAMII_AUTO_RECOVERY_SCOPE"],
              let readyPath = env["HAMII_AUTO_RECOVERY_READY"],
              let releasePath = env["HAMII_AUTO_RECOVERY_RELEASE"],
              let resultPath = env["HAMII_AUTO_RECOVERY_RESULT"] else {
            throw XCTSkip("Recovery worker only")
        }
        let fixture = Fixture(root: URL(fileURLWithPath: project), indexRoot: URL(fileURLWithPath: indexes),
            documentID: EntityID(documentID), scopeID: EntityID(scopeID))
        let source = try capture(fixture)
        let expected = try publishedState(fixture)
        let candidate = try build(fixture, from: source)
        defer { try? FileManager.default.removeItem(at: candidate.root) }
        try Data().write(to: URL(fileURLWithPath: readyPath))
        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: releasePath) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard FileManager.default.fileExists(atPath: releasePath) else { throw CocoaError(.fileReadUnknown) }
        let result = try publishIfExpected(fixture, source: source, candidate: candidate, expected: expected)
        let label: String
        let id: IndexGenerationID
        switch result {
        case .published(let value): label = "published"; id = value
        case .reused(let value): label = "reused"; id = value
        }
        let payload = ["outcome": label, "generationID": id.rawValue]
        try JSONEncoder().encode(payload).write(to: URL(fileURLWithPath: resultPath), options: .atomic)
    }

    func testConcurrentQueryWorker() throws {
        let env = ProcessInfo.processInfo.environment
        guard let project = env["HAMII_AUTO_RECOVERY_PROJECT"],
              let indexes = env["HAMII_AUTO_RECOVERY_INDEXES"],
              let documentID = env["HAMII_AUTO_RECOVERY_DOCUMENT"],
              let scopeID = env["HAMII_AUTO_RECOVERY_SCOPE"],
              let readyPath = env["HAMII_AUTO_RECOVERY_READY"],
              let releasePath = env["HAMII_AUTO_RECOVERY_RELEASE"],
              let resultPath = env["HAMII_AUTO_RECOVERY_RESULT"] else {
            throw XCTSkip("Query worker only")
        }
        let fixture = Fixture(root: URL(fileURLWithPath: project), indexRoot: URL(fileURLWithPath: indexes),
            documentID: EntityID(documentID), scopeID: EntityID(scopeID))
        let reader = session(fixture)
        var observations: [String] = []
        do {
            _ = try query(fixture, with: reader)
            XCTFail("Old published Index must be stale before recovery")
        } catch IndexError.stale {
            observations.append("stale")
        }
        try Data().write(to: URL(fileURLWithPath: readyPath))
        let release = URL(fileURLWithPath: releasePath)
        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: release.path) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard FileManager.default.fileExists(atPath: release.path) else { throw CocoaError(.fileReadUnknown) }
        while Date() < deadline {
            do {
                let names = try query(fixture, with: reader).hits.map(\.name)
                XCTAssertEqual(names, ["Beta"])
                observations.append("Beta")
                break
            } catch IndexError.stale {
                observations.append("stale")
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        XCTAssertEqual(observations.last, "Beta")
        try JSONEncoder().encode(observations).write(to: URL(fileURLWithPath: resultPath), options: .atomic)
    }

    private func child(_ method: String, environment: [String: String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        process.arguments = ["-XCTest", "HamiiTests.AutomaticFullRebuildSpikeTests/\(method)",
                             Bundle(for: Self.self).bundleURL.path]
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

    private func awaitFile(_ url: URL, process: Process) throws {
        let deadline = Date().addingTimeInterval(25)
        while !FileManager.default.fileExists(atPath: url.path) && process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            let output = (process.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
            XCTFail("Recovery worker did not reach \(url.lastPathComponent): \(String(decoding: output, as: UTF8.self))")
            throw CocoaError(.fileReadUnknown)
        }
    }

    func testConcurrentOSProcessRecoveryReusesFirstPublishedGeneration() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let initial = try capture(fixture)
        let initialCandidate = try build(fixture, from: initial)
        defer { try? FileManager.default.removeItem(at: initialCandidate.root) }
        try publish(fixture, source: initial, candidate: initialCandidate)
        try saveComponent(fixture, as: "Beta")
        XCTAssertThrowsError(try query(fixture, with: session(fixture)))
        let old = try publishedState(fixture)
        guard case .generation = old else { return XCTFail("Expected stale published generation") }

        let release = fixture.directory.appendingPathComponent("release-concurrent-recovery")
        var processes: [Process] = []
        var results: [URL] = []
        for number in 0..<2 {
            let ready = fixture.directory.appendingPathComponent("ready-\(number)")
            let result = fixture.directory.appendingPathComponent("result-\(number).json")
            let worker = try child("testConcurrentRecoveryWorker", environment: [
                "HAMII_AUTO_RECOVERY_PROJECT": fixture.root.path,
                "HAMII_AUTO_RECOVERY_INDEXES": fixture.indexRoot.path,
                "HAMII_AUTO_RECOVERY_DOCUMENT": fixture.documentID.rawValue,
                "HAMII_AUTO_RECOVERY_SCOPE": fixture.scopeID.rawValue,
                "HAMII_AUTO_RECOVERY_READY": ready.path,
                "HAMII_AUTO_RECOVERY_RELEASE": release.path,
                "HAMII_AUTO_RECOVERY_RESULT": result.path
            ])
            processes.append(worker)
            results.append(result)
            try awaitFile(ready, process: worker)
        }
        let readerReady = fixture.directory.appendingPathComponent("ready-query")
        let readerResult = fixture.directory.appendingPathComponent("result-query.json")
        let readerWorker = try child("testConcurrentQueryWorker", environment: [
            "HAMII_AUTO_RECOVERY_PROJECT": fixture.root.path,
            "HAMII_AUTO_RECOVERY_INDEXES": fixture.indexRoot.path,
            "HAMII_AUTO_RECOVERY_DOCUMENT": fixture.documentID.rawValue,
            "HAMII_AUTO_RECOVERY_SCOPE": fixture.scopeID.rawValue,
            "HAMII_AUTO_RECOVERY_READY": readerReady.path,
            "HAMII_AUTO_RECOVERY_RELEASE": release.path,
            "HAMII_AUTO_RECOVERY_RESULT": readerResult.path
        ])
        try awaitFile(readerReady, process: readerWorker)
        XCTAssertEqual(try publishedState(fixture), old)
        try Data().write(to: release)
        for (worker, result) in zip(processes, results) {
            try awaitFile(result, process: worker)
            worker.waitUntilExit()
            XCTAssertEqual(worker.terminationStatus, 0)
        }
        try awaitFile(readerResult, process: readerWorker)
        readerWorker.waitUntilExit()
        XCTAssertEqual(readerWorker.terminationStatus, 0)
        let observations = try JSONDecoder().decode([String].self, from: Data(contentsOf: readerResult))
        XCTAssertEqual(observations.first, "stale")
        XCTAssertEqual(observations.last, "Beta")
        XCTAssertTrue(observations.allSatisfy { $0 == "stale" || $0 == "Beta" })
        let payloads = try results.map { try JSONDecoder().decode([String: String].self,
            from: Data(contentsOf: $0)) }
        XCTAssertEqual(Set(payloads.compactMap { $0["outcome"] }), ["published", "reused"])
        XCTAssertEqual(Set(payloads.compactMap { $0["generationID"] }).count, 1)
        let published = try index(fixture).publishedGeneration()
        XCTAssertEqual(published.id.rawValue, payloads[0]["generationID"])
        XCTAssertNotEqual(.generation(published.id), old)
        let reader = session(fixture)
        XCTAssertEqual(try query(fixture, with: reader).hits.map(\.name), ["Beta"])
        XCTAssertEqual(try query(fixture, with: reader).path, .fast)
        if let path = ProcessInfo.processInfo.environment["HAMII_AUTO_REBUILD_CONCURRENT_RESULT"] {
            let report = ["writerOutcomes": payloads.compactMap { $0["outcome"] }.sorted(),
                          "queryObservations": observations,
                          "publishedGenerationIDs": payloads.compactMap { $0["generationID"] }]
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func testCrashRecoveryWorker() throws {
        let env = ProcessInfo.processInfo.environment
        guard let project = env["HAMII_AUTO_RECOVERY_PROJECT"],
              let indexes = env["HAMII_AUTO_RECOVERY_INDEXES"],
              let documentID = env["HAMII_AUTO_RECOVERY_DOCUMENT"],
              let scopeID = env["HAMII_AUTO_RECOVERY_SCOPE"],
              let phase = env["HAMII_AUTO_RECOVERY_STOP_PHASE"],
              let stoppedPath = env["HAMII_AUTO_RECOVERY_STOPPED"] else {
            throw XCTSkip("Crash worker only")
        }
        let fixture = Fixture(root: URL(fileURLWithPath: project), indexRoot: URL(fileURLWithPath: indexes),
            documentID: EntityID(documentID), scopeID: EntityID(scopeID))
        func stop(_ at: String) {
            guard phase == at else { return }
            try! Data(at.utf8).write(to: URL(fileURLWithPath: stoppedPath), options: .atomic)
            while true { Thread.sleep(forTimeInterval: 0.1) }
        }
        let source = try capture(fixture)
        let expected = try publishedState(fixture)
        let candidate = try build(fixture, from: source, transactionHook: { stop("duringBuild") })
        defer { try? FileManager.default.removeItem(at: candidate.root) }
        stop("built")
        let outcome = try publishIfExpected(fixture, source: source, candidate: candidate,
            expected: expected, phaseHook: { stop($0) })
        guard case .published = outcome else { throw IndexError.stale }
        let retry = IndexQuerySession(projectRoot: fixture.root,
            revisionCalculator: StoppingRevisionCalculator(stop: { stop("queryRetry") }),
            storageRoot: fixture.indexRoot, afterFastVerdict: nil)
        XCTAssertEqual(try query(fixture, with: retry).hits.map(\.name), ["Beta"])
    }

    func testSIGKILLRecoveryPublicationMatrix() throws {
        guard let resultPath = ProcessInfo.processInfo.environment["HAMII_AUTO_REBUILD_CRASH_MATRIX_RESULT"] else {
            throw XCTSkip("Set HAMII_AUTO_REBUILD_CRASH_MATRIX_RESULT to run real-process SIGKILL matrix")
        }
        var results: [[String: String]] = []
        for phase in ["duringBuild", "built", "lockAcquired", "sourceVerified", "renamed", "queryRetry"] {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let initial = try capture(fixture)
            let initialCandidate = try build(fixture, from: initial)
            try publish(fixture, source: initial, candidate: initialCandidate)
            try? FileManager.default.removeItem(at: initialCandidate.root)
            let oldIndex = try index(fixture).publishedGeneration()
            try saveComponent(fixture, as: "Beta")
            XCTAssertThrowsError(try query(fixture, with: session(fixture)))

            let stopped = fixture.directory.appendingPathComponent("stopped-\(phase)")
            let worker = try child("testCrashRecoveryWorker", environment: [
                "HAMII_AUTO_RECOVERY_PROJECT": fixture.root.path,
                "HAMII_AUTO_RECOVERY_INDEXES": fixture.indexRoot.path,
                "HAMII_AUTO_RECOVERY_DOCUMENT": fixture.documentID.rawValue,
                "HAMII_AUTO_RECOVERY_SCOPE": fixture.scopeID.rawValue,
                "HAMII_AUTO_RECOVERY_STOP_PHASE": phase,
                "HAMII_AUTO_RECOVERY_STOPPED": stopped.path
            ])
            try awaitFile(stopped, process: worker)
            XCTAssertTrue(worker.isRunning)
            XCTAssertEqual(try String(contentsOf: stopped, encoding: .utf8), phase)
            kill(worker.processIdentifier, SIGKILL)
            worker.waitUntilExit()
            XCTAssertEqual(worker.terminationReason, .uncaughtSignal)
            XCTAssertEqual(worker.terminationStatus, SIGKILL)

            let canonical = try CanonicalRepository(root: fixture.root).load()
            XCTAssertEqual(canonical.components.map(\.name), ["Beta"])
            let published = try index(fixture).publishedGeneration()
            let afterCommit = phase == "renamed" || phase == "queryRetry"
            if afterCommit {
                XCTAssertNotEqual(published.id, oldIndex.id)
                XCTAssertEqual(try query(fixture, with: session(fixture)).hits.map(\.name), ["Beta"])
            } else {
                XCTAssertEqual(published.id, oldIndex.id)
                XCTAssertThrowsError(try query(fixture, with: session(fixture)))
                let recovered = try capture(fixture)
                let candidate = try build(fixture, from: recovered)
                let expected = try publishedState(fixture)
                guard case .published = try publishIfExpected(fixture, source: recovered,
                    candidate: candidate, expected: expected) else {
                    return XCTFail("Expected known-source recovery publication")
                }
                try? FileManager.default.removeItem(at: candidate.root)
                XCTAssertEqual(try query(fixture, with: session(fixture)).hits.map(\.name), ["Beta"])
            }
            results.append(["phase": phase, "postKillIndex": afterCommit ? "new" : "old",
                            "postRecoveryQuery": "Beta", "canonical": "Beta",
                            "signal": "SIGKILL"])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: URL(fileURLWithPath: resultPath), options: .atomic)
    }

    func testBoundedAutoRecoveryAndWriterChurn() throws {
        for writerChangesDuringBuild in [false, true] {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let initial = try capture(fixture)
            let initialCandidate = try build(fixture, from: initial)
            try publish(fixture, source: initial, candidate: initialCandidate)
            try? FileManager.default.removeItem(at: initialCandidate.root)
            try saveComponent(fixture, as: "Beta")
            let reader = session(fixture)
            var queryAttempts = 0
            var recoveryAttempts = 0
            let queryAttempt = { () throws -> [ComponentHit] in
                queryAttempts += 1
                return try self.query(fixture, with: reader).hits
            }
            let recoveryAttempt = { () throws -> Void in
                recoveryAttempts += 1
                let source = try self.capture(fixture)
                let expected = try self.publishedState(fixture)
                let candidate = try self.build(fixture, from: source)
                defer { try? FileManager.default.removeItem(at: candidate.root) }
                if writerChangesDuringBuild { try self.saveComponent(fixture, as: "Gamma") }
                guard case .published = try self.publishIfExpected(fixture, source: source,
                    candidate: candidate, expected: expected) else { throw IndexError.stale }
            }
            if writerChangesDuringBuild {
                XCTAssertThrowsError(try queryWithOneRecoveryAttempt(queryAttempt, recovery: recoveryAttempt))
                XCTAssertEqual(queryAttempts, 1)
                XCTAssertEqual(recoveryAttempts, 1)
                XCTAssertThrowsError(try query(fixture, with: reader))
            } else {
                XCTAssertEqual(try queryWithOneRecoveryAttempt(queryAttempt, recovery: recoveryAttempt)
                    .map(\.name), ["Beta"])
                XCTAssertEqual(queryAttempts, 2)
                XCTAssertEqual(recoveryAttempts, 1)
                XCTAssertEqual(try query(fixture, with: reader).path, .fast)
            }
        }
    }

    func testReadOnlyClassificationDoesNotDestructivelyOpenObsoleteOrCorruptIndex() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let source = try capture(fixture)
        XCTAssertEqual(try inspectIndexWithoutMutation(fixture), .missing)
        let candidate = try build(fixture, from: source)
        try publish(fixture, source: source, candidate: candidate)
        try? FileManager.default.removeItem(at: candidate.root)
        XCTAssertEqual(try inspectIndexWithoutMutation(fixture), .currentSchema)
        let url = LocalIndexLocation.url(projectRoot: fixture.root,
            documentID: fixture.documentID, storageRoot: fixture.indexRoot)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA user_version = 7", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(database), SQLITE_OK)
        let obsoleteBytes = try Data(contentsOf: url)
        XCTAssertEqual(try inspectIndexWithoutMutation(fixture), .obsoleteSchema(7))
        XCTAssertEqual(try Data(contentsOf: url), obsoleteBytes)

        // Current LocalIndex construction recreates an old disposable schema.
        // An automatic recovery classifier must inspect before taking this path.
        let recreated = try index(fixture)
        XCTAssertThrowsError(try recreated.publishedGeneration())
        XCTAssertNotEqual(try Data(contentsOf: url), obsoleteBytes)

        let corruptBytes = Data("not a SQLite database".utf8)
        try corruptBytes.write(to: url, options: .atomic)
        XCTAssertEqual(try inspectIndexWithoutMutation(fixture), .corruptSQLite)
        XCTAssertEqual(try Data(contentsOf: url), corruptBytes)
    }

    func testOptimizedPhaseTwoRejectsCoordinatedAndRawSourceChanges() throws {
        let coordinated = try fixture()
        defer { try? FileManager.default.removeItem(at: coordinated.directory) }
        let first = try capture(coordinated)
        let firstCandidate = try buildFromImmutableSnapshot(coordinated, from: first)
        defer { try? FileManager.default.removeItem(at: firstCandidate.root) }
        let expected = try publishedState(coordinated)
        try saveComponent(coordinated, as: "Beta")
        XCTAssertThrowsError(try publishWithGenerationAndGitRecheck(coordinated, source: first,
            candidate: firstCandidate, expected: expected))
        XCTAssertThrowsError(try query(coordinated, with: session(coordinated)))

        let external = try fixture()
        defer { try? FileManager.default.removeItem(at: external.directory) }
        let source = try capture(external)
        let candidate = try buildFromImmutableSnapshot(external, from: source)
        defer { try? FileManager.default.removeItem(at: candidate.root) }
        let externalExpected = try publishedState(external)
        let file = external.root.appendingPathComponent("components/component_alpha.json")
        let old = try String(contentsOf: file, encoding: .utf8)
        try Data(old.replacingOccurrences(of: "Alpha", with: "Raw Edit").utf8).write(to: file)
        XCTAssertEqual(try CanonicalGenerationStore(root: external.root).readStable(), source.stable)
        XCTAssertThrowsError(try publishWithGenerationAndGitRecheck(external, source: source,
            candidate: candidate, expected: externalExpected))
        XCTAssertThrowsError(try query(external, with: session(external)))
    }

    func testOptimizedPhaseTwoRejectsRawBranchSwitchWithUnchangedGeneration() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try git(fixture.root, ["switch", "-qc", "alternate"])
        let file = fixture.root.appendingPathComponent("components/component_alpha.json")
        let old = try String(contentsOf: file, encoding: .utf8)
        try Data(old.replacingOccurrences(of: "Alpha", with: "Alternate").utf8).write(to: file)
        try git(fixture.root, ["add", "-A"])
        try git(fixture.root, ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                               "commit", "-qm", "alternate"])
        try git(fixture.root, ["switch", "-q", "-"])
        let source = try capture(fixture)
        let expected = try publishedState(fixture)
        let candidate = try buildFromImmutableSnapshot(fixture, from: source)
        defer { try? FileManager.default.removeItem(at: candidate.root) }
        try git(fixture.root, ["switch", "-q", "alternate"])
        XCTAssertEqual(try CanonicalGenerationStore(root: fixture.root).readStable(), source.stable)
        XCTAssertThrowsError(try publishWithGenerationAndGitRecheck(fixture, source: source,
            candidate: candidate, expected: expected))
        XCTAssertThrowsError(try query(fixture, with: session(fixture)))
    }

    func testContendingRecoveryWorker() throws {
        let env = ProcessInfo.processInfo.environment
        guard let project = env["HAMII_AUTO_RECOVERY_PROJECT"],
              let indexes = env["HAMII_AUTO_RECOVERY_INDEXES"],
              let documentID = env["HAMII_AUTO_RECOVERY_DOCUMENT"],
              let scopeID = env["HAMII_AUTO_RECOVERY_SCOPE"],
              let strategy = env["HAMII_AUTO_RECOVERY_STRATEGY"],
              let readyPath = env["HAMII_AUTO_RECOVERY_READY"],
              let releasePath = env["HAMII_AUTO_RECOVERY_RELEASE"],
              let resultPath = env["HAMII_AUTO_RECOVERY_RESULT"] else {
            throw XCTSkip("Recovery contention worker only")
        }
        let fixture = Fixture(root: URL(fileURLWithPath: project), indexRoot: URL(fileURLWithPath: indexes),
            documentID: EntityID(documentID), scopeID: EntityID(scopeID))
        func pauseDuringBuild() {
            try! Data().write(to: URL(fileURLWithPath: readyPath))
            let deadline = Date().addingTimeInterval(20)
            while !FileManager.default.fileExists(atPath: releasePath) && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        let outcome: String
        do {
            if strategy == "lockHeld" {
                try CanonicalRepository(root: fixture.root).withCoordinatedSnapshot { snapshot in
                    let stable = try CanonicalGenerationStore(root: fixture.root).requireMatchingStable(snapshot)
                    let source = Source(snapshot: snapshot, stable: stable,
                        revision: try calculator.current(at: fixture.root))
                    let candidate = try build(fixture, from: source, transactionHook: pauseDuringBuild)
                    defer { try? FileManager.default.removeItem(at: candidate.root) }
                    let destination = LocalIndexLocation.url(projectRoot: fixture.root,
                        documentID: fixture.documentID, storageRoot: fixture.indexRoot)
                    guard rename(candidate.url.path, destination.path) == 0 else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
            } else {
                let source = try capture(fixture)
                let expected = try publishedState(fixture)
                let candidate = try strategy == "optimizedTwoPhase"
                    ? buildFromImmutableSnapshot(fixture, from: source, transactionHook: pauseDuringBuild)
                    : build(fixture, from: source, transactionHook: pauseDuringBuild)
                defer { try? FileManager.default.removeItem(at: candidate.root) }
                if strategy == "optimizedTwoPhase" {
                    _ = try publishWithGenerationAndGitRecheck(fixture, source: source,
                        candidate: candidate, expected: expected)
                } else {
                    _ = try publishIfExpected(fixture, source: source, candidate: candidate,
                        expected: expected)
                }
            }
            outcome = "published"
        } catch IndexError.stale {
            outcome = "stale"
        }
        try Data(outcome.utf8).write(to: URL(fileURLWithPath: resultPath), options: .atomic)
    }

    func testContendingWriterWorker() throws {
        let env = ProcessInfo.processInfo.environment
        guard let project = env["HAMII_AUTO_RECOVERY_PROJECT"],
              let indexes = env["HAMII_AUTO_RECOVERY_INDEXES"],
              let documentID = env["HAMII_AUTO_RECOVERY_DOCUMENT"],
              let scopeID = env["HAMII_AUTO_RECOVERY_SCOPE"],
              let attemptPath = env["HAMII_AUTO_RECOVERY_ATTEMPT"],
              let resultPath = env["HAMII_AUTO_RECOVERY_RESULT"] else {
            throw XCTSkip("Writer contention worker only")
        }
        let fixture = Fixture(root: URL(fileURLWithPath: project), indexRoot: URL(fileURLWithPath: indexes),
            documentID: EntityID(documentID), scopeID: EntityID(scopeID))
        try Data().write(to: URL(fileURLWithPath: attemptPath))
        let started = ProcessInfo.processInfo.systemUptime
        let acquired = try WorktreeCoordinator(root: fixture.root).withReadyExclusive {
            ProcessInfo.processInfo.systemUptime
        }
        try saveComponent(fixture, as: "Gamma")
        let duration = (ProcessInfo.processInfo.systemUptime - started) * 1_000
        let wait = (acquired - started) * 1_000
        try JSONEncoder().encode(["operationMilliseconds": duration,
                                  "preSaveLockWaitMilliseconds": wait])
            .write(to: URL(fileURLWithPath: resultPath), options: .atomic)
    }

    func testWriterWaitWhileRecoveryBuildsUnderAndOutsideLock() throws {
        guard let resultPath = ProcessInfo.processInfo.environment["HAMII_AUTO_REBUILD_WRITER_WAIT_RESULT"] else {
            throw XCTSkip("Set HAMII_AUTO_REBUILD_WRITER_WAIT_RESULT to measure contention")
        }
        var results: [[String: String]] = []
        for strategy in ["lockHeld", "twoPhase", "optimizedTwoPhase"] {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let source = try capture(fixture)
            let candidate = try build(fixture, from: source)
            try publish(fixture, source: source, candidate: candidate)
            try? FileManager.default.removeItem(at: candidate.root)
            try saveComponent(fixture, as: "Beta")
            let release = fixture.directory.appendingPathComponent("release-\(strategy)")
            let ready = fixture.directory.appendingPathComponent("ready-\(strategy)")
            let recoveryResult = fixture.directory.appendingPathComponent("recovery-\(strategy)")
            let recovery = try child("testContendingRecoveryWorker", environment: [
                "HAMII_AUTO_RECOVERY_PROJECT": fixture.root.path,
                "HAMII_AUTO_RECOVERY_INDEXES": fixture.indexRoot.path,
                "HAMII_AUTO_RECOVERY_DOCUMENT": fixture.documentID.rawValue,
                "HAMII_AUTO_RECOVERY_SCOPE": fixture.scopeID.rawValue,
                "HAMII_AUTO_RECOVERY_STRATEGY": strategy,
                "HAMII_AUTO_RECOVERY_READY": ready.path,
                "HAMII_AUTO_RECOVERY_RELEASE": release.path,
                "HAMII_AUTO_RECOVERY_RESULT": recoveryResult.path
            ])
            try awaitFile(ready, process: recovery)
            let writerAttempt = fixture.directory.appendingPathComponent("writer-attempt-\(strategy)")
            let writerResult = fixture.directory.appendingPathComponent("writer-result-\(strategy).json")
            let writer = try child("testContendingWriterWorker", environment: [
                "HAMII_AUTO_RECOVERY_PROJECT": fixture.root.path,
                "HAMII_AUTO_RECOVERY_INDEXES": fixture.indexRoot.path,
                "HAMII_AUTO_RECOVERY_DOCUMENT": fixture.documentID.rawValue,
                "HAMII_AUTO_RECOVERY_SCOPE": fixture.scopeID.rawValue,
                "HAMII_AUTO_RECOVERY_ATTEMPT": writerAttempt.path,
                "HAMII_AUTO_RECOVERY_RESULT": writerResult.path
            ])
            try awaitFile(writerAttempt, process: writer)
            if strategy == "lockHeld" {
                Thread.sleep(forTimeInterval: 0.15)
                XCTAssertFalse(FileManager.default.fileExists(atPath: writerResult.path))
            } else {
                try awaitFile(writerResult, process: writer)
                XCTAssertFalse(FileManager.default.fileExists(atPath: release.path))
            }
            try Data().write(to: release)
            try awaitFile(recoveryResult, process: recovery)
            try awaitFile(writerResult, process: writer)
            recovery.waitUntilExit()
            writer.waitUntilExit()
            let recoveryOutput = (recovery.standardOutput as? Pipe)?
                .fileHandleForReading.readDataToEndOfFile() ?? Data()
            let writerOutput = (writer.standardOutput as? Pipe)?
                .fileHandleForReading.readDataToEndOfFile() ?? Data()
            XCTAssertEqual(recovery.terminationStatus, 0,
                "\(strategy) recovery: \(String(decoding: recoveryOutput, as: UTF8.self))")
            XCTAssertEqual(writer.terminationStatus, 0,
                "\(strategy) writer: \(String(decoding: writerOutput, as: UTF8.self))")
            let outcome = try String(contentsOf: recoveryResult, encoding: .utf8)
            XCTAssertEqual(outcome, strategy == "lockHeld" ? "published" : "stale")
            XCTAssertEqual(try CanonicalRepository(root: fixture.root).load().components.map(\.name),
                ["Gamma"])
            XCTAssertThrowsError(try query(fixture, with: session(fixture)))
            let sample = try JSONDecoder().decode([String: Double].self,
                from: Data(contentsOf: writerResult))
            results.append(["strategy": strategy, "writerCompletedBeforeRecoveryRelease":
                strategy == "lockHeld" ? "false" : "true", "recoveryOutcome": outcome,
                "writerOperationMilliseconds": String(try XCTUnwrap(sample["operationMilliseconds"])),
                "preSaveLockWaitMilliseconds": String(try XCTUnwrap(sample["preSaveLockWaitMilliseconds"]))])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: URL(fileURLWithPath: resultPath), options: .atomic)
    }
}
