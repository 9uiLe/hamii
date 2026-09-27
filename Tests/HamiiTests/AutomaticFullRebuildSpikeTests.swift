import Darwin
import Foundation
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

    private struct TimingRecord: Codable {
        let components: Int
        let strategy: String
        let snapshotAndRevisionMS: Double
        let candidateBuildMS: Double
        let publicationMS: Double
        let lockHeldMS: Double
        let firstQueryMS: Double
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

    private func build(_ fixture: Fixture, from source: Source) throws -> Candidate {
        let root = fixture.directory.appendingPathComponent("Candidate-\(UUID().uuidString)")
        let descriptor: IndexGenerationDescriptor
        let candidateURL: URL
        do {
            let candidate = try index(fixture, storageRoot: root)
            descriptor = try candidate.rebuild(from: source.snapshot, canonicalRevision: source.revision,
                sourceGenerationBinding: .bound(source.stable.generation))
            candidateURL = candidate.url
            XCTAssertEqual(try candidate.assertCurrent(documentID: fixture.documentID,
                revision: source.snapshot.document.revision,
                expectedSourceIdentity: source.snapshot.identity), descriptor)
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
            for strategy in ["lockHeld", "twoPhase"] {
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
                    } else {
                        source = try capture(fixture)
                        captured = now()
                        candidate = try build(fixture, from: source)
                        built = now()
                        try publish(fixture, source: source, candidate: candidate)
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
                        firstQueryMS: ms(queryStarted, queried)))
                    _ = source
                }
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }
}
