import Foundation
import Darwin
import CryptoKit
import HamiiCore
import HamiiApplication

public enum CanonicalError: Error, CustomStringConvertible {
    case unsupportedFormat(Int)
    case invalid([Diagnostic])
    case unsafeID(String)
    case alreadyExists
    case filenameMismatch(String)
    case transactionConflict(String)
    case transactionCorrupt(String)
    case invalidClientEpoch

    public var description: String {
        switch self {
        case .unsupportedFormat(let version): return "Unsupported document format \(version); run a migration"
        case .invalid(let diagnostics): return diagnostics.map { "\($0.rule): \($0.message)" }.joined(separator: "; ")
        case .unsafeID(let id): return "Unsafe stable ID: \(id)"
        case .alreadyExists: return "Project already exists"
        case .filenameMismatch(let name): return "Canonical file name does not match stable ID: \(name)"
        case .transactionConflict(let path): return "Canonical save conflicts with an external edit: \(path)"
        case .transactionCorrupt(let detail): return "Canonical save journal is invalid: \(detail)"
        case .invalidClientEpoch: return "Client observation epoch is invalid"
        }
    }
}

private struct Manifest: Codable {
    var formatVersion: Int
    var id: EntityID
    var name: String
    var revision: Int
    var versions: FormatVersions
    var authoringHarness: AuthoringHarness
    var capabilityDeclarations: [CapabilityDeclaration]
    var tokenTemplate: TokenTemplateProvenance?
}

private struct FormatHeader: Decodable { var formatVersion: Int }

public final class CanonicalRepository: ProjectRepository {
    public let root: URL
    private let manager = FileManager.default
    private let transaction: CanonicalTransaction

    public init(root: URL) {
        self.root = root.standardizedFileURL
        transaction = CanonicalTransaction(root: self.root)
    }

    init(root: URL, transactionHook: @escaping (TransactionStep) throws -> Void) {
        self.root = root.standardizedFileURL
        transaction = CanonicalTransaction(root: self.root, hook: transactionHook)
    }

    public func create(name: String) throws -> Document {
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let document = Document(name: name)
        try withLock(exclusive: true) {
            try transaction.recoverIfNeeded()
            if manager.fileExists(atPath: root.appendingPathComponent("hamii.json").path) { throw CanonicalError.alreadyExists }
            try AgentProfilesRepository(root: root).createDefault()
            try rotateClientEpoch()
            try writeDocument(document, expected: nil)
        }
        return document
    }

    public func load() throws -> Document {
        try withLock(exclusive: true) {
            try transaction.recoverIfNeeded()
            return try loadUnlocked(validate: true)
        }
    }

    public func observe() throws -> ProjectObservation {
        try withLock(exclusive: true) {
            try transaction.recoverIfNeeded()
            let document = try loadUnlocked(validate: true)
            return ProjectObservation(document: document, statePrecondition: try clientPreconditionUnlocked())
        }
    }

    public func commit(_ document: Document, expected: ProjectObservation) throws -> ProjectObservation {
        try withLock(exclusive: true) {
            try transaction.recoverIfNeeded()
            guard try clientPreconditionUnlocked() == expected.statePrecondition else { throw AuthoringError.staleState }
            let manifest = try readManifest()
            guard manifest.revision == expected.document.revision,
                  document.revision == expected.document.revision + 1 else {
                throw AuthoringError.staleRevision(expected: expected.document.revision + 1, actual: manifest.revision)
            }
            // Advance before touching Canonical shards. A stopped save may
            // invalidate a token unnecessarily, but cannot resurrect it.
            try rotateClientEpoch()
            try writeDocument(document, expected: expected.document)
            return ProjectObservation(document: document, statePrecondition: try clientPreconditionUnlocked())
        }
    }

    public func diagnostics() throws -> [Diagnostic] {
        try withLock(exclusive: true) {
            try transaction.recoverIfNeeded()
            return allDiagnostics(try loadUnlocked(validate: false))
        }
    }

