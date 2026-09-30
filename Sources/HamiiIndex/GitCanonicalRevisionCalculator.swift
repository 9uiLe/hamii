import CryptoKit
import Foundation
import HamiiFormat

struct GitCanonicalRevisionProfile {
    let stageMilliseconds: [String: Double]
    let gitSubprocessCount: Int
    let trackedCanonicalFileCount: Int
    let changedCanonicalFileCount: Int
    let workingTreeHashedBytes: Int
}

private final class GitRevisionProfileRecorder {
    var stageMilliseconds: [String: Double] = [:]
    var gitSubprocessCount = 0
    var trackedCanonicalFileCount = 0
    var changedCanonicalFileCount = 0
    var workingTreeHashedBytes = 0

    func measure<T>(_ stage: String, _ body: () throws -> T) rethrows -> T {
        let start = ProcessInfo.processInfo.systemUptime
        defer { stageMilliseconds[stage, default: 0] += (ProcessInfo.processInfo.systemUptime - start) * 1_000 }
        return try body()
    }

    var result: GitCanonicalRevisionProfile {
        GitCanonicalRevisionProfile(stageMilliseconds: stageMilliseconds,
            gitSubprocessCount: gitSubprocessCount,
            trackedCanonicalFileCount: trackedCanonicalFileCount,
            changedCanonicalFileCount: changedCanonicalFileCount,
            workingTreeHashedBytes: workingTreeHashedBytes)
    }
}

/// A content identity for the canonical JSON visible in one Git working tree.
/// Git supplies clean tracked content through HEAD; dirty and untracked bytes
/// are included without reading every clean shard on each query.
public struct GitCanonicalRevisionCalculator: CanonicalRevisionCalculating {
    private let afterInitialStatus: (() throws -> Void)?
    private let afterFlagsObserved: (() throws -> Void)?
    private let afterFilterObserved: (() throws -> Void)?
    public init() {
        afterInitialStatus = nil
        afterFlagsObserved = nil
        afterFilterObserved = nil
    }
    init(afterInitialStatus: @escaping () throws -> Void) {
        self.afterInitialStatus = afterInitialStatus
        afterFlagsObserved = nil
        afterFilterObserved = nil
    }
    #if DEBUG
    init(afterFlagsObserved: @escaping () throws -> Void) {
        afterInitialStatus = nil
        self.afterFlagsObserved = afterFlagsObserved
        afterFilterObserved = nil
    }
    init(afterFilterObserved: @escaping () throws -> Void) {
        afterInitialStatus = nil
        afterFlagsObserved = nil
        self.afterFilterObserved = afterFilterObserved
    }
    #endif
    private static let paths = ["hamii.json", "pages", "screens", "scopes", "components", "tokens", "assets", "interactions", "motions", "fixtures", "targets"]
    private static let gitPaths = ["hamii.json"] + paths.dropFirst().map { ":(glob)\($0)/*.json" }

    public func current(at root: URL) throws -> CanonicalRevision {
        try CanonicalRevision(Self.calculate(at: root, afterInitialStatus: afterInitialStatus,
            afterFlagsObserved: afterFlagsObserved, afterFilterObserved: afterFilterObserved, profile: nil))
    }

    #if DEBUG
    func profiledCurrent(at root: URL) throws -> (revision: CanonicalRevision, profile: GitCanonicalRevisionProfile) {
        let recorder = GitRevisionProfileRecorder()
        let revision = try CanonicalRevision(Self.calculate(at: root, afterInitialStatus: afterInitialStatus,
            afterFlagsObserved: afterFlagsObserved, afterFilterObserved: afterFilterObserved, profile: recorder))
        return (revision, recorder.result)
    }
    #endif

    private static func measured<T>(_ stage: String, profile: GitRevisionProfileRecorder?,
                                    _ body: () throws -> T) rethrows -> T {
        guard let profile else { return try body() }
        return try profile.measure(stage, body)
    }

