import Foundation

/// Captures the historical Canonical JSON inputs without interpreting them as Current Core types.
/// Git/worktree coordination belongs to the caller.
public enum MigrationRepositoryInput {
    public static func load(from root: URL) throws -> MigrationFileSet {
        let manager = FileManager.default
        var files: [String: Data] = [:]
        for name in ["hamii.json", "hamii-agent-profiles.json"] {
            let url = root.appendingPathComponent(name)
            if manager.fileExists(atPath: url.path) { files[name] = try checkedBytes(at: url, relativePath: name) }
        }
        for folder in ["pages", "screens", "scopes", "components", "tokens", "assets", "interactions", "motions", "fixtures", "targets"] {
            let directory = root.appendingPathComponent(folder, isDirectory: true)
            guard manager.fileExists(atPath: directory.path) else { continue }
            guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw MigrationEdgeFailure.invalidInput("Canonical directory is a symlink: \(folder)")
            }
            for url in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
                where url.pathExtension == "json" {
                let path = "\(folder)/\(url.lastPathComponent)"
                files[path] = try checkedBytes(at: url, relativePath: path)
            }
        }
        return MigrationFileSet(files: files)
    }

    private static func checkedBytes(at url: URL, relativePath: String) throws -> Data {
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw MigrationEdgeFailure.invalidInput("Canonical symlink is not a migration input: \(relativePath)")
        }
        return try Data(contentsOf: url)
    }
}
