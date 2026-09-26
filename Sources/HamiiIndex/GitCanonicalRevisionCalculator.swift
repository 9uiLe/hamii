import CryptoKit
import Foundation

/// A content identity for the canonical JSON visible in one Git working tree.
/// Git supplies clean tracked content through HEAD; dirty and untracked bytes
/// are included without reading every clean shard on each query.
public struct GitCanonicalRevisionCalculator: CanonicalRevisionCalculating {
    private let afterInitialStatus: (() throws -> Void)?
    public init() { afterInitialStatus = nil }
    init(afterInitialStatus: @escaping () throws -> Void) { self.afterInitialStatus = afterInitialStatus }
    private static let paths = ["hamii.json", "pages", "screens", "scopes", "components", "tokens", "assets", "interactions", "motions", "fixtures", "targets"]
    private static let gitPaths = ["hamii.json"] + paths.dropFirst().map { ":(glob)\($0)/*.json" }

    public func current(at root: URL) throws -> CanonicalRevision {
        try CanonicalRevision(Self.calculate(at: root, afterInitialStatus: afterInitialStatus))
    }

    private static func calculate(at root: URL, afterInitialStatus: (() throws -> Void)?) throws -> String {
        var hash = SHA256()
        let status = try git(root, ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all", "--ignored=matching", "--"] + gitPaths)
        try afterInitialStatus?()
        guard status.status == 0 else { throw IndexError.unverifiableSource }
        // Git omits working-tree edits to assume-unchanged and skip-worktree
        // paths from status. Refuse to identify such a source as current.
        let tracked = try git(root, ["ls-files", "-v", "-z", "--"] + gitPaths)
        guard tracked.status == 0 else { throw IndexError.stale }
        var attributeInput = Data()
        var trackedPaths: [Data] = []
        for record in tracked.output.split(separator: 0) {
            guard record.count >= 3, record.first == 72, record.dropFirst().first == 32 else { throw IndexError.unverifiableSource }
            let path = Data(record.dropFirst(2))
            trackedPaths.append(path)
            attributeInput.append(path)
            attributeInput.append(0)
        }
        if !trackedPaths.isEmpty {
            let attributes = try git(root, ["check-attr", "-z", "--stdin", "filter"], input: attributeInput)
            guard attributes.status == 0 else { throw IndexError.unverifiableSource }
            let fields = attributes.output.split(separator: 0, omittingEmptySubsequences: false)
            guard fields.count == trackedPaths.count * 3 + 1, fields.last?.isEmpty == true else { throw IndexError.unverifiableSource }
            for (index, path) in trackedPaths.enumerated() {
                guard fields[index * 3] == path, fields[index * 3 + 1] == Data("filter".utf8) else {
                    throw IndexError.unverifiableSource
                }
                let value = fields[index * 3 + 2]
                guard value == Data("unspecified".utf8) || value == Data("unset".utf8) else {
                    throw IndexError.unverifiableSource
                }
            }
        }
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
        // A checkout can complete after the first status call while the
        // remaining Git calls still succeed. Refuse that mixed snapshot.
        let verification = try git(root, ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all", "--ignored=matching", "--"] + gitPaths)
        guard verification.status == 0, verification.output == status.output else { throw IndexError.stale }
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

    private static func git(_ root: URL, _ arguments: [String], input: Data? = nil) throws -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        var inputFile: URL?
        var inputHandle: FileHandle?
        if let input {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("hamii-git-attrs-\(UUID().uuidString)")
            try input.write(to: file)
            inputFile = file
        }
        defer {
            try? inputHandle?.close()
            if let inputFile { try? FileManager.default.removeItem(at: inputFile) }
        }
        if let inputFile {
            inputHandle = try FileHandle(forReadingFrom: inputFile)
            process.standardInput = inputHandle
        }
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }
}
