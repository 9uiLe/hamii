import Foundation
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
    case managedGitPending

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
        case .managedGitPending: return "Worktree transition is pending; recovery is required"
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

// The keyed variant is a measurement candidate. Normal repository entry
// points always use the existing comparator until its full safety gate passes.
enum CanonicalPathSortVariant {
    case current
    #if DEBUG
    case precomputedPathKeys
    #endif
}

func sortCanonicalPaths(_ paths: [URL], variant: CanonicalPathSortVariant) -> [URL] {
    switch variant {
    case .current:
        return paths.sorted(by: { $0.path < $1.path })
    #if DEBUG
    case .precomputedPathKeys:
        let keyed = paths.map { (key: $0.path, url: $0) }
        assert(Set(keyed.map(\.key)).count == keyed.count,
               "Canonical paths must be unique before comparing sort variants")
        return keyed.sorted(by: { $0.key < $1.key }).map(\.url)
    #endif
    }
}

public final class CanonicalRepository: ProjectRepository {
    public let root: URL
    private let manager = FileManager.default
    private let transaction: CanonicalTransaction
    private let coordinator: WorktreeCoordinator
    private let generations: CanonicalGenerationStore

    public init(root: URL) {
        self.root = root.standardizedFileURL
        transaction = CanonicalTransaction(root: self.root)
        coordinator = WorktreeCoordinator(root: self.root)
        generations = CanonicalGenerationStore(root: self.root)
    }

    init(root: URL, transactionHook: @escaping (TransactionStep) throws -> Void) {
        self.root = root.standardizedFileURL
        transaction = CanonicalTransaction(root: self.root, hook: transactionHook)
        coordinator = WorktreeCoordinator(root: self.root)
        generations = CanonicalGenerationStore(root: self.root)
    }

    public func create(name: String) throws -> Document {
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let document = Document(name: name)
        try coordinator.withExclusive {
            try transaction.recoverIfNeeded()
            try coordinator.requireReady()
            if manager.fileExists(atPath: root.appendingPathComponent("hamii.json").path) { throw CanonicalError.alreadyExists }
            try AgentProfilesRepository(root: root).createDefault()
            try coordinator.invalidateClientObservations()
            try writeDocument(document, expected: nil)
            _ = try generations.bootstrapVerified(snapshotDuringManagedGitTransition())
        }
        return document
    }

    public func load() throws -> Document {
        try coordinator.withExclusive {
            try transaction.recoverIfNeeded()
            try coordinator.requireReady()
            try recoverGenerationIfNeeded()
            return try loadUnlocked(validate: true)
        }
    }

    public func observe() throws -> ProjectObservation {
        try withCoordinatedObservation { $0 }
    }

    public func withCoordinatedObservation<T>(_ operation: (ProjectObservation) throws -> T) throws -> T {
        try coordinator.withExclusive {
            try transaction.recoverIfNeeded()
            try coordinator.requireReady()
            try recoverGenerationIfNeeded()
            let document = try loadUnlocked(validate: true)
            let observed = ProjectObservation(document: document, statePrecondition: try clientPreconditionUnlocked())
            return try operation(observed)
        }
    }

    public func withCoordinatedDocument<T>(_ operation: (Document) throws -> T) throws -> T {
        try coordinator.withExclusive {
            try transaction.recoverIfNeeded()
            try coordinator.requireReady()
            try recoverGenerationIfNeeded()
            return try operation(loadUnlocked(validate: true))
        }
    }

    public func withCoordinatedSnapshot<T>(_ operation: (CanonicalSnapshot) throws -> T) throws -> T {
        try coordinator.withExclusive {
            try transaction.recoverIfNeeded()
            try coordinator.requireReady()
            try recoverGenerationIfNeeded()
            return try operation(snapshotDuringManagedGitTransition())
        }
    }

