import CryptoKit
import Darwin
import Foundation
import SQLite3
import HamiiCore
import HamiiFormat

/// A read-only description of the published file. This is an expected-state
/// token for coordinated replacement, not a proof against raw external writes.
enum PublishedIndexState: Equatable {
    case missing
    case present(String)
}

enum PublishedIndexAssessment {
    case missing
    case obsolete
    case malformed
    case corrupt
    case valid(IndexGenerationDescriptor, CanonicalRevision)
}

struct PublishedIndexObservation {
    let state: PublishedIndexState
    let assessment: PublishedIndexAssessment
}

/// Never opens a published SQLite database for writing. Unknown I/O failures
/// are errors; they must not be converted into disposable-index corruption.
struct PublishedIndexProbe {
    func inspect(at url: URL) throws -> PublishedIndexObservation {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return PublishedIndexObservation(state: .missing, assessment: .missing) }
            throw IndexError.sqlite("Cannot inspect published Index path: POSIX code \(errno)")
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw IndexError.sqlite("Published Index path is not a regular file")
        }
        let bytes: Data
        do { bytes = try Data(contentsOf: url) }
        catch { throw IndexError.sqlite("Cannot read published Index file: \(error)") }
        let fingerprint = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let state = PublishedIndexState.present(fingerprint)
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil)
        defer { if let database { sqlite3_close(database) } }
        if opened == SQLITE_CORRUPT || opened == SQLITE_NOTADB {
            return PublishedIndexObservation(state: state, assessment: .corrupt)
        }
        guard opened == SQLITE_OK else {
            throw IndexError.sqlite("Cannot read published Index: SQLite code \(opened)")
        }
        do {
            let version = try rows("PRAGMA user_version", database: database)
            guard let value = Int(version.first?.first ?? "") else { throw ProbeIssue.corrupt }
            guard value == LocalIndex.schemaVersion else {
                return PublishedIndexObservation(state: state, assessment: .obsolete)
            }
            let integrity = try rows("PRAGMA integrity_check", database: database)
            guard integrity == [["ok"]] else { throw ProbeIssue.corrupt }
            // An intact SQLite file can still have an incomplete schema.
            _ = try rows("SELECT id, name, owner_scope_id, usage_count FROM components LIMIT 0", database: database)
            _ = try rows("SELECT consumer_id, ancestor_id FROM scope_closure LIMIT 0", database: database)
            _ = try rows("SELECT consumer_id, component_id FROM component_availability LIMIT 0", database: database)
            let pairs = try rows("SELECT key, value FROM metadata", database: database)
            let metadata = Dictionary(pairs.compactMap { row -> (String, String)? in
                row.count == 2 ? (row[0], row[1]) : nil
            }, uniquingKeysWith: { first, _ in first })
            guard let documentID = metadata["documentID"], !documentID.isEmpty,
                  let revision = Int(metadata["revision"] ?? ""), revision >= 0,
                  let generationID = IndexGenerationID(rawValue: metadata["indexGenerationID"] ?? ""),
                  let identity = CanonicalSnapshotIdentity(rawValue: metadata["sourceCanonicalIdentity"] ?? ""),
                  let binding = IndexSourceGenerationBinding(serialized: metadata["sourceGenerationBinding"] ?? ""),
                  let source = metadata["canonicalRevision"], !source.isEmpty else {
                throw ProbeIssue.malformed
            }
            let descriptor = IndexGenerationDescriptor(id: generationID,
                sourceCanonicalIdentity: identity, documentID: EntityID(documentID),
                documentRevision: revision, sourceGenerationBinding: binding)
            return PublishedIndexObservation(state: state,
                assessment: .valid(descriptor, CanonicalRevision(source)))
        } catch ProbeIssue.corrupt {
            return PublishedIndexObservation(state: state, assessment: .corrupt)
        } catch ProbeIssue.malformed {
            return PublishedIndexObservation(state: state, assessment: .malformed)
        }
    }

    private enum ProbeIssue: Error { case corrupt, malformed }

    private func rows(_ sql: String, database: OpaquePointer?) throws -> [[String]] {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        defer { if let statement { sqlite3_finalize(statement) } }
        if prepared == SQLITE_CORRUPT || prepared == SQLITE_NOTADB { throw ProbeIssue.corrupt }
        guard prepared == SQLITE_OK else {
            if prepared == SQLITE_ERROR {
                throw ProbeIssue.malformed
            }
            throw IndexError.sqlite("Cannot inspect published Index: SQLite code \(prepared)")
        }
        var result: [[String]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            if step == SQLITE_CORRUPT || step == SQLITE_NOTADB { throw ProbeIssue.corrupt }
            guard step == SQLITE_ROW else {
                throw IndexError.sqlite("Cannot read published Index: SQLite code \(step)")
            }
            result.append((0..<sqlite3_column_count(statement)).map { column in
                guard let value = sqlite3_column_text(statement, column) else { return "" }
                return String(cString: value)
            })
        }
    }
}
