import Darwin
import Foundation

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
}
