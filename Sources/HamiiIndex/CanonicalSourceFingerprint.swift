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
        let status = try git(root, ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all", "--ignored=matching", "--"] + gitPaths)
        if status.status == 0 {
            var oid: Data?
            var changed: [Data] = []
            var skipOriginal = false
            for record in status.output.split(separator: 0) {
                if skipOriginal { skipOriginal = false; continue }
                if record.starts(with: Data("# branch.oid ".utf8)) {
                    oid = Data(record.dropFirst("# branch.oid ".utf8.count))
                } else if record.starts(with: Data("# ".utf8)) {
                    continue
                } else if record.starts(with: Data("1 ".utf8)) {
                    changed.append(try pathField(record, index: 8))
                } else if record.starts(with: Data("2 ".utf8)) {
                    changed.append(try pathField(record, index: 9))
                    skipOriginal = true
                } else if record.starts(with: Data("? ".utf8)) || record.starts(with: Data("! ".utf8)) {
                    changed.append(Data(record.dropFirst(2)))
                } else {
                    throw IndexError.stale
                }
            }
            guard let oid, !skipOriginal else { throw IndexError.stale }
            append(oid, to: &hash)
            for raw in changed.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                guard let name = String(data: raw, encoding: .utf8), safe(name) else { throw IndexError.stale }
                let url = root.appendingPathComponent(name)
                append(raw, to: &hash)
                if FileManager.default.fileExists(atPath: url.path) {
                    guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw IndexError.stale }
                    append(try Data(contentsOf: url), to: &hash)
                } else {
                    append(Data("<deleted>".utf8), to: &hash)
                }
            }
        } else {
            // Tests may use an isolated canonical directory without a Git repository.
            for name in try canonicalFiles(at: root) {
                append(Data(name.utf8), to: &hash)
                append(try Data(contentsOf: root.appendingPathComponent(name)), to: &hash)
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func pathField(_ record: Data.SubSequence, index: Int) throws -> Data {
        let fields = record.split(separator: 32, maxSplits: index, omittingEmptySubsequences: false)
        guard fields.count == index + 1, !fields[index].isEmpty else { throw IndexError.stale }
        return Data(fields[index])
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

    private static func git(_ root: URL, _ arguments: [String]) throws -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }
}