    /// A derived Index may recover only from an already stable coordinated
    /// generation. This path may recover the Canonical transaction journal, but
    /// deliberately never bootstraps or reconciles the generation record.
    package func withStableSnapshotForDerivedRecovery<T>(
        onLockAcquired: (() throws -> Void)? = nil,
        onObservation: ((CanonicalObservationMeasurement) -> Void)? = nil,
        _ operation: (CanonicalSnapshot, StableCanonicalGeneration) throws -> T
    ) throws -> T {
        try coordinator.withExclusive {
            try onLockAcquired?()
            try measureCanonical(.transactionRecovery, recorder: onObservation) {
                try transaction.recoverIfNeeded()
            }
            try measureCanonical(.readyGate, recorder: onObservation) {
                try coordinator.requireReady()
            }
            let stable = try measureCanonical(.stableGenerationRead, recorder: onObservation) {
                try generations.readStable()
            }
            let snapshot = try measureCanonical(.snapshotAcquisition, recorder: onObservation) {
                try snapshotDuringManagedGitTransition(onObservation: onObservation)
            }
            guard stable.snapshotIdentity == snapshot.identity else {
                throw CanonicalGenerationError.unknownState
            }
            return try operation(snapshot, stable)
        }
    }

    /// Query may read an explicitly unbound Index after an external edit and
    /// explicit rebuild. It requires an existing stable record, but only a
    /// Bound Index requires that record to match the observed Snapshot.
    package func withStableRecordSnapshotForQuery<T>(
        onLockAcquired: (() throws -> Void)? = nil,
        _ operation: (CanonicalSnapshot, StableCanonicalGeneration) throws -> T
    ) throws -> T {
        try coordinator.withExclusive {
            try onLockAcquired?()
            try transaction.recoverIfNeeded()
            try coordinator.requireReady()
            let stable = try generations.readStable()
            return try operation(snapshotDuringManagedGitTransition(), stable)
        }
    }

    /// Phase 2 of an Index recovery uses the durable stable generation and a
    /// Git oracle without parsing the full Canonical document a second time.
    package func withStableGenerationForDerivedRecovery<T>(
        onLockAcquired: (() throws -> Void)? = nil,
        _ operation: (StableCanonicalGeneration) throws -> T
    ) throws -> T {
        try coordinator.withExclusive {
            try onLockAcquired?()
            try transaction.recoverIfNeeded()
            try coordinator.requireReady()
            return try operation(generations.readStable())
        }
    }

    public func withCoordinatedIdentity<T>(_ operation: (EntityID, Int) throws -> T) throws -> T {
        try coordinator.withExclusive {
            try transaction.recoverIfNeeded()
            try coordinator.requireReady()
            try recoverGenerationIfNeeded()
            let manifest = try readManifest()
            return try operation(manifest.id, manifest.revision)
        }
    }

    public func commit(_ document: Document, expected: ProjectObservation) throws -> ProjectObservation {
        try coordinator.withExclusive {
            try transaction.recoverIfNeeded()
            try coordinator.requireReady()
            try recoverGenerationIfNeeded()
            guard try clientPreconditionUnlocked() == expected.statePrecondition else { throw AuthoringError.staleState }
            let manifest = try readManifest()
            guard manifest.revision == expected.document.revision,
                  document.revision == expected.document.revision + 1 else {
                throw AuthoringError.staleRevision(expected: expected.document.revision + 1, actual: manifest.revision)
            }
            // Advance before touching Canonical shards. A stopped save may
            // invalidate a token unnecessarily, but cannot resurrect it.
            try coordinator.invalidateClientObservations()
            try writeDocument(document, expected: expected.document)
            return ProjectObservation(document: document, statePrecondition: try clientPreconditionUnlocked())
        }
    }

    public func diagnostics() throws -> [Diagnostic] {
        try coordinator.withExclusive {
            try transaction.recoverIfNeeded()
            try coordinator.requireReady()
            try recoverGenerationIfNeeded()
            return allDiagnostics(try loadUnlocked(validate: false))
        }
    }

