import Foundation
import XCTest
import HamiiApplication
import HamiiCore
@testable import HamiiFormat
@testable import HamiiIndex

final class CanonicalGenerationIntegrationTests: XCTestCase {
    private struct Stopped: Error {}
    private struct FixedRevision: CanonicalRevisionCalculating {
        func current(at root: URL) throws -> CanonicalRevision { CanonicalRevision("fixture") }
    }
    private struct InterleavingBlobStore: BinaryObjectStore {
        let delegate: CanonicalBlobStore
        let interleave: () throws -> Void
        func put(_ data: Data) throws -> StoredBlob {
            let stored = try delegate.put(data)
            try interleave()
            return stored
        }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("hamii-generation-integration-\(UUID().uuidString)")
    }

    func testCreateSaveAndSameSourceIndexRebuildKeepDistinctGenerations() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CanonicalRepository(root: root)
        let created = try repository.create(name: "Generation")
        let store = CanonicalGenerationStore(root: root)
        let first = try store.readStable()
        XCTAssertEqual(first.generation.value, 1)
        XCTAssertEqual(first.snapshotIdentity, try repository.withCoordinatedSnapshot { $0.identity })

        let service = ProjectService(repository: repository)
        _ = try service.mutate(.createPage(name: "A"), expectedState: service.observe().statePrecondition, author: .human)
        let second = try store.readStable()
        XCTAssertEqual(second.generation.value, 2)
        XCTAssertEqual(second.generation.lineage, first.generation.lineage)
        XCTAssertNotEqual(second.snapshotIdentity, first.snapshotIdentity)

        let storage = root.deletingLastPathComponent().appendingPathComponent("hamii-index-fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storage) }
        let index = try LocalIndex(projectRoot: root, documentID: created.id,
                                   revisionCalculator: FixedRevision(), storageRoot: storage)
        let snapshot = try repository.withCoordinatedSnapshot { $0 }
        let firstIndex = try index.rebuild(from: snapshot, canonicalRevision: CanonicalRevision("fixture"),
                                           sourceGenerationBinding: .bound(second.generation))
        let secondIndex = try index.rebuild(from: snapshot, canonicalRevision: CanonicalRevision("fixture"),
                                            sourceGenerationBinding: .bound(second.generation))
        XCTAssertNotEqual(firstIndex.id, secondIndex.id)
        XCTAssertEqual(firstIndex.sourceGenerationBinding, .bound(second.generation))
        XCTAssertEqual(secondIndex.sourceGenerationBinding, .bound(second.generation))
        XCTAssertEqual(try store.readStable(), second)
        XCTAssertEqual(try index.assertCurrent(documentID: created.id, revision: snapshot.document.revision,
                                               expectedSourceIdentity: snapshot.identity), secondIndex)
    }

    func testNormalSavePendingRecoversOldAndCommittedNewSnapshot() throws {
        for stop in [TransactionStep.prepared, .complete] {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            var armed = false
            let repository = CanonicalRepository(root: root) { step in
                if armed && String(describing: step) == String(describing: stop) { throw Stopped() }
            }
            _ = try repository.create(name: "Interrupted")
            let before = try CanonicalGenerationStore(root: root).readStable()
            let service = ProjectService(repository: repository)
            armed = true
            XCTAssertThrowsError(try service.mutate(.createPage(name: "After"),
                expectedState: service.observe().statePrecondition, author: .human))
            XCTAssertThrowsError(try CanonicalGenerationStore(root: root).readStable()) { error in
                guard case CanonicalGenerationError.pending = error else { return XCTFail("Wrong state: \(error)") }
            }
            armed = false
            let reopened = CanonicalRepository(root: root)
            let recovered = try reopened.observe()
            let stable = try CanonicalGenerationStore(root: root).readStable()
            XCTAssertEqual(stable.snapshotIdentity, try reopened.withCoordinatedSnapshot { $0.identity })
            if String(describing: stop) == String(describing: TransactionStep.prepared) {
                XCTAssertEqual(stable.generation, before.generation)
                XCTAssertTrue(recovered.document.pages.isEmpty)
            } else {
                XCTAssertEqual(stable.generation.value, before.generation.value + 1)
                XCTAssertEqual(recovered.document.pages.map(\.name), ["After"])
            }
        }
    }

