import Foundation
import SQLite3
import HamiiCore

public enum IndexError: Error, CustomStringConvertible {
    case sqlite(String)
    case stale
    public var description: String {
        switch self {
        case .sqlite(let message): return "SQLite index: \(message)"
        case .stale: return "Local index is missing or stale; run hamii index rebuild"
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
    public static let schemaVersion = 3
    public let url: URL
    private var database: OpaquePointer?

    public init(projectRoot: URL) throws {
        let local = projectRoot.appendingPathComponent(".hamii", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        url = local.appendingPathComponent("index.sqlite")
        if sqlite3_open(url.path, &database) != SQLITE_OK { throw IndexError.sqlite("Could not open index") }
        if try currentSchemaVersion() != Self.schemaVersion {
            sqlite3_close(database)
            database = nil
            try? FileManager.default.removeItem(at: url)
            if sqlite3_open(url.path, &database) != SQLITE_OK { throw IndexError.sqlite("Could not recreate index") }
        }
        try execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS components (id TEXT PRIMARY KEY, name TEXT NOT NULL, owner_scope_id TEXT NOT NULL, usage_count INTEGER NOT NULL)")
        try execute("CREATE INDEX IF NOT EXISTS components_name ON components(name)")
        try execute("CREATE TABLE IF NOT EXISTS scope_closure (consumer_id TEXT NOT NULL, ancestor_id TEXT NOT NULL, PRIMARY KEY(consumer_id, ancestor_id))")
        try execute("CREATE TABLE IF NOT EXISTS component_availability (consumer_id TEXT NOT NULL, component_id TEXT NOT NULL, PRIMARY KEY(consumer_id, component_id))")
        try execute("PRAGMA user_version = \(Self.schemaVersion)")
    }

    deinit { sqlite3_close(database) }

    public func rebuild(from document: Document, sourceFingerprint: String) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try execute("DELETE FROM components")
            try execute("DELETE FROM scope_closure")
            try execute("DELETE FROM component_availability")
            try execute("DELETE FROM metadata")
            let scopes = ScopeEvaluator(document.scopes)
            let definitions = Dictionary(document.components.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for scope in document.scopes {
                for ancestor in scopes.ancestorsIncludingSelf(of: scope.id) ?? [] {
                    try insert("INSERT INTO scope_closure(consumer_id, ancestor_id) VALUES (?, ?)", [scope.id.rawValue, ancestor.rawValue])
                }
            }
            for component in document.components {
                let count = document.screens.reduce(0) { $0 + countInstances(of: component.id, in: $1.root) }
                try insert("INSERT INTO components(id, name, owner_scope_id, usage_count) VALUES (?, ?, ?, ?)", [component.id.rawValue, component.name, component.ownerScopeID.rawValue, String(count)])
                for scope in document.scopes where ComponentAvailability.reason(component, consumer: scope.id, scopes: scopes, definitions: definitions) == nil {
                    try insert("INSERT INTO component_availability(consumer_id, component_id) VALUES (?, ?)", [scope.id.rawValue, component.id.rawValue])
                }
            }
            try insert("INSERT INTO metadata(key, value) VALUES ('documentID', ?)", [document.id.rawValue])
            try insert("INSERT INTO metadata(key, value) VALUES ('revision', ?)", [String(document.revision)])
            try insert("INSERT INTO metadata(key, value) VALUES ('sourceFingerprint', ?)", [sourceFingerprint])
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func components(matching text: String, consumerScopeID: EntityID, documentID: EntityID, revision: Int, sourceFingerprint: String) throws -> [ComponentHit] {
        guard try metadata("documentID") == documentID.rawValue,
              try metadata("revision") == String(revision),
              try metadata("sourceFingerprint") == sourceFingerprint else { throw IndexError.stale }
        let sql = "SELECT c.id, c.name, c.owner_scope_id, c.usage_count FROM components c JOIN component_availability a ON a.component_id = c.id WHERE a.consumer_id = ? AND c.name LIKE ? ORDER BY c.name"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(consumerScopeID.rawValue, at: 1, to: statement)
        bind("%\(text)%", at: 2, to: statement)
        var hits: [ComponentHit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            hits.append(ComponentHit(id: EntityID(column(statement, 0)), name: column(statement, 1), ownerScopeID: EntityID(column(statement, 2)), usageCount: Int(sqlite3_column_int(statement, 3))))
        }
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

    private func countInstances(of componentID: EntityID, in layer: Layer) -> Int {
        let selfCount = layer.component?.definitionID == componentID ? 1 : 0
        return selfCount + layer.children.reduce(0) { $0 + countInstances(of: componentID, in: $1) }
    }
}