    private func loadUnlocked(validate: Bool, validationHook: (() throws -> Void)? = nil,
                              onObservation: CanonicalObservationRecorder? = nil) throws -> Document {
        let manifest = try measureCanonical(.manifestRead, recorder: onObservation) { try readManifest() }
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
        document.pages = try readAll("pages", onObservation: onObservation)
        document.screens = try readAll("screens", onObservation: onObservation)
        document.scopes = try readAll("scopes", onObservation: onObservation)
        document.components = try readAll("components", onObservation: onObservation)
        document.tokens = try readAll("tokens", onObservation: onObservation)
        document.assets = try readAll("assets", onObservation: onObservation)
        document.interactions = try readAll("interactions", onObservation: onObservation)
        document.motions = try readAll("motions", onObservation: onObservation)
        document.fixtures = try readAll("fixtures", onObservation: onObservation)
        document.targets = try readAll("targets", onObservation: onObservation)
        if validate {
            try validationHook?()
            let diagnostics = allDiagnostics(document, onObservation: onObservation)
            if diagnostics.contains(where: { $0.severity == .error }) { throw CanonicalError.invalid(diagnostics) }
        }
        return document
    }

    public func identityAndRevision() throws -> (EntityID, Int) {
        try withCoordinatedIdentity { ($0, $1) }
    }

    public func save(_ document: Document, expected: Document) throws {
        try coordinator.withExclusive {
            try transaction.recoverIfNeeded()
            try coordinator.requireReady()
            try recoverGenerationIfNeeded()
            let manifest = try readManifest()
            guard manifest.revision == expected.revision else {
                throw AuthoringError.staleRevision(expected: expected.revision, actual: manifest.revision)
            }
            guard document.revision == expected.revision + 1 else {
                throw AuthoringError.staleRevision(expected: expected.revision + 1, actual: document.revision)
            }
            try coordinator.invalidateClientObservations()
            try writeDocument(document, expected: expected)
        }
    }

    // Managed Git holds the same coordinator lock while it validates a
    // candidate worktree state. The pending marker intentionally blocks all
    // normal repository entry points until validation finishes.
    func observeDuringManagedGitTransition() throws -> ProjectObservation {
        try transaction.recoverIfNeeded()
        let document = try loadUnlocked(validate: true)
        return ProjectObservation(document: document, statePrecondition: try clientPreconditionUnlocked())
    }

    // The caller holds WorktreeCoordinator across the entire observation.
    // A revision cannot make multiple files coherent; the coordinated read
    // provides the snapshot boundary for hamii-managed writers.
    func snapshotDuringManagedGitTransition(validationHook: (() throws -> Void)? = nil,
                                            onObservation: CanonicalObservationRecorder? = nil,
                                            pathSortVariant: CanonicalPathSortVariant = .current) throws -> CanonicalSnapshot {
        try measureCanonical(.transactionRecovery, recorder: onObservation) { try transaction.recoverIfNeeded() }
        let document = try loadUnlocked(validate: true, validationHook: validationHook,
                                        onObservation: onObservation)
        _ = try measureCanonical(.agentProfilesReadValidation, recorder: onObservation) {
            try AgentProfilesRepository(root: root).profiles()
        }
        var files: [String: Data] = [:]
        let paths = try measureCanonical(.canonicalPathEnumerationAndSymlinkCheck, recorder: onObservation) {
            try canonicalJSONPaths(onObservation: onObservation, sortVariant: pathSortVariant)
        }
        let readStart = onObservation == nil ? 0 : ProcessInfo.processInfo.systemUptime
        var bytesRead = 0
        for path in paths {
            let relative = path.path.replacingOccurrences(of: root.path + "/", with: "")
            let data = try Data(contentsOf: path)
            files[relative] = data
            if onObservation != nil { bytesRead += data.count }
        }
        if let onObservation {
            onObservation(CanonicalObservationMeasurement(stage: .identityBytesRead,
                milliseconds: (ProcessInfo.processInfo.systemUptime - readStart) * 1_000,
                bytes: bytesRead))
        }
        let identity = measureCanonical(.identityHash, recorder: onObservation) { hashIdentity(files) }
        return CanonicalSnapshot(document: document, identity: identity)
    }