    func testMissingRecordRequiresVerifiedBootstrapAndCorruptRecordFailsClosed() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CanonicalRepository(root: root)
        _ = try repository.create(name: "Bootstrap")
        let store = CanonicalGenerationStore(root: root)
        let old = try store.readStable()
        let record = root.appendingPathComponent(".hamii/canonical-generation.json")
        try FileManager.default.removeItem(at: record)
        XCTAssertThrowsError(try store.readStable()) { error in
            guard case CanonicalGenerationError.missing = error else { return XCTFail("Wrong state: \(error)") }
        }
        // Repository open performs full coordinated parse/validation before
        // creating a new lineage; it never treats the missing record as old N.
        _ = try CanonicalRepository(root: root).observe()
        let fresh = try store.readStable()
        XCTAssertNotEqual(old.generation.lineage, fresh.generation.lineage)
        XCTAssertEqual(fresh.snapshotIdentity, old.snapshotIdentity)
        try Data("broken".utf8).write(to: record)
        XCTAssertThrowsError(try CanonicalRepository(root: root).observe())
    }

    func testDerivedRecoveryCaptureDoesNotBootstrapOrReconcileGeneration() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CanonicalRepository(root: root)
        _ = try repository.create(name: "Strict capture")
        let record = root.appendingPathComponent(".hamii/canonical-generation.json")
        let original = try Data(contentsOf: record)
        let captured = try repository.withStableSnapshotForDerivedRecovery { snapshot, stable in
            XCTAssertEqual(snapshot.identity, stable.snapshotIdentity)
            return stable
        }
        XCTAssertEqual(try repository.withStableGenerationForDerivedRecovery { $0 }, captured)

        try FileManager.default.removeItem(at: record)
        XCTAssertThrowsError(try repository.withStableSnapshotForDerivedRecovery { _, _ in () }) { error in
            guard case CanonicalGenerationError.missing = error else { return XCTFail("Wrong state: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))

        try original.write(to: record)
        _ = try WorktreeCoordinator(root: root).withExclusive {
            try CanonicalGenerationStore(root: root).beginPending(old: captured,
                expectedNewIdentity: nil)
        }
        let pending = try Data(contentsOf: record)
        XCTAssertThrowsError(try repository.withStableSnapshotForDerivedRecovery { _, _ in () }) { error in
            guard case CanonicalGenerationError.pending = error else { return XCTFail("Wrong state: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: record), pending)
    }

    func testGenerationStoreUsesSameRecordForVarPathAliases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hamii-generation-alias-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try CanonicalRepository(root: root).create(name: "Alias")
        let alternatePath = root.path.hasPrefix("/var/") ? "/private" + root.path : root.path
        let alternate = URL(fileURLWithPath: alternatePath)
        XCTAssertEqual(try CanonicalGenerationStore(root: root).readStable(),
                       try CanonicalGenerationStore(root: alternate).readStable())
        XCTAssertEqual(try CanonicalRepository(root: root).withCoordinatedSnapshot { $0.identity },
                       try CanonicalRepository(root: alternate).withCoordinatedSnapshot { $0.identity })
    }

    func testAssetConflictAfterBlobWriteDoesNotAddAnotherCanonicalGeneration() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CanonicalRepository(root: root)
        let created = try repository.create(name: "Asset conflict")
        let service = ProjectService(repository: repository)
        let before = try service.observe()
        let generation = try CanonicalGenerationStore(root: root).readStable().generation
        let blobs = InterleavingBlobStore(delegate: CanonicalBlobStore(root: root)) {
            _ = try service.mutate(.createPage(name: "Other writer"),
                                   expectedState: service.observe().statePrecondition, author: .human)
        }
        XCTAssertThrowsError(try service.importRepositoryAsset(Data("orphan".utf8), name: "Avatar",
            scopeID: created.scopes[0].id, mediaType: "image/png", expectedState: before.statePrecondition,
            author: .human, blobs: blobs)) { error in
            guard case AuthoringError.staleState = error else { return XCTFail("Wrong error: \(error)") }
        }
        XCTAssertEqual(try CanonicalGenerationStore(root: root).readStable().generation.value, generation.value + 1)
        XCTAssertTrue(try repository.load().assets.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("assets/blobs").path).count, 1)
    }
}
