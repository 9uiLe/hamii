import CryptoKit
import Darwin
import Foundation

enum TransactionStep {
    case prepared
    case ready
    case applied(String)
    case complete
}

private struct TransactionEntry: Codable {
    var path: String
    var oldHash: String?
    var newHash: String?
}

private struct TransactionPlan: Codable {
    var oldRevision: Int?
    var newRevision: Int
    var entries: [TransactionEntry]
}

private struct RevisionHeader: Decodable { var revision: Int }

final class CanonicalTransaction {
    private let root: URL
    private let manager = FileManager.default
    private let hook: ((TransactionStep) throws -> Void)?
    private let folders = ["pages", "screens", "scopes", "components", "tokens", "assets", "interactions", "motions", "fixtures", "targets"]

    init(root: URL, hook: ((TransactionStep) throws -> Void)? = nil) {
        self.root = root
        self.hook = hook
    }

    func preflight(expectedOldFiles: [String: Data]) throws {
        let actual = try currentFiles()
        guard actual == expectedOldFiles else {
            let mismatched = Set(actual.keys).union(expectedOldFiles.keys)
                .filter { actual[$0] != expectedOldFiles[$0] }.sorted()
            throw CanonicalError.transactionConflict(mismatched.first ?? "hamii.json")
        }
    }

    func commit(newFiles: [String: Data], expectedOldFiles: [String: Data], oldRevision: Int?, newRevision: Int) throws {
        try recoverIfNeeded()
        try preflight(expectedOldFiles: expectedOldFiles)
        let oldFiles = expectedOldFiles
        let paths = Set(oldFiles.keys).union(newFiles.keys).filter { oldFiles[$0] != newFiles[$0] }.sorted()
        guard paths.contains("hamii.json") else { throw CanonicalError.transactionCorrupt("Manifest revision did not change") }
        let local = root.appendingPathComponent(".hamii", isDirectory: true)
        let preparing = local.appendingPathComponent("transaction.prepare", isDirectory: true)
        let ready = local.appendingPathComponent("transaction.ready", isDirectory: true)
        try manager.createDirectory(at: local, withIntermediateDirectories: true)
        if manager.fileExists(atPath: preparing.path) { try manager.removeItem(at: preparing) }
        try manager.createDirectory(at: preparing, withIntermediateDirectories: true)

        let entries = paths.map { path in
            TransactionEntry(path: path, oldHash: oldFiles[path].map(Self.hash), newHash: newFiles[path].map(Self.hash))
        }
        let plan = TransactionPlan(oldRevision: oldRevision, newRevision: newRevision, entries: entries)
        for entry in entries {
            if let old = oldFiles[entry.path] { try writeSnapshot(old, relativePath: "old/\(entry.path)", under: preparing) }
            if let new = newFiles[entry.path] { try writeSnapshot(new, relativePath: "new/\(entry.path)", under: preparing) }
        }
        try writeSnapshot(JSONEncoder().encode(plan), relativePath: "plan.json", under: preparing)
        try syncTree(preparing)
        try hook?(.prepared)
        try replace(preparing, with: ready)
        try syncDirectory(local)
        try hook?(.ready)
        try apply(plan: plan, journal: ready, useNew: true)
        try finish(ready)
    }

    func recoverIfNeeded() throws {
        let local = root.appendingPathComponent(".hamii", isDirectory: true)
        let preparing = local.appendingPathComponent("transaction.prepare", isDirectory: true)
        let ready = local.appendingPathComponent("transaction.ready", isDirectory: true)
        let complete = local.appendingPathComponent("transaction.complete", isDirectory: true)
        if manager.fileExists(atPath: complete.path) { try manager.removeItem(at: complete) }
        if manager.fileExists(atPath: preparing.path) { try manager.removeItem(at: preparing) }
        guard manager.fileExists(atPath: ready.path) else { return }
        try cleanupTemporaryFiles()
        let plan: TransactionPlan
        do { plan = try JSONDecoder().decode(TransactionPlan.self, from: Data(contentsOf: ready.appendingPathComponent("plan.json"))) }
        catch { throw CanonicalError.transactionCorrupt("Journal plan cannot be read") }
        guard plan.entries.contains(where: { $0.path == "hamii.json" }), Set(plan.entries.map(\.path)).count == plan.entries.count,
              plan.entries.allSatisfy({ validPath($0.path) }) else {
            throw CanonicalError.transactionCorrupt("Journal contains invalid or duplicate paths")
        }
        let marker = root.appendingPathComponent("hamii.json")
        let current = try readIfPresent(marker)
        let oldManifest = try snapshot(path: "hamii.json", hash: plan.entries.first(where: { $0.path == "hamii.json" })!.oldHash, under: ready, side: "old")
        let newManifest = try snapshot(path: "hamii.json", hash: plan.entries.first(where: { $0.path == "hamii.json" })!.newHash, under: ready, side: "new")
        guard (try oldManifest.map { try JSONDecoder().decode(RevisionHeader.self, from: $0).revision }) == plan.oldRevision,
              (try newManifest.map { try JSONDecoder().decode(RevisionHeader.self, from: $0).revision }) == plan.newRevision else {
            throw CanonicalError.transactionCorrupt("Journal revisions do not match their manifests")
        }
        let useNew: Bool
        if current == newManifest { useNew = true }
        else if current == oldManifest { useNew = false }
        else { throw CanonicalError.transactionConflict("hamii.json") }
        try apply(plan: plan, journal: ready, useNew: useNew)
        try finish(ready)
    }