    private func writeDocument(_ document: Document, expected: Document?) throws {
        let diagnostics = allDiagnostics(document)
        if diagnostics.contains(where: { $0.severity == .error }) { throw CanonicalError.invalid(diagnostics) }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let files = try encodedFiles(document)
        let oldFiles = try expected.map(encodedFiles) ?? [:]
        try transaction.preflight(expectedOldFiles: oldFiles)
        let operationID: UUID?
        if expected != nil {
            let old = try generations.requireMatchingStable(snapshotDuringManagedGitTransition())
            var proposed = files
            proposed["hamii-agent-profiles.json"] = try Data(contentsOf: root.appendingPathComponent("hamii-agent-profiles.json"))
            operationID = try generations.beginPending(old: old, expectedNewIdentity: hashIdentity(proposed))
        } else {
            operationID = nil
        }
        try transaction.commit(newFiles: files, expectedOldFiles: oldFiles, oldRevision: expected?.revision, newRevision: document.revision)
        if let operationID {
            _ = try generations.reconcile(snapshotDuringManagedGitTransition(), expectedOperationID: operationID)
        }
    }

    private func recoverGenerationIfNeeded() throws {
        do {
            _ = try generations.readStable()
        } catch CanonicalGenerationError.missing {
            // A verified coordinated snapshot is the only bootstrap source.
            _ = try generations.bootstrapVerified(snapshotDuringManagedGitTransition())
        } catch CanonicalGenerationError.pending {
            _ = try generations.reconcile(snapshotDuringManagedGitTransition())
        }
    }

    private func hashIdentity(_ files: [String: Data]) -> CanonicalSnapshotIdentity {
        var hash = SHA256()
        for path in files.keys.sorted() {
            appendHash(Data(path.utf8), to: &hash)
            appendHash(files[path]!, to: &hash)
        }
        return CanonicalSnapshotIdentity(rawValue: hash.finalize().map { String(format: "%02x", $0) }.joined())!
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

    private func allDiagnostics(_ document: Document,
                                onObservation: CanonicalObservationRecorder? = nil) -> [Diagnostic] {
        var diagnostics = measureCanonical(.documentValidation, recorder: onObservation) {
            DocumentValidator.validate(document)
        }
        let start = onObservation == nil ? 0 : ProcessInfo.processInfo.systemUptime
        let blobs = CanonicalBlobStore(root: root)
        for asset in document.assets {
            if case .repository = asset.source, !blobs.verify(asset) {
                diagnostics.append(Diagnostic("asset.integrity", "Repository asset blob is missing or has a different SHA-256", entityID: asset.id))
            }
        }
        if let onObservation {
            onObservation(CanonicalObservationMeasurement(stage: .assetIntegrityValidation,
                milliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1_000))
        }
        return diagnostics
    }

    private func clientPreconditionUnlocked() throws -> ClientPrecondition {
        var hash = SHA256()
        appendHash(Data("hamii-client-state-v1".utf8), to: &hash)
        appendHash(Data(root.resolvingSymlinksInPath().standardizedFileURL.path.utf8), to: &hash)
        appendHash(Data(try coordinator.clientEpoch().utf8), to: &hash)
        for path in try canonicalJSONPaths() {
            appendHash(Data(path.path.replacingOccurrences(of: root.path + "/", with: "").utf8), to: &hash)
            appendHash(try Data(contentsOf: path), to: &hash)
        }
        return ClientPrecondition(hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    func canonicalJSONPaths(onObservation: CanonicalObservationRecorder? = nil,
                            sortVariant: CanonicalPathSortVariant = .current,
                            onUnsortedPaths: (([URL]) -> Void)? = nil) throws -> [URL] {
        func mark() -> Double { onObservation == nil ? 0 : ProcessInfo.processInfo.systemUptime }
        func report(_ stage: CanonicalObservationStage, since start: Double,
                    detail: String? = nil, pathCount: Int? = nil, folderCount: Int? = nil) {
            guard let onObservation else { return }
            onObservation(CanonicalObservationMeasurement(stage: stage, detail: detail,
                milliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1_000,
                pathCount: pathCount, folderCount: folderCount))
        }
        let rootStart = mark()
        let folders = ["pages", "screens", "scopes", "components", "tokens", "assets", "interactions", "motions", "fixtures", "targets"]
        var paths = [root.appendingPathComponent("hamii.json")]
        let agentProfiles = root.appendingPathComponent("hamii-agent-profiles.json")
        if manager.fileExists(atPath: agentProfiles.path) { paths.append(agentProfiles) }
        report(.canonicalRootFileChecks, since: rootStart, pathCount: paths.count)
        for folder in folders {
            let directory = root.appendingPathComponent(folder, isDirectory: true)
            let existenceStart = mark()
            let exists = manager.fileExists(atPath: directory.path)
            report(.folderExistenceChecks, since: existenceStart, detail: folder,
                   pathCount: exists ? 1 : 0, folderCount: 1)
            guard exists else { continue }
            let listingStart = mark()
            let listed = try manager.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isSymbolicLinkKey])
            report(.contentsOfDirectory, since: listingStart, detail: folder,
                   pathCount: listed.count, folderCount: 1)
            let filterStart = mark()
            let json = listed.filter { $0.pathExtension == "json" }
            report(.jsonFiltering, since: filterStart, detail: folder,
                   pathCount: json.count, folderCount: 1)
            let reconstructionStart = mark()
            paths += json.map { directory.appendingPathComponent($0.lastPathComponent) }
            report(.rootBasedURLReconstruction, since: reconstructionStart, detail: folder,
                   pathCount: json.count, folderCount: 1)
        }
        let symlinkStart = mark()
        for path in paths {
            guard try path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw CanonicalError.invalidClientEpoch
            }
        }
        report(.symlinkResourceValueChecks, since: symlinkStart,
               pathCount: paths.count, folderCount: folders.count)
        onUnsortedPaths?(paths)
        let sortStart = mark()
        let sorted = sortCanonicalPaths(paths, variant: sortVariant)
        report(.pathSorting, since: sortStart, pathCount: sorted.count, folderCount: folders.count)
        return sorted
    }

