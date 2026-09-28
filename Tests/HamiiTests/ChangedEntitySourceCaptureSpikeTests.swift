import CryptoKit
import Darwin
import Foundation
import SQLite3
import XCTest
import HamiiCore
@testable import HamiiFormat
@testable import HamiiIndex

/// Test-only source inventory. This is not the production LocalIndex schema or recovery path.
final class ChangedEntitySourceCaptureSpikeTests: XCTestCase {
    private enum ProbeFailure: Error { case sqlite(String), invalid(String) }

    private struct Entry: Codable, Equatable {
        let path: String
        let kind: String
        let id: String
        let digest: String
    }

    private struct Capture {
        let snapshot: CanonicalSnapshot
        let stable: StableCanonicalGeneration
        let entries: [Entry]
        let snapshotMilliseconds: Double
        let digestMilliseconds: Double
        let readCounts: [String: Int]
    }

    private struct EntityChange: Codable, Equatable, Hashable {
        let operation: String
        let kind: String
        let id: String
    }

    private struct ChangeSet: Codable {
        let fromIndexGenerationID: String
        let fromCanonicalIdentity: String
        let toCanonicalGeneration: String
        let toCanonicalIdentity: String
        let changes: [EntityChange]
    }

    private enum Decision {
        case changed(ChangeSet)
        case fullRebuild(String)
    }

    private final class Store {
        let url: URL
        private var db: OpaquePointer?

        init(url: URL) throws {
            self.url = url
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw ProbeFailure.sqlite("open") }
            try execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS projection_rows (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            // No UNIQUE(path): the reader must classify duplicate paths as corrupt input.
            try execute("CREATE TABLE IF NOT EXISTS source_inventory (path TEXT NOT NULL, kind TEXT NOT NULL, entity_id TEXT NOT NULL, digest TEXT NOT NULL)")
        }

        deinit { sqlite3_close(db) }

        func execute(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw ProbeFailure.sqlite(String(cString: sqlite3_errmsg(db)))
            }
        }