    private static func calculate(at root: URL, afterInitialStatus: (() throws -> Void)?,
                                  afterFlagsObserved: (() throws -> Void)?,
                                  afterFilterObserved: (() throws -> Void)?,
                                  profile: GitRevisionProfileRecorder?) throws -> String {
        let started = profile == nil ? 0 : ProcessInfo.processInfo.systemUptime
        defer {
            if let profile { profile.stageMilliseconds["total", default: 0] +=
                (ProcessInfo.processInfo.systemUptime - started) * 1_000 }
        }
        var hash = SHA256()
        let status = try measured("status1", profile: profile) {
            profile?.gitSubprocessCount += 1
            return try git(root, ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all",
                "--ignored=matching", "--"] + gitPaths)
        }
        try afterInitialStatus?()
        guard status.status == 0 else { throw IndexError.unverifiableSource }
        // Git omits working-tree edits to assume-unchanged and skip-worktree
        // paths from status. Refuse to identify such a source as current.
        let tracked = try measured("lsFiles", profile: profile) {
            profile?.gitSubprocessCount += 1
            return try git(root, ["ls-files", "-v", "-z", "--"] + gitPaths)
        }
        guard tracked.status == 0 else { throw IndexError.stale }
        let trackedPaths = try measured("trackedFlagsParse", profile: profile) {
            try tracked.output.split(separator: 0).map { record -> Data in
                guard record.count >= 3, record.first == 72, record.dropFirst().first == 32 else {
                    throw IndexError.unverifiableSource
                }
                return Data(record.dropFirst(2))
            }
        }
        profile?.trackedCanonicalFileCount = trackedPaths.count
        try afterFlagsObserved?()
        let attributeInput = measured("checkAttrInputPreparation", profile: profile) {
            var input = Data()
            for path in trackedPaths {
                input.append(path)
                input.append(0)
            }
            return input
        }
        if !trackedPaths.isEmpty {
            let attributes = try measured("checkAttr", profile: profile) {
                profile?.gitSubprocessCount += 1
                return try git(root, ["check-attr", "-z", "--stdin", "filter"], input: attributeInput)
            }
            guard attributes.status == 0 else { throw IndexError.unverifiableSource }
            try measured("attributeParse", profile: profile) {
                let fields = attributes.output.split(separator: 0, omittingEmptySubsequences: false)
                guard fields.count == trackedPaths.count * 3 + 1, fields.last?.isEmpty == true else {
                    throw IndexError.unverifiableSource
                }
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
        }
        try afterFilterObserved?()
        var oid: Data?
        var changed: [Data] = []
        var skipOriginal = false
        try measured("status1Parse", profile: profile) {
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
        }
        guard let oid, !skipOriginal else { throw IndexError.stale }
        append(oid, to: &hash)
        let sortedChanged = measured("changedPathSort", profile: profile) {
            changed.sorted(by: { $0.lexicographicallyPrecedes($1) })
        }
        profile?.changedCanonicalFileCount = sortedChanged.count
        try measured("changedWorkingTreeBytes", profile: profile) {
            for raw in sortedChanged {
                guard let name = String(data: raw, encoding: .utf8), safe(name) else { throw IndexError.stale }
                let url = root.appendingPathComponent(name)
                append(raw, to: &hash)
                if FileManager.default.fileExists(atPath: url.path) {
                    guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                        throw IndexError.stale
                    }
                    let bytes = try Data(contentsOf: url)
                    profile?.workingTreeHashedBytes += bytes.count
                    append(bytes, to: &hash)
                } else {
                    append(Data("<deleted>".utf8), to: &hash)
                }
            }
        }
        // A checkout can complete after the first status call while the
        // remaining Git calls still succeed. Refuse that mixed snapshot.
        let verification = try measured("status2", profile: profile) {
            profile?.gitSubprocessCount += 1
            return try git(root, ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all",
                "--ignored=matching", "--"] + gitPaths)
        }
        let unchanged = measured("status2Equality", profile: profile) {
            verification.status == 0 && verification.output == status.output
        }
        guard unchanged else { throw IndexError.stale }
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
        let result = try GitProcess.run(at: root, arguments, input: input)
        return (result.status, result.stdout)
    }
}