    private func apply(plan: TransactionPlan, journal: URL, useNew: Bool) throws {
        for entry in plan.entries.sorted(by: { $0.path == "hamii.json" ? false : ($1.path == "hamii.json" ? true : $0.path < $1.path) }) {
            let old = try snapshot(path: entry.path, hash: entry.oldHash, under: journal, side: "old")
            let new = try snapshot(path: entry.path, hash: entry.newHash, under: journal, side: "new")
            let destination = root.appendingPathComponent(entry.path)
            let current = try readIfPresent(destination)
            guard current == old || current == new else { throw CanonicalError.transactionConflict(entry.path) }
            let desired = useNew ? new : old
            if current != desired { try install(desired, at: destination) }
            try hook?(.applied(entry.path))
        }
    }

    private func finish(_ ready: URL) throws {
        let local = ready.deletingLastPathComponent()
        let complete = local.appendingPathComponent("transaction.complete", isDirectory: true)
        try replace(ready, with: complete)
        try syncDirectory(local)
        try hook?(.complete)
        try manager.removeItem(at: complete)
        try syncDirectory(local)
    }

    private func currentFiles() throws -> [String: Data] {
        var files: [String: Data] = [:]
        let manifest = root.appendingPathComponent("hamii.json")
        files["hamii.json"] = try readIfPresent(manifest)
        for folder in folders {
            let directory = root.appendingPathComponent(folder, isDirectory: true)
            guard manager.fileExists(atPath: directory.path) else { continue }
            for file in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                files["\(folder)/\(file.lastPathComponent)"] = try Data(contentsOf: file)
            }
        }
        return files
    }

    private func cleanupTemporaryFiles() throws {
        for directory in [root] + folders.map({ root.appendingPathComponent($0, isDirectory: true) }) where manager.fileExists(atPath: directory.path) {
            for file in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where file.lastPathComponent.hasPrefix(".hamii-") && file.pathExtension == "tmp" {
                try manager.removeItem(at: file)
            }
        }
    }

    private func snapshot(path: String, hash: String?, under journal: URL, side: String) throws -> Data? {
        guard let hash else { return nil }
        let url = journal.appendingPathComponent("\(side)/\(path)")
        guard let data = try? Data(contentsOf: url), Self.hash(data) == hash else {
            throw CanonicalError.transactionCorrupt("Journal snapshot is missing or invalid: \(path)")
        }
        return data
    }

    private func writeSnapshot(_ data: Data, relativePath: String, under directory: URL) throws {
        let url = directory.appendingPathComponent(relativePath)
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        try syncFile(url)
    }

    private func install(_ data: Data?, at destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data {
            let temporary = directory.appendingPathComponent(".hamii-\(UUID().uuidString).tmp")
            try data.write(to: temporary)
            try syncFile(temporary)
            try replace(temporary, with: destination)
        } else if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try syncDirectory(directory)
    }

    private func readIfPresent(_ url: URL) throws -> Data? {
        guard manager.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private func validPath(_ path: String) -> Bool {
        if path == "hamii.json" { return true }
        let parts = path.split(separator: "/")
        return parts.count == 2 && folders.contains(String(parts[0])) &&
            String(parts[1]).range(of: "^[a-zA-Z0-9_-]+\\.json$", options: .regularExpression) != nil
    }

    private func syncTree(_ directory: URL) throws {
        for child in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) where (try child.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
            try syncTree(child)
        }
        try syncDirectory(directory)
    }

    private func syncFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private func syncDirectory(_ url: URL) throws { try syncFile(url) }

    private func replace(_ source: URL, with destination: URL) throws {
        guard rename(source.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