    private func loadUnlocked(validate: Bool) throws -> Document {
        let manifest = try readManifest()
        guard manifest.formatVersion == 1, manifest.versions.document == 1, manifest.versions.authoringHarness == 1 else {
            throw CanonicalError.unsupportedFormat(manifest.formatVersion)
        }
        var document = Document(name: manifest.name)
        document.id = manifest.id
        document.revision = manifest.revision
        document.versions = manifest.versions
        document.authoringHarness = manifest.authoringHarness
        document.capabilityDeclarations = manifest.capabilityDeclarations
        document.tokenTemplate = manifest.tokenTemplate
        document.pages = try readAll("pages")
        document.screens = try readAll("screens")
        document.scopes = try readAll("scopes")
        document.components = try readAll("components")
        document.tokens = try readAll("tokens")
        document.assets = try readAll("assets")
        document.interactions = try readAll("interactions")
        document.motions = try readAll("motions")
        document.fixtures = try readAll("fixtures")
        document.targets = try readAll("targets")
        if validate {
            let diagnostics = allDiagnostics(document)
            if diagnostics.contains(where: { $0.severity == .error }) { throw CanonicalError.invalid(diagnostics) }
        }
        return document
    }

    public func identityAndRevision() throws -> (EntityID, Int) {
        try withLock(exclusive: true) {
            try transaction.recoverIfNeeded()
            let manifest = try readManifest()
            return (manifest.id, manifest.revision)
        }
    }

    public func save(_ document: Document, expected: Document) throws {
        try withLock(exclusive: true) {
            try transaction.recoverIfNeeded()
            let manifest = try readManifest()
            guard manifest.revision == expected.revision else {
                throw AuthoringError.staleRevision(expected: expected.revision, actual: manifest.revision)
            }
            guard document.revision == expected.revision + 1 else {
                throw AuthoringError.staleRevision(expected: expected.revision + 1, actual: document.revision)
            }
            try rotateClientEpoch()
            try writeDocument(document, expected: expected)
        }
    }

    private func writeDocument(_ document: Document, expected: Document?) throws {
        let diagnostics = allDiagnostics(document)
        if diagnostics.contains(where: { $0.severity == .error }) { throw CanonicalError.invalid(diagnostics) }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let files = try encodedFiles(document)
        let oldFiles = try expected.map(encodedFiles) ?? [:]
        try transaction.commit(newFiles: files, expectedOldFiles: oldFiles, oldRevision: expected?.revision, newRevision: document.revision)
    }

    private func encodedFiles(_ document: Document) throws -> [String: Data] {
        var files: [String: Data] = [:]
        try encodeAll(document.pages, folder: "pages", into: &files)
        try encodeAll(document.screens, folder: "screens", into: &files)
        try encodeAll(document.scopes, folder: "scopes", into: &files)
        try encodeAll(document.components, folder: "components", into: &files)
        try encodeAll(document.tokens, folder: "tokens", into: &files)
        try encodeAll(document.assets, folder: "assets", into: &files)
        try encodeAll(document.interactions, folder: "interactions", into: &files)
        try encodeAll(document.motions, folder: "motions", into: &files)
        try encodeAll(document.fixtures, folder: "fixtures", into: &files)
        try encodeAll(document.targets, folder: "targets", into: &files)
        let manifest = Manifest(formatVersion: 1, id: document.id, name: document.name, revision: document.revision, versions: document.versions, authoringHarness: document.authoringHarness, capabilityDeclarations: document.capabilityDeclarations, tokenTemplate: document.tokenTemplate)
        files["hamii.json"] = try encode(manifest)
        return files
    }

