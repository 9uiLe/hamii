import Darwin
import Foundation

struct ManagedGitTransition: Codable {
    let sourceBranch: String
    let sourceHead: String
    let targetBranch: String
    let targetHead: String
}

/// The only production owner of the cooperative worktree lock and local
/// observation epoch. Callers hold this boundary across recovery, state
/// changes, validation, and observation; raw Git and external editors do not.
public struct WorktreeCoordinator {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public func withExclusive<T>(_ operation: () throws -> T) throws -> T {
        let local = root.appendingPathComponent(".hamii", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let descriptor = open(local.appendingPathComponent("write.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileReadUnknown) }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    var epochURL: URL { root.appendingPathComponent(".hamii/client-observation-epoch") }
    private var transitionURL: URL { root.appendingPathComponent(".hamii/managed-git-transition.json") }
    var mergePublicationURL: URL { root.appendingPathComponent(".hamii/merge-publication.pending.json") }

    // These methods are called only while withExclusive holds the lock.
    func clientEpoch() throws -> String {
        if !FileManager.default.fileExists(atPath: epochURL.path) { try invalidateClientObservations() }
        let value = try String(contentsOf: epochURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: value) != nil else { throw CanonicalError.invalidClientEpoch }
        return value
    }

    func invalidateClientObservations() throws {
        try Data((UUID().uuidString + "\n").utf8).write(to: epochURL, options: .atomic)
    }

    func requireReady() throws {
        guard !FileManager.default.fileExists(atPath: transitionURL.path),
              !mergePublicationPending() else {
            throw CanonicalError.managedGitPending
        }
    }

    func mergePublicationPending() -> Bool {
        FileManager.default.fileExists(atPath: mergePublicationURL.path)
    }

    func mergePublicationRecord() throws -> Data? {
        guard mergePublicationPending() else { return nil }
        return try Data(contentsOf: mergePublicationURL)
    }

    func beginMergePublication(_ record: Data) throws {
        try requireReady()
        try invalidateClientObservations()
        try sync(epochURL)
        try writeMergePublicationRecord(record)
    }

    func writeMergePublicationRecord(_ record: Data) throws {
        try record.write(to: mergePublicationURL, options: .atomic)
        try sync(mergePublicationURL)
        try sync(mergePublicationURL.deletingLastPathComponent())
    }

    func finishMergePublication() throws {
        try FileManager.default.removeItem(at: mergePublicationURL)
        try sync(mergePublicationURL.deletingLastPathComponent())
    }

    private func sync(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    func pendingGitTransition() throws -> ManagedGitTransition? {
        guard FileManager.default.fileExists(atPath: transitionURL.path) else { return nil }
        do { return try JSONDecoder().decode(ManagedGitTransition.self, from: Data(contentsOf: transitionURL)) }
        catch { throw CanonicalError.managedGitPending }
    }

    func beginGitTransition(_ transition: ManagedGitTransition) throws {
        try requireReady()
        // Invalidate clients before Git can touch Canonical files. A stopped
        // transition remains pending until explicit recovery validates it.
        try invalidateClientObservations()
        try JSONEncoder().encode(transition).write(to: transitionURL, options: .atomic)
    }

    func finishGitTransition() throws {
        try FileManager.default.removeItem(at: transitionURL)
    }
}
