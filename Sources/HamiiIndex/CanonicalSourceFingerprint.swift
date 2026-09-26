import CryptoKit
import Foundation

/// A content identity for the canonical JSON visible in one Git working tree.
/// Git supplies clean tracked content through HEAD; dirty and untracked bytes
/// are included without reading every clean shard on each query.
public enum CanonicalSourceFingerprint {
    private static let paths = ["hamii.json", "pages", "screens", "scopes", "components", "tokens", "assets", "interactions", "motions", "fixtures", "targets"]
    private static let gitPaths = ["hamii.json"] + paths.dropFirst().map { ":(glob)\($0)/*.json" }

    public static func current(at root: URL) throws -> String {
        var hash = SHA256()
        let head = try git(root, ["rev-parse", "--verify", "HEAD"], allowFailure: true)
        if head.status == 0 {
            append(head.output, to: &hash)
            let diff = try git(root, ["diff", "--no-ext-diff", "--no-textconv", "--binary", "HEAD", "--"] + gitPaths)
            append(diff.output, to: &hash)
            let untracked = try git(root, ["ls-files", "--others", "-z", "--"] + gitPaths).output
            for raw in untracked.split(separator: 0).sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                let name = String(decoding: raw, as: UTF8.self)
                guard safe(name) else { throw IndexError.stale }
                append(Data(raw), to: &hash)
                append(try Data(contentsOf: root.appendingPathComponent(name)), to: &hash)
            }
        } else {
            // A new hamii project has a Git repository but no HEAD yet.
            for name in try canonicalFiles(at: root) {
                append(Data(name.utf8), to: &hash)
                append(try Data(contentsOf: root.appendingPathComponent(name)), to: &hash)
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func append(_ data: Data, to hash: inout SHA256) {
        var length = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &length) { hash.update(data: $0) }
        hash.update(data: data)
    }

    private static func safe(_ path: String) -> Bool {
        !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }

    private static func canonicalFiles(at root: URL) throws -> [String] {
        var result: [String] = []
        for path in paths {
            let url = root.appendingPathComponent(path)
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else { continue }
            if directory.boolValue {
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) where child.pathExtension == "json" {
                    result.append("\(path)/\(child.lastPathComponent)")
                }
            } else if path == "hamii.json" {
                result.append(path)
            }
        }
        return result.sorted()
    }

    private static func git(_ root: URL, _ arguments: [String], allowFailure: Bool = false) throws -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 && !allowFailure { throw IndexError.stale }
        return (process.terminationStatus, output)
    }
}
