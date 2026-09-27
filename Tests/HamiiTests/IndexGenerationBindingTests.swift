import Foundation
import SQLite3
import XCTest
import HamiiCore
@testable import HamiiFormat
@testable import HamiiIndex

final class IndexGenerationBindingTests: XCTestCase {
    private struct FixedRevision: CanonicalRevisionCalculating {
        func current(at root: URL) throws -> CanonicalRevision { CanonicalRevision("fixed-source") }
    }

    private func withFixture(_ body: (URL, CanonicalRepository, CanonicalSnapshot, LocalIndex, EntityID) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hamii-index-binding-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CanonicalRepository(root: root)
        var document = try repository.create(name: "Index binding")
        let created = document
        let scope = try XCTUnwrap(document.scopes.first?.id)
        document.components = [ComponentDefinition(id: EntityID("component_button"), name: "Button", ownerScopeID: scope,
            root: Layer(id: EntityID("layer_button"), kind: .stack, name: "Root"))]
        document.revision = 1
        try repository.save(document, expected: created)
        let snapshot = try repository.withCoordinatedSnapshot { $0 }
        let index = try LocalIndex(projectRoot: root, documentID: document.id, revisionCalculator: FixedRevision(),
                                   storageRoot: root.appendingPathComponent("derived-indexes"))
        try body(root, repository, snapshot, index, scope)
    }

    private func execute(_ sql: String, at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw IndexError.sqlite("open test database") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw IndexError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func hits(_ index: LocalIndex, _ snapshot: CanonicalSnapshot, scope: EntityID) throws -> [ComponentHit] {
        try index.components(matching: "Button", consumerScopeID: scope, documentID: snapshot.document.id,
                             revision: snapshot.document.revision, expectedSourceIdentity: snapshot.identity)
    }

    func testRebuildIssuesNewGenerationForSameCanonicalSnapshot() throws {
        try withFixture { _, _, snapshot, index, scope in
            let first = try index.rebuild(from: snapshot, canonicalRevision: CanonicalRevision("fixed-source"))
            let second = try index.rebuild(from: snapshot, canonicalRevision: CanonicalRevision("fixed-source"))
            XCTAssertNotEqual(first.id, second.id)
            XCTAssertEqual(first.sourceCanonicalIdentity, second.sourceCanonicalIdentity)
            XCTAssertEqual(second.sourceCanonicalIdentity, snapshot.identity)
            XCTAssertEqual(try index.assertCurrent(documentID: snapshot.document.id,
                revision: snapshot.document.revision, expectedSourceIdentity: snapshot.identity), second)
            XCTAssertEqual(try hits(index, snapshot, scope: scope).map(\.name), ["Button"])
        }
    }

    func testMissingMalformedAndMismatchedGenerationMetadataRejectQuery() throws {
        try withFixture { _, repository, snapshot, index, scope in
            let source = CanonicalRevision("fixed-source")
            func expectStale() {
                XCTAssertThrowsError(try hits(index, snapshot, scope: scope)) { error in
                    guard case IndexError.stale = error else { return XCTFail("Expected staleIndex: \(error)") }
                }
            }
            try index.rebuild(from: snapshot, canonicalRevision: source)
            try execute("DELETE FROM metadata WHERE key='indexGenerationID'", at: index.url)
            expectStale()
            try index.rebuild(from: snapshot, canonicalRevision: source)
            try execute("UPDATE metadata SET value='not-a-uuid' WHERE key='indexGenerationID'", at: index.url)
            expectStale()
            try index.rebuild(from: snapshot, canonicalRevision: source)
            try execute("DELETE FROM metadata WHERE key='sourceCanonicalIdentity'", at: index.url)
            expectStale()
            try index.rebuild(from: snapshot, canonicalRevision: source)
            try execute("UPDATE metadata SET value='broken' WHERE key='sourceCanonicalIdentity'", at: index.url)
            expectStale()
            try index.rebuild(from: snapshot, canonicalRevision: source)
            let wrong = CanonicalSnapshotIdentity(rawValue: String(repeating: "a", count: 64))!
            XCTAssertNotEqual(wrong, snapshot.identity)
            XCTAssertThrowsError(try index.components(matching: "Button", consumerScopeID: scope,
                documentID: snapshot.document.id, revision: snapshot.document.revision,
                expectedSourceIdentity: wrong)) { error in
                    guard case IndexError.stale = error else { return XCTFail("Expected staleIndex: \(error)") }
            }
            let componentFile = repository.root.appendingPathComponent("components/component_button.json")
            var bytes = try Data(contentsOf: componentFile)
            bytes.append(0x0A)
            try bytes.write(to: componentFile)
            let changed = try repository.withCoordinatedSnapshot { $0 }
            XCTAssertNotEqual(changed.identity, snapshot.identity)
            XCTAssertThrowsError(try hits(index, changed, scope: scope)) { error in
                guard case IndexError.stale = error else { return XCTFail("Expected staleIndex: \(error)") }
            }
        }
    }

    func testMetadataWriteFailureRollsBackRowsAndGenerationTogether() throws {
        try withFixture { _, _, snapshot, index, scope in
            let source = CanonicalRevision("fixed-source")
            let first = try index.rebuild(from: snapshot, canonicalRevision: source)
            try execute("CREATE TRIGGER reject_source BEFORE INSERT ON metadata WHEN NEW.key='sourceCanonicalIdentity' BEGIN SELECT RAISE(ABORT, 'injected'); END", at: index.url)
            XCTAssertThrowsError(try index.rebuild(from: snapshot, canonicalRevision: source))
            XCTAssertEqual(try index.assertCurrent(documentID: snapshot.document.id,
                revision: snapshot.document.revision, expectedSourceIdentity: snapshot.identity), first)
            XCTAssertEqual(try hits(index, snapshot, scope: scope).map(\.name), ["Button"])
        }
    }

    func testOldDisposableSchemaIsRecreatedWithoutMigration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hamii-index-schema-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CanonicalRepository(root: root)
        let document = try repository.create(name: "Schema")
        let snapshot = try repository.withCoordinatedSnapshot { $0 }
        let storage = root.appendingPathComponent("derived-indexes")
        let url: URL
        do {
            let index = try LocalIndex(projectRoot: root, documentID: document.id,
                revisionCalculator: FixedRevision(), storageRoot: storage)
            try index.rebuild(from: snapshot, canonicalRevision: CanonicalRevision("fixed-source"))
            url = index.url
        }
        try execute("PRAGMA user_version = 5", at: url)
        let reopened = try LocalIndex(projectRoot: root, documentID: document.id,
            revisionCalculator: FixedRevision(), storageRoot: storage)
        XCTAssertThrowsError(try reopened.assertCurrent(documentID: document.id,
            revision: document.revision, expectedSourceIdentity: snapshot.identity)) { error in
                guard case IndexError.stale = error else { return XCTFail("Expected staleIndex: \(error)") }
            }
        try reopened.rebuild(from: snapshot, canonicalRevision: CanonicalRevision("fixed-source"))
        XCTAssertNoThrow(try reopened.assertCurrent(documentID: document.id,
            revision: document.revision, expectedSourceIdentity: snapshot.identity))
    }
}