        private func insert(_ sql: String, _ values: [String]) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw ProbeFailure.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (offset, value) in values.enumerated() {
                guard sqlite3_bind_text(statement, Int32(offset + 1), value, -1, transient) == SQLITE_OK else {
                    throw ProbeFailure.sqlite("bind")
                }
            }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw ProbeFailure.sqlite(String(cString: sqlite3_errmsg(db)))
            }
        }

        func publish(_ capture: Capture, binding: IndexSourceGenerationBinding,
                     beforeCommit: (() throws -> Void)? = nil) throws -> IndexGenerationDescriptor {
            let snapshot = capture.snapshot
            let projectionRows = Self.rows(snapshot.document)
            let descriptor = IndexGenerationDescriptor(id: .new(), sourceCanonicalIdentity: snapshot.identity,
                documentID: snapshot.document.id, documentRevision: snapshot.document.revision,
                sourceGenerationBinding: binding)
            try execute("BEGIN IMMEDIATE TRANSACTION")
            do {
                try execute("DELETE FROM metadata")
                try execute("DELETE FROM projection_rows")
                try execute("DELETE FROM source_inventory")
                for (key, value) in projectionRows {
                    try insert("INSERT INTO projection_rows(key,value) VALUES (?,?)", [key, value])
                }
                for entry in capture.entries {
                    try insert("INSERT INTO source_inventory(path,kind,entity_id,digest) VALUES (?,?,?,?)",
                               [entry.path, entry.kind, entry.id, entry.digest])
                }
                let metadata = [
                    "indexGenerationID": descriptor.id.rawValue,
                    "sourceCanonicalIdentity": snapshot.identity.rawValue,
                    "documentID": snapshot.document.id.rawValue,
                    "documentRevision": String(snapshot.document.revision),
                    "sourceGenerationBinding": binding.serialized,
                    "indexSchemaVersion": String(LocalIndex.schemaVersion),
                    "projectionDigest": Self.rowDigest(projectionRows),
                    "inventoryVersion": "1",
                    "inventoryIndexGenerationID": descriptor.id.rawValue,
                    "inventorySourceCanonicalIdentity": snapshot.identity.rawValue,
                    "inventoryDigest": Self.inventoryDigest(capture.entries),
                    "inventoryCount": String(capture.entries.count)
                ]
                for (key, value) in metadata {
                    try insert("INSERT INTO metadata(key,value) VALUES (?,?)", [key, value])
                }
                try beforeCommit?()
                try execute("COMMIT")
                return descriptor
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }

        func read(onInventoryRead: ((Double) -> Void)? = nil) throws -> (IndexGenerationDescriptor, [Entry])? {
            let started = ProcessInfo.processInfo.systemUptime
            var metadata: [String: String] = [:]
            try each("SELECT key,value FROM metadata") { columns in metadata[columns[0]] = columns[1] }
            guard let generationText = metadata["indexGenerationID"],
                  let generation = IndexGenerationID(rawValue: generationText),
                  let identityText = metadata["sourceCanonicalIdentity"],
                  let identity = CanonicalSnapshotIdentity(rawValue: identityText),
                  let documentText = metadata["documentID"], !documentText.isEmpty,
                  let revisionText = metadata["documentRevision"], let revision = Int(revisionText),
                  let bindingText = metadata["sourceGenerationBinding"],
                  let binding = IndexSourceGenerationBinding(serialized: bindingText),
                  metadata["indexSchemaVersion"] == String(LocalIndex.schemaVersion),
                  let expectedProjectionDigest = metadata["projectionDigest"],
                  metadata["inventoryVersion"] == "1",
                  metadata["inventoryIndexGenerationID"] == generation.rawValue,
                  metadata["inventorySourceCanonicalIdentity"] == identity.rawValue,
                  let expectedDigest = metadata["inventoryDigest"],
                  let countText = metadata["inventoryCount"], let count = Int(countText) else { return nil }
            var entries: [Entry] = []
            try each("SELECT path,kind,entity_id,digest FROM source_inventory") { columns in
                entries.append(Entry(path: columns[0], kind: columns[1], id: columns[2], digest: columns[3]))
            }
            guard count == entries.count, Set(entries.map(\.path)).count == entries.count,
                  entries.allSatisfy(Self.validEntry),
                  Self.inventoryDigest(entries) == expectedDigest else { return nil }
            onInventoryRead?((ProcessInfo.processInfo.systemUptime - started) * 1_000)
            var projectionRows: [String: String] = [:]
            try each("SELECT key,value FROM projection_rows") { columns in projectionRows[columns[0]] = columns[1] }
            guard Self.rowDigest(projectionRows) == expectedProjectionDigest else { return nil }
            return (IndexGenerationDescriptor(id: generation, sourceCanonicalIdentity: identity,
                documentID: EntityID(documentText), documentRevision: revision,
                sourceGenerationBinding: binding), entries)
        }

        func projectionRows() throws -> [String: String] {
            var rows: [String: String] = [:]
            try each("SELECT key,value FROM projection_rows") { columns in rows[columns[0]] = columns[1] }
            return rows
        }

        private func each(_ sql: String, _ body: ([String]) -> Void) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw ProbeFailure.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return }
                guard status == SQLITE_ROW else { throw ProbeFailure.sqlite(String(cString: sqlite3_errmsg(db))) }
                body((0..<sqlite3_column_count(statement)).map { index in
                    guard let value = sqlite3_column_text(statement, index) else { return "" }
                    return String(cString: value)
                })
            }
        }

        static func rows(_ document: Document) -> [String: String] {
            let projection = IndexProjection(document: document)
            var rows: [String: String] = [:]
            for row in projection.components {
                rows["component:\(row.id.rawValue)"] = "\(row.name)|\(row.ownerScopeID.rawValue)|\(row.usageCount)"
            }
            for row in projection.scopeClosure {
                rows["closure:\(row.consumer.rawValue):\(row.ancestor.rawValue)"] = "1"
            }
            for row in projection.availability {
                rows["availability:\(row.consumer.rawValue):\(row.component.rawValue)"] = "1"
            }
            return rows
        }

        static func inventoryDigest(_ entries: [Entry]) -> String {
            var hash = SHA256()
            for entry in entries.sorted(by: { $0.path < $1.path }) {
                for field in [entry.path, entry.kind, entry.id, entry.digest] {
                    let bytes = Data(field.utf8)
                    var count = UInt64(bytes.count).bigEndian
                    withUnsafeBytes(of: &count) { hash.update(data: $0) }
                    hash.update(data: bytes)
                }
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }

        static func rowDigest(_ rows: [String: String]) -> String {
            var hash = SHA256()
            for (key, value) in rows.sorted(by: { $0.key < $1.key }) {
                for field in [key, value] {
                    let bytes = Data(field.utf8)
                    var count = UInt64(bytes.count).bigEndian
                    withUnsafeBytes(of: &count) { hash.update(data: $0) }
                    hash.update(data: bytes)
                }
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }

        private static func validEntry(_ entry: Entry) -> Bool {
            guard entry.path == "hamii.json" || entry.path == "hamii-agent-profiles.json" ||
                    entry.path.hasSuffix(".json"),
                  entry.digest.utf8.count == 64,
                  entry.digest.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) else { return false }
            let classified = classify(entry.path)
            return entry.kind == classified.kind && entry.id == classified.id
        }
    }

    private static func classify(_ path: String) -> (kind: String, id: String) {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, ["components", "scopes", "screens"].contains(String(parts[0])),
              parts[1].hasSuffix(".json") else { return ("other", "") }
        return (String(parts[0]), String(parts[1].dropLast(5)))
    }

    private func capture(_ repository: CanonicalRepository) throws -> Capture {
        try repository.withStableSinglePassProbe(captureFileDigests: true) { probe, stable in
            let entries = probe.fileDigests.map { path, digest -> Entry in
                let classification = Self.classify(path)
                return Entry(path: path, kind: classification.kind, id: classification.id, digest: digest)
            }.sorted { $0.path < $1.path }
            return Capture(snapshot: probe.snapshot, stable: stable, entries: entries,
                snapshotMilliseconds: probe.milliseconds["snapshotTotal"] ?? 0,
                digestMilliseconds: probe.digestMilliseconds, readCounts: probe.readCounts)
        }
    }

    private func decision(_ store: Store, current: Capture) throws -> Decision {
        guard let loaded = try store.read() else { return .fullRebuild("invalidInventoryOrDescriptor") }
        return decide(loaded, current: current)
    }

    private func decide(_ loaded: (IndexGenerationDescriptor, [Entry]), current: Capture) -> Decision {
        let (descriptor, old) = loaded
        guard case .bound(let sourceGeneration) = descriptor.sourceGenerationBinding else { return .fullRebuild("unbound") }
        guard sourceGeneration.lineage == current.stable.generation.lineage,
              sourceGeneration.value <= current.stable.generation.value else {
            return .fullRebuild("generationMismatch")
        }
        guard descriptor.documentID == current.snapshot.document.id else { return .fullRebuild("documentMismatch") }
        let oldPaths = Dictionary(uniqueKeysWithValues: old.map { ($0.path, $0) })
        let newPaths = Dictionary(uniqueKeysWithValues: current.entries.map { ($0.path, $0) })
        let paths = Set(oldPaths.keys).union(newPaths.keys)
        var changes: [EntityChange] = []
        for path in paths.sorted() where oldPaths[path] != newPaths[path] {
            if path == "hamii.json" { continue } // v1 IndexProjection does not read manifest fields; documentID checked above.
            let source = newPaths[path] ?? oldPaths[path]!
            guard source.kind != "other" else { return .fullRebuild("unsupportedCanonicalInput") }
            let operation = oldPaths[path] == nil ? "added" : newPaths[path] == nil ? "deleted" : "modified"
            changes.append(EntityChange(operation: operation, kind: source.kind, id: source.id))
        }
        return .changed(ChangeSet(fromIndexGenerationID: descriptor.id.rawValue,
            fromCanonicalIdentity: descriptor.sourceCanonicalIdentity.rawValue,
            toCanonicalGeneration: current.stable.generation.serialized,
            toCanonicalIdentity: current.snapshot.identity.rawValue, changes: changes))
    }

    private func remainsCurrent(_ set: ChangeSet, at repository: CanonicalRepository) throws -> Bool {
        let now = try capture(repository)
        return now.stable.generation.serialized == set.toCanonicalGeneration &&
               now.snapshot.identity.rawValue == set.toCanonicalIdentity
    }

    private func fileBytes(_ root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for url in try CanonicalRepository(root: root).canonicalJSONPaths() {
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            result[relative] = try Data(contentsOf: url)
        }
        return result
    }

    private func byteOracle(_ old: [String: Data], _ new: [String: Data]) -> [EntityChange] {
        Set(old.keys).union(new.keys).sorted().compactMap { path in
            guard old[path] != new[path], path != "hamii.json" else { return nil }
            let source = Self.classify(path)
            guard source.kind != "other" else { return nil }
            return EntityChange(operation: old[path] == nil ? "added" : new[path] == nil ? "deleted" : "modified",
                                kind: source.kind, id: source.id)
        }
    }

    private func fixture(componentCount: Int = 3, mixed: Bool = false) throws -> (URL, CanonicalRepository, Document) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hamii-source-capture-\(UUID().uuidString)")
        let root = directory.appendingPathComponent("Project")
        let repository = CanonicalRepository(root: root)
        let created = try repository.create(name: "Source capture")
        let app = created.scopes[0].id
        var document = created
        document.scopes.append(ArchitectureScope(id: EntityID("scope_child"), name: "Child", parentID: app))
        document.scopes.append(ArchitectureScope(id: EntityID("scope_leaf"), name: "Leaf", parentID: app))
        if mixed {
            for number in 0..<10 {
                document.scopes.append(ArchitectureScope(id: EntityID("scope_mixed_\(number)"), name: "Mixed \(number)", parentID: app))
            }
        }
        document.components = (0..<componentCount).map { number in
            ComponentDefinition(id: EntityID("component_\(number)"), name: "Component \(number)", ownerScopeID: app,
                root: Layer(id: EntityID("layer_\(number)"), kind: .stack, name: "Root"))
        }
        document.screens = [Screen(id: EntityID("screen_main"), name: "Main", scopeID: app,
            root: Layer(id: EntityID("screen_root"), kind: .stack, name: "Root", children: [
                Layer(id: EntityID("screen_instance_0"), kind: .componentInstance, name: "Instance",
                      component: ComponentInstance(definitionID: EntityID("component_0")))
            ]))]
        if mixed {
            for number in 0..<20 {
                document.screens.append(Screen(id: EntityID("screen_mixed_\(number)"), name: "Mixed \(number)", scopeID: app,
                    root: Layer(id: EntityID("screen_mixed_root_\(number)"), kind: .stack, name: "Root")))
            }
        }
        document.revision += 1
        try repository.save(document, expected: created)
        return (root, repository, document)
    }

    private func save(_ repository: CanonicalRepository, _ old: Document, _ update: (inout Document) -> Void) throws -> Document {
        var next = old
        update(&next)
        next.revision += 1
        try repository.save(next, expected: old)
        return next
    }

    private func makeStore(_ root: URL) throws -> Store {
        try Store(url: root.deletingLastPathComponent().appendingPathComponent("Indexes/source-inventory-\(UUID().uuidString).sqlite"))
    }

    private func changed(_ decision: Decision, file: StaticString = #filePath, line: UInt = #line) throws -> ChangeSet {
        guard case .changed(let set) = decision else {
            XCTFail("Expected changed source set", file: file, line: line)
            throw ProbeFailure.invalid("full rebuild")
        }
        return set
    }

    func testChangeMatrixAgainstExactBytesAndProjectionRows() throws {
        let scenarios = ["componentModify", "componentAvailability", "componentAdd", "componentDelete", "screenUsageAdd",
                         "screenUsageRemove", "scopeParentMove", "scopeAdd", "scopeDelete", "stableIDRename"]
        var reports: [[String: Any]] = []
        for scenario in scenarios {
            let (root, repository, oldDocument) = try fixture()
            defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
            let oldCapture = try capture(repository)
            XCTAssertTrue(oldCapture.readCounts.values.allSatisfy { $0 == 1 }, scenario)
            let oldBytes = try fileBytes(root)
            for entry in oldCapture.entries {
                let bytes = try XCTUnwrap(oldBytes[entry.path])
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                XCTAssertEqual(entry.digest, digest, entry.path)
            }
            let store = try makeStore(root)
            let descriptor = try store.publish(oldCapture, binding: .bound(oldCapture.stable.generation))
            let newDocument = try save(repository, oldDocument) { document in
                switch scenario {
                case "componentModify": document.components[0].name = "Renamed"
                case "componentAvailability": document.components[1].availability.denyScopeIDs = [EntityID("scope_child")]
                case "componentAdd": document.components.append(ComponentDefinition(id: EntityID("component_added"), name: "Added",
                    ownerScopeID: document.scopes[0].id, root: Layer(id: EntityID("layer_added"), kind: .stack, name: "Root")))
                case "componentDelete": document.components.removeLast()
                case "screenUsageAdd": document.screens[0].root.children.append(Layer(id: EntityID("instance_added"),
                    kind: .componentInstance, name: "Added", component: ComponentInstance(definitionID: EntityID("component_1"))))
                case "screenUsageRemove": document.screens[0].root.children.removeAll()
                case "scopeParentMove": document.scopes[2].parentID = document.scopes[1].id
                case "scopeAdd": document.scopes.append(ArchitectureScope(id: EntityID("scope_added"), name: "Added",
                    parentID: document.scopes[0].id))
                case "scopeDelete": document.scopes.removeLast()
                case "stableIDRename": document.components[2].id = EntityID("component_renamed")
                default: fatalError("Unknown scenario")
                }
            }
            let current = try capture(repository)
            let set = try changed(decision(store, current: current))
            let newBytes = try fileBytes(root)
            XCTAssertEqual(Set(set.changes), Set(byteOracle(oldBytes, newBytes)), scenario)
            XCTAssertEqual(set.fromIndexGenerationID, descriptor.id.rawValue)
            XCTAssertEqual(set.fromCanonicalIdentity, oldCapture.snapshot.identity.rawValue)
            XCTAssertEqual(set.toCanonicalGeneration, current.stable.generation.serialized)
            XCTAssertEqual(set.toCanonicalIdentity, current.snapshot.identity.rawValue)
            let beforeRows = Store.rows(oldDocument)
            let afterRows = Store.rows(newDocument)
            let changedRows = Set(beforeRows.keys).union(afterRows.keys).filter { beforeRows[$0] != afterRows[$0] }.sorted()
            reports.append(["scenario": scenario, "changes": set.changes.map { ["operation": $0.operation, "kind": $0.kind, "id": $0.id] },
                            "actualChangedProjectionRows": changedRows, "sourceMatchesByteOracle": true])
        }
        if let path = ProcessInfo.processInfo.environment["HAMII_SOURCE_CAPTURE_MATRIX_RESULT"] {
            let data = try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path))
        }
    }

    func testCumulativeSavesAndSourceInvalidation() throws {
        let (root, repository, initial) = try fixture()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let old = try capture(repository)
        let oldBytes = try fileBytes(root)
        let store = try makeStore(root)
        _ = try store.publish(old, binding: .bound(old.stable.generation))
        let first = try save(repository, initial) { $0.components[1].name = "First save" }
        let second = try save(repository, first) { document in
            document.screens[0].root.children.append(Layer(id: EntityID("instance_second_save"), kind: .componentInstance,
                name: "Second", component: ComponentInstance(definitionID: EntityID("component_2"))))
        }
        let current = try capture(repository)
        let set = try changed(decision(store, current: current))
        XCTAssertEqual(Set(set.changes), Set(byteOracle(oldBytes, try fileBytes(root))))
        XCTAssertEqual(Set(set.changes.map(\.kind)), ["components", "screens"])
        XCTAssertEqual(Store.rows(initial).keys.count, Store.rows(second).keys.count)
        XCTAssertTrue(try remainsCurrent(set, at: repository))
        _ = try save(repository, second) { $0.components[2].name = "Third save" }
        XCTAssertFalse(try remainsCurrent(set, at: repository))
    }

    func testUnboundAndCorruptInventoryFallBackToFullRebuild() throws {
        let (root, repository, document) = try fixture()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let old = try capture(repository)
        let store = try makeStore(root)
        if case .fullRebuild = try decision(store, current: old) {} else { XCTFail("missing index accepted") }
        _ = try store.publish(old, binding: .explicitlyUnbound)
        let updated = try save(repository, document) { $0.components[1].name = "Updated" }
        let current = try capture(repository)
        if case .fullRebuild("unbound") = try decision(store, current: current) {} else { XCTFail("unbound must fall back") }
        _ = try store.publish(old, binding: .bound(old.stable.generation))
        for sql in [
            "DELETE FROM source_inventory WHERE path='components/component_1.json'",
            "INSERT INTO source_inventory SELECT * FROM source_inventory LIMIT 1",
            "UPDATE source_inventory SET digest='invalid' WHERE path='components/component_1.json'",
            "UPDATE metadata SET value='2' WHERE key='inventoryVersion'",
            "UPDATE metadata SET value=printf('%064d',0) WHERE key='inventorySourceCanonicalIdentity'",
            "UPDATE metadata SET value='00000000-0000-0000-0000-000000000000' WHERE key='inventoryIndexGenerationID'",
            "UPDATE metadata SET value='0' WHERE key='indexSchemaVersion'",
            "DELETE FROM projection_rows WHERE key='component:component_1'"
        ] {
            _ = try store.publish(old, binding: .bound(old.stable.generation))
            try store.execute(sql)
            if case .fullRebuild = try decision(store, current: current) {} else { XCTFail("corrupt inventory accepted: \(sql)") }
        }
        _ = try store.publish(old, binding: .bound(old.stable.generation))
        try store.execute("DELETE FROM metadata WHERE key='inventoryDigest'")
        if case .fullRebuild = try decision(store, current: current) {} else { XCTFail("missing inventory accepted") }
        _ = try store.publish(old, binding: .bound(old.stable.generation))
        try store.execute("DELETE FROM metadata WHERE key='sourceGenerationBinding'")
        if case .fullRebuild = try decision(store, current: current) {} else { XCTFail("malformed descriptor accepted") }
        let token = DesignToken(id: EntityID("token_extra"), name: "Extra", kind: .spacing,
                                ownerScopeID: updated.scopes[0].id, value: .literal("8"))
        _ = try save(repository, updated) { $0.tokens.append(token) }
        _ = try store.publish(old, binding: .bound(old.stable.generation))
        if case .fullRebuild("unsupportedCanonicalInput") = try decision(store, current: capture(repository)) {}
        else { XCTFail("non-projection input must fall back") }
    }

    func testAtomicInventoryAndRowsPublication() throws {
        let (root, repository, document) = try fixture()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let old = try capture(repository)
        let store = try makeStore(root)
        let first = try store.publish(old, binding: .bound(old.stable.generation))
        _ = try save(repository, document) { $0.components[1].name = "New name" }
        let next = try capture(repository)
        let reader = try Store(url: store.url)
        _ = try store.publish(next, binding: .bound(next.stable.generation), beforeCommit: {
            let visible = try XCTUnwrap(reader.read())
            XCTAssertEqual(visible.0.id, first.id)
            XCTAssertEqual(visible.1, old.entries)
            XCTAssertEqual(try reader.projectionRows(), Store.rows(old.snapshot.document))
        })
        let visible = try XCTUnwrap(reader.read())
        XCTAssertEqual(visible.1, next.entries)
        XCTAssertNotEqual(visible.0.id, first.id)
        XCTAssertEqual(try reader.projectionRows(), Store.rows(next.snapshot.document))
        enum Rollback: Error { case injected }
        XCTAssertThrowsError(try store.publish(old, binding: .bound(old.stable.generation),
            beforeCommit: { throw Rollback.injected }))
        XCTAssertEqual(try reader.read()?.0.id, visible.0.id)
        XCTAssertEqual(try reader.read()?.1, next.entries)
        XCTAssertEqual(try reader.projectionRows(), Store.rows(next.snapshot.document))
    }

    func testManifestOnlyMutationDoesNotInventProjectionEntityChange() throws {
        let (root, repository, document) = try fixture()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let old = try capture(repository)
        let store = try makeStore(root)
        _ = try store.publish(old, binding: .bound(old.stable.generation))
        _ = try save(repository, document) { $0.name = "New project title" }
        let current = try capture(repository)
        XCTAssertNotEqual(old.snapshot.identity, current.snapshot.identity)
        XCTAssertTrue(try changed(decision(store, current: current)).changes.isEmpty)
    }

    func testRestartWorker() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let project = environment["HAMII_SOURCE_CAPTURE_PROJECT"],
              let database = environment["HAMII_SOURCE_CAPTURE_DATABASE"],
              let output = environment["HAMII_SOURCE_CAPTURE_WORKER_RESULT"] else {
            throw XCTSkip("Subprocess only")
        }
        let repository = CanonicalRepository(root: URL(fileURLWithPath: project))
        let set = try changed(decision(Store(url: URL(fileURLWithPath: database)), current: capture(repository)))
        try JSONEncoder().encode(set).write(to: URL(fileURLWithPath: output))
    }

    func testNewOSProcessReconstructsOldIndexSourceDifference() throws {
        let (root, repository, document) = try fixture()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let old = try capture(repository)
        let oldBytes = try fileBytes(root)
        let store = try makeStore(root)
        _ = try store.publish(old, binding: .bound(old.stable.generation))
        _ = try save(repository, document) { $0.components[1].name = "After restart" }
        let result = root.deletingLastPathComponent().appendingPathComponent("source-worker-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: result) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        process.arguments = ["-XCTest", "HamiiTests.ChangedEntitySourceCaptureSpikeTests/testRestartWorker", Bundle(for: Self.self).bundleURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["HAMII_SOURCE_CAPTURE_PROJECT"] = root.path
        environment["HAMII_SOURCE_CAPTURE_DATABASE"] = store.url.path
        environment["HAMII_SOURCE_CAPTURE_WORKER_RESULT"] = result.path
        for imageIndex in 0..<_dyld_image_count() {
            guard let imageName = _dyld_get_image_name(imageIndex) else { continue }
            let imagePath = String(cString: imageName)
            if imagePath.hasSuffix("/libTesting.dylib") {
                environment["DYLD_LIBRARY_PATH"] = URL(fileURLWithPath: imagePath).deletingLastPathComponent().path
                break
            }
        }
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = process.standardOutput
        try process.run()
        let output = (process.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: output, as: UTF8.self))
        let set = try JSONDecoder().decode(ChangeSet.self, from: Data(contentsOf: result))
        XCTAssertEqual(Set(set.changes), Set(byteOracle(oldBytes, try fileBytes(root))))
    }

    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        return sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)]
    }

    func testMeasuredSourceCaptureCost() throws {
        guard let output = ProcessInfo.processInfo.environment["HAMII_SOURCE_CAPTURE_BENCHMARK_RESULT"] else {
            throw XCTSkip("Run explicitly for Spike benchmark")
        }
        var reports: [[String: Any]] = []
        for (name, count, mixed) in [("1000", 1000, false), ("5000", 5000, false), ("mixed", 100, true)] {
            let (root, repository, baseline) = try fixture(componentCount: count, mixed: mixed)
            defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
            var oldDocument = baseline
            for changedCount in [1, 10, 100] {
                let old = try capture(repository)
                let store = try makeStore(root)
                _ = try store.publish(old, binding: .bound(old.stable.generation))
                let iteration = oldDocument.revision
                oldDocument = try save(repository, oldDocument) { document in
                    for number in 0..<changedCount {
                        document.components[number].name = "Change \(iteration)-\(number)"
                    }
                }
                var snapshotTimes: [Double] = []
                var baselineSnapshotTimes: [Double] = []
                var digestTimes: [Double] = []
                var readTimes: [Double] = []
                var indexIntegrityTimes: [Double] = []
                var diffTimes: [Double] = []
                for _ in 0..<5 {
                    let baseline = try repository.withStableSinglePassProbe { result, _ in result }
                    baselineSnapshotTimes.append(baseline.milliseconds["snapshotTotal"] ?? 0)
                    let current = try capture(repository)
                    snapshotTimes.append(current.snapshotMilliseconds)
                    digestTimes.append(current.digestMilliseconds)
                    let readStart = ProcessInfo.processInfo.systemUptime
                    var inventoryRead = 0.0
                    let loaded = try store.read(onInventoryRead: { inventoryRead = $0 })
                    let fullRead = (ProcessInfo.processInfo.systemUptime - readStart) * 1_000
                    readTimes.append(inventoryRead)
                    indexIntegrityTimes.append(fullRead - inventoryRead)
                    let source = try XCTUnwrap(loaded)
                    let diffStart = ProcessInfo.processInfo.systemUptime
                    let set = try changed(decide(source, current: current))
                    diffTimes.append((ProcessInfo.processInfo.systemUptime - diffStart) * 1_000)
                    XCTAssertEqual(set.changes.count, changedCount)
                }
                func summary(_ samples: [Double]) -> [String: Double] {
                    ["p50Ms": percentile(samples, 0.5), "p95Ms": percentile(samples, 0.95)]
                }
                let size = try FileManager.default.attributesOfItem(atPath: store.url.path)[.size] as? NSNumber
                reports.append(["fixture": name, "components": count, "changedEntities": changedCount,
                    "runs": 5, "snapshot": summary(snapshotTimes), "digestCallback": summary(digestTimes),
                    "baselineSnapshotWithoutDigest": summary(baselineSnapshotTimes),
                    "inventoryRead": summary(readTimes), "indexRowIntegrityRead": summary(indexIntegrityTimes),
                    "inventoryDiffAndChangeSet": summary(diffTimes),
                    "inventoryRows": old.entries.count, "digestBytes": old.entries.count * 32,
                    "sqliteFileBytes": size?.intValue ?? -1])
            }
        }
        let data = try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: output))
    }
}