    private func allDiagnostics(_ document: Document) -> [Diagnostic] {
        var diagnostics = DocumentValidator.validate(document)
        let blobs = CanonicalBlobStore(root: root)
        for asset in document.assets {
            if case .repository = asset.source, !blobs.verify(asset) {
                diagnostics.append(Diagnostic("asset.integrity", "Repository asset blob is missing or has a different SHA-256", entityID: asset.id))
            }
        }
        return diagnostics
    }

    private func withLock<T>(exclusive: Bool, _ operation: () throws -> T) throws -> T {
        let local = root.appendingPathComponent(".hamii", isDirectory: true)
        try manager.createDirectory(at: local, withIntermediateDirectories: true)
        let descriptor = open(local.appendingPathComponent("write.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard flock(descriptor, exclusive ? LOCK_EX : LOCK_SH) == 0 else { throw CocoaError(.fileReadUnknown) }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private var clientEpochURL: URL {
        root.appendingPathComponent(".hamii/client-observation-epoch")
    }

    private func clientEpochUnlocked() throws -> String {
        if !manager.fileExists(atPath: clientEpochURL.path) { try rotateClientEpoch() }
        let value = try String(contentsOf: clientEpochURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: value) != nil else { throw CanonicalError.invalidClientEpoch }
        return value
    }

    private func rotateClientEpoch() throws {
        let value = UUID().uuidString + "\n"
        try Data(value.utf8).write(to: clientEpochURL, options: .atomic)
    }

    private func clientPreconditionUnlocked() throws -> ClientPrecondition {
        var hash = SHA256()
        func append(_ value: Data) {
            var length = UInt64(value.count).bigEndian
            withUnsafeBytes(of: &length) { hash.update(data: $0) }
            hash.update(data: value)
        }
        append(Data("hamii-client-state-v1".utf8))
        append(Data(root.resolvingSymlinksInPath().standardizedFileURL.path.utf8))
        append(Data(try clientEpochUnlocked().utf8))
        let folders = ["pages", "screens", "scopes", "components", "tokens", "assets", "interactions", "motions", "fixtures", "targets"]
        var paths = [root.appendingPathComponent("hamii.json")]
        let agentProfiles = root.appendingPathComponent("hamii-agent-profiles.json")
        if manager.fileExists(atPath: agentProfiles.path) { paths.append(agentProfiles) }
        for folder in folders {
            let directory = root.appendingPathComponent(folder, isDirectory: true)
            if manager.fileExists(atPath: directory.path) {
                paths += try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
                    .filter { $0.pathExtension == "json" }
            }
        }
        for path in paths.sorted(by: { $0.path < $1.path }) {
            guard try path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw CanonicalError.invalidClientEpoch
            }
            append(Data(path.path.replacingOccurrences(of: root.path + "/", with: "").utf8))
            append(try Data(contentsOf: path))
        }
        return ClientPrecondition(hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private func read<T: Decodable>(_ url: URL) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    private func readManifest() throws -> Manifest {
        let url = root.appendingPathComponent("hamii.json")
        let header: FormatHeader = try read(url)
        guard header.formatVersion == 1 else { throw CanonicalError.unsupportedFormat(header.formatVersion) }
        return try read(url)
    }

    private func readAll<T: Decodable & Identifiable>(_ folder: String) throws -> [T] where T.ID == EntityID {
        let directory = root.appendingPathComponent(folder, isDirectory: true)
        guard manager.fileExists(atPath: directory.path) else { return [] }
        return try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                let value: T = try read(url)
                guard url.deletingPathExtension().lastPathComponent == value.id.rawValue else {
                    throw CanonicalError.filenameMismatch(url.lastPathComponent)
                }
                return value
            }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    private func encodeAll<T: Encodable & Identifiable>(_ values: [T], folder: String, into files: inout [String: Data]) throws where T.ID == EntityID {
        for value in values {
            guard value.id.rawValue.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil else {
                throw CanonicalError.unsafeID(value.id.rawValue)
            }
            files["\(folder)/\(value.id.rawValue).json"] = try encode(value)
        }
    }
}
