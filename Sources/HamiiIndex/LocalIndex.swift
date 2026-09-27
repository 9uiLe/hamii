import Foundation
import SQLite3
import HamiiCore
import HamiiFormat

public enum IndexError: Error, CustomStringConvertible {
    case sqlite(String)
    case stale
    case unverifiableSource
    public var description: String {
        switch self {
        case .sqlite(let message): return "SQLite index: \(message)"
        case .stale: return "Local index is missing or stale; run hamii index rebuild"
        case .unverifiableSource: return "Cannot verify Canonical Git state; use a Git worktree and clear assume-unchanged/skip-worktree flags or Git filters before rebuilding the index"
        }
    }
}

public struct ComponentHit: Codable, Equatable {
    public var id: EntityID
    public var name: String
    public var ownerScopeID: EntityID
    public var usageCount: Int
}

public final class LocalIndex {
    public static let schemaVersion = 8
    public let url: URL
    private let projectRoot: URL
    private let revisionCalculator: any CanonicalRevisionCalculating
    private var database: OpaquePointer?

    public init(projectRoot: URL, documentID: EntityID, revisionCalculator: any CanonicalRevisionCalculating, storageRoot: URL? = nil) throws {
        self.projectRoot = projectRoot.standardizedFileURL
        self.revisionCalculator = revisionCalculator
        url = LocalIndexLocation.url(projectRoot: projectRoot, documentID: documentID, storageRoot: storageRoot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if sqlite3_open(url.path, &database) != SQLITE_OK { throw IndexError.sqlite("Could not open index") }
        if try currentSchemaVersion() != Self.schemaVersion {
            sqlite3_close(database)
            database = nil
            try? FileManager.default.removeItem(at: url)
            if sqlite3_open(url.path, &database) != SQLITE_OK { throw IndexError.sqlite("Could not recreate index") }
        }
        _ = sqlite3_busy_timeout(database, 5_000)
        try execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS components (id TEXT PRIMARY KEY, name TEXT NOT NULL, owner_scope_id TEXT NOT NULL, usage_count INTEGER NOT NULL)")
        try execute("CREATE INDEX IF NOT EXISTS components_name ON components(name)")
        try execute("CREATE TABLE IF NOT EXISTS scope_closure (consumer_id TEXT NOT NULL, ancestor_id TEXT NOT NULL, PRIMARY KEY(consumer_id, ancestor_id))")
        try execute("CREATE TABLE IF NOT EXISTS component_availability (consumer_id TEXT NOT NULL, component_id TEXT NOT NULL, PRIMARY KEY(consumer_id, component_id))")
        try execute("PRAGMA user_version = \(Self.schemaVersion)")
    }

    deinit { sqlite3_close(database) }

    @discardableResult
    public func rebuild(from snapshot: CanonicalSnapshot, canonicalRevision: CanonicalRevision,
                        sourceGenerationBinding: IndexSourceGenerationBinding = .explicitlyUnbound) throws -> IndexGenerationDescriptor {
        try rebuild(from: snapshot, canonicalRevision: canonicalRevision,
                    sourceGenerationBinding: sourceGenerationBinding, transactionHook: nil)
    }

    // Internal stop point for process-crash regression tests. The public
    // rebuild contract never exposes a partially committed transaction.
    @discardableResult
    func rebuild(from snapshot: CanonicalSnapshot, canonicalRevision: CanonicalRevision,
                 sourceGenerationBinding: IndexSourceGenerationBinding = .explicitlyUnbound,
                 transactionHook: (() throws -> Void)?) throws -> IndexGenerationDescriptor {
        let document = snapshot.document
        let generation = IndexGenerationDescriptor(id: .new(), sourceCanonicalIdentity: snapshot.identity,
                                                   documentID: document.id, documentRevision: document.revision,
                                                   sourceGenerationBinding: sourceGenerationBinding)
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try execute("DELETE FROM components")
            try execute("DELETE FROM scope_closure")
            try execute("DELETE FROM component_availability")
            try execute("DELETE FROM metadata")
            let projection = IndexProjection(document: document)
            for row in projection.scopeClosure {
                try insert("INSERT INTO scope_closure(consumer_id, ancestor_id) VALUES (?, ?)", [row.consumer.rawValue, row.ancestor.rawValue])
            }
            try transactionHook?()
            for row in projection.components {
                try insert("INSERT INTO components(id, name, owner_scope_id, usage_count) VALUES (?, ?, ?, ?)", [row.id.rawValue, row.name, row.ownerScopeID.rawValue, String(row.usageCount)])
            }
            for row in projection.availability {
                try insert("INSERT INTO component_availability(consumer_id, component_id) VALUES (?, ?)", [row.consumer.rawValue, row.component.rawValue])
            }
            try insert("INSERT INTO metadata(key, value) VALUES ('documentID', ?)", [document.id.rawValue])
            try insert("INSERT INTO metadata(key, value) VALUES ('revision', ?)", [String(document.revision)])
            try insert("INSERT INTO metadata(key, value) VALUES ('canonicalRevision', ?)", [canonicalRevision.rawValue])
            try insert("INSERT INTO metadata(key, value) VALUES ('indexGenerationID', ?)", [generation.id.rawValue])
            try insert("INSERT INTO metadata(key, value) VALUES ('sourceCanonicalIdentity', ?)", [snapshot.identity.rawValue])
            try insert("INSERT INTO metadata(key, value) VALUES ('sourceGenerationBinding', ?)",
                       [sourceGenerationBinding.serialized])
            try execute("COMMIT")
            return generation
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func components(matching text: String, consumerScopeID: EntityID, documentID: EntityID,
                           revision: Int, expectedSourceIdentity: CanonicalSnapshotIdentity) throws -> [ComponentHit] {
        try execute("BEGIN DEFERRED TRANSACTION")
        do {
            let generation = try readGeneration()
            guard generation.documentID == documentID,
                  generation.documentRevision == revision,
                  let indexedRevision = try metadata("canonicalRevision") else { throw IndexError.stale }
            if generation.sourceCanonicalIdentity != expectedSourceIdentity {
                // Preserve a specific Git guard diagnostic for hidden flags or
                // filters even when the exact source identity is already stale.
                _ = try revisionCalculator.current(at: projectRoot)
                throw IndexError.stale
            }
            let hits = try readComponentRows(matching: text, consumerScopeID: consumerScopeID)
            guard try revisionCalculator.current(at: projectRoot).rawValue == indexedRevision else { throw IndexError.stale }
            try execute("COMMIT")
            return hits
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    @discardableResult
    public func assertCurrent(documentID: EntityID, revision: Int,
                              expectedSourceIdentity: CanonicalSnapshotIdentity) throws -> IndexGenerationDescriptor {
        try execute("BEGIN DEFERRED TRANSACTION")
        do {
            let generation = try readGeneration()
            guard generation.documentID == documentID,
                  generation.documentRevision == revision,
                  generation.sourceCanonicalIdentity == expectedSourceIdentity,
                  let indexedRevision = try metadata("canonicalRevision"),
                  try revisionCalculator.current(at: projectRoot).rawValue == indexedRevision else {
                throw IndexError.stale
            }
            try execute("COMMIT")
            return generation
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func readGeneration() throws -> IndexGenerationDescriptor {
        guard let documentID = try metadata("documentID"), !documentID.isEmpty,
              let revisionText = try metadata("revision"), let revision = Int(revisionText), revision >= 0,
              let idText = try metadata("indexGenerationID"), let id = IndexGenerationID(rawValue: idText),
              let sourceText = try metadata("sourceCanonicalIdentity"),
              let source = CanonicalSnapshotIdentity(rawValue: sourceText) else { throw IndexError.stale }
        guard let bindingText = try metadata("sourceGenerationBinding"),
              let binding = IndexSourceGenerationBinding(serialized: bindingText) else { throw IndexError.stale }
        return IndexGenerationDescriptor(id: id, sourceCanonicalIdentity: source,
                                         documentID: EntityID(documentID), documentRevision: revision,
                                         sourceGenerationBinding: binding)
    }

    // A descriptor read is not a Canonical freshness proof by itself.
    // IndexQuerySession combines it with coordinated generation evidence or
    // the slow Git oracle before returning rows.
    func publishedGeneration() throws -> IndexGenerationDescriptor {
        try execute("BEGIN DEFERRED TRANSACTION")
        do {
            let result = try readGeneration()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Query rows from the exact SQLite generation already proven current by
    /// an IndexQuerySession. The caller holds WorktreeCoordinator through this
    /// transaction; this method does not independently prove Canonical state.
    func components(matching text: String, consumerScopeID: EntityID,
                    verifiedGeneration: IndexGenerationDescriptor) throws -> [ComponentHit] {
        try execute("BEGIN DEFERRED TRANSACTION")
        do {
            guard try readGeneration() == verifiedGeneration else { throw IndexError.stale }
            let hits = try readComponentRows(matching: text, consumerScopeID: consumerScopeID)
            try execute("COMMIT")
            return hits
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func readComponentRows(matching text: String, consumerScopeID: EntityID) throws -> [ComponentHit] {
        let sql = "SELECT c.id, c.name, c.owner_scope_id, c.usage_count FROM components c JOIN component_availability a ON a.component_id = c.id WHERE a.consumer_id = ? AND c.name LIKE ? ORDER BY c.name"
        let statement = try prepare(sql)
        bind(consumerScopeID.rawValue, at: 1, to: statement)
        bind("%\(text)%", at: 2, to: statement)
        var hits: [ComponentHit] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            hits.append(ComponentHit(id: EntityID(column(statement, 0)), name: column(statement, 1),
                                     ownerScopeID: EntityID(column(statement, 2)),
                                     usageCount: Int(sqlite3_column_int(statement, 3))))
            step = sqlite3_step(statement)
        }
        if step != SQLITE_DONE {
            let message = String(cString: sqlite3_errmsg(database))
            sqlite3_finalize(statement)
            throw IndexError.sqlite(message)
        }
        sqlite3_finalize(statement)
        return hits
    }

    private func metadata(_ key: String) throws -> String? {
        let statement = try prepare("SELECT value FROM metadata WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        bind(key, at: 1, to: statement)
        return sqlite3_step(statement) == SQLITE_ROW ? column(statement, 0) : nil
    }

    private func currentSchemaVersion() throws -> Int {
        let statement = try prepare("PRAGMA user_version")
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : 0
    }

    private func execute(_ sql: String) throws {
        if sqlite3_exec(database, sql, nil, nil, nil) != SQLITE_OK { throw IndexError.sqlite(String(cString: sqlite3_errmsg(database))) }
    }

    private func insert(_ sql: String, _ values: [String]) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() { bind(value, at: Int32(index + 1), to: statement) }
        if sqlite3_step(statement) != SQLITE_DONE { throw IndexError.sqlite(String(cString: sqlite3_errmsg(database))) }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(database, sql, -1, &statement, nil) != SQLITE_OK { throw IndexError.sqlite(String(cString: sqlite3_errmsg(database))) }
        guard let statement else { throw IndexError.sqlite("Could not prepare statement") }
        return statement
    }

    private func bind(_ value: String, at position: Int32, to statement: OpaquePointer) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = sqlite3_bind_text(statement, position, value, -1, transient)
    }

    private func column(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

}