    private func appendHash(_ value: Data, to hash: inout SHA256) {
        var length = UInt64(value.count).bigEndian
        withUnsafeBytes(of: &length) { hash.update(data: $0) }
        hash.update(data: value)
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

    private func readAll<T: Decodable & Identifiable>(_ folder: String,
        onObservation: CanonicalObservationRecorder? = nil) throws -> [T] where T.ID == EntityID {
        let directory = root.appendingPathComponent(folder, isDirectory: true)
        let enumerationStart = onObservation == nil ? 0 : ProcessInfo.processInfo.systemUptime
        let paths: [URL]
        if manager.fileExists(atPath: directory.path) {
            paths = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } else {
            paths = []
        }
        if let onObservation {
            onObservation(CanonicalObservationMeasurement(stage: .directoryEnumeration, detail: folder,
                milliseconds: (ProcessInfo.processInfo.systemUptime - enumerationStart) * 1_000))
        }
        var readMilliseconds = 0.0
        var decodeMilliseconds = 0.0
        var bytesRead = 0
        let values: [T] = try paths.map { url in
            let readStart = onObservation == nil ? 0 : ProcessInfo.processInfo.systemUptime
            let data = try Data(contentsOf: url)
            if onObservation != nil {
                readMilliseconds += (ProcessInfo.processInfo.systemUptime - readStart) * 1_000
                bytesRead += data.count
            }
            let decodeStart = onObservation == nil ? 0 : ProcessInfo.processInfo.systemUptime
            let value = try JSONDecoder().decode(T.self, from: data)
            if onObservation != nil {
                decodeMilliseconds += (ProcessInfo.processInfo.systemUptime - decodeStart) * 1_000
            }
            guard url.deletingPathExtension().lastPathComponent == value.id.rawValue else {
                throw CanonicalError.filenameMismatch(url.lastPathComponent)
            }
            return value
        }
        if let onObservation {
            onObservation(CanonicalObservationMeasurement(stage: .entityBytesRead, detail: folder,
                milliseconds: readMilliseconds, bytes: bytesRead))
            onObservation(CanonicalObservationMeasurement(stage: .entityDecode, detail: folder,
                milliseconds: decodeMilliseconds))
        }
        return values
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
