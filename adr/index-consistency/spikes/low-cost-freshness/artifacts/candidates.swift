import CryptoKit
import Foundation

// Spike-only probes. The Git candidate is compiled from the production source.
enum IndexError: Error { case stale, unverifiableSource }

private let canonicalDirectories = ["pages", "screens", "scopes", "components", "tokens", "assets", "interactions", "motions", "fixtures", "targets"]

private func paths(at root: URL) throws -> [URL] {
    let fm = FileManager.default
    var result: [URL] = []
    let manifest = root.appendingPathComponent("hamii.json")
    guard fm.fileExists(atPath: manifest.path) else { throw IndexError.unverifiableSource }
    result.append(manifest)
    for directory in canonicalDirectories {
        let base = root.appendingPathComponent(directory)
        guard fm.fileExists(atPath: base.path) else { continue }
        // CanonicalRepository.readAll only reads immediate JSON children.
        for url in try fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
            result.append(url)
        }
    }
    return result.sorted { $0.path < $1.path }
}

private func append(_ data: Data, to hash: inout SHA256) {
    var length = UInt64(data.count).bigEndian
    withUnsafeBytes(of: &length) { hash.update(data: $0) }
    hash.update(data: data)
}

private func digest(_ hash: SHA256) -> String {
    hash.finalize().map { String(format: "%02x", $0) }.joined()
}

private func fullBytePass(at root: URL, afterRead: ((URL) throws -> Void)? = nil) throws -> String {
    var hash = SHA256()
    for url in try paths(at: root) {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw IndexError.unverifiableSource }
        append(Data(url.path.dropFirst(root.path.count).utf8), to: &hash)
        append(try Data(contentsOf: url), to: &hash)
        try afterRead?(url)
    }
    return digest(hash)
}

private func fullByteRevision(at root: URL) throws -> String {
    let first = try fullBytePass(at: root)
    let second = try fullBytePass(at: root)
    guard first == second else { throw IndexError.stale }
    return second
}

// Deterministic interleaving: both passes read A=0,B=1 although no such
// complete filesystem state exists. The writes are A=1 then B=1; reset is
// B=0 then A=0. This hook is only reachable through the spike's race command.
private func inconsistentSnapshotProbe(at root: URL) throws -> [String: Any] {
    let a = root.appendingPathComponent("components/a.json")
    let b = root.appendingPathComponent("components/b.json")
    func write(_ url: URL, _ value: Int) throws { try Data("{\"value\":\(value)}\n".utf8).write(to: url) }
    try write(a, 0); try write(b, 0)
    let states = [(0, 0), (1, 0), (1, 1)]
    var stable: [String] = []
    for (av, bv) in states {
        try write(a, av); try write(b, bv)
        stable.append(try fullBytePass(at: root))
    }
    try write(a, 0); try write(b, 0)
    let hook: (URL) throws -> Void = { url in
        if url.lastPathComponent == "a.json" { try write(a, 1); try write(b, 1) }
    }
    let first = try fullBytePass(at: root, afterRead: hook)
    try write(b, 0); try write(a, 0)
    let second = try fullBytePass(at: root, afterRead: hook)
    let final = try fullBytePass(at: root)
    return ["passesEqual": first == second, "acceptedDigestMatchesFinalBytes": first == final,
            "acceptedDigestMatchesAnyStableState": stable.contains(first),
            "writeOrder": "A=1,B=1; reset B=0,A=0; repeat"]
}

// Negative control: cheap metadata cannot identify Canonical bytes reliably.
private func metadataRevision(at root: URL) throws -> String {
    var hash = SHA256()
    for url in try paths(at: root) {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, let modified = values.contentModificationDate else { throw IndexError.unverifiableSource }
        append(Data(url.path.dropFirst(root.path.count).utf8), to: &hash)
        append(Data("\(size):\(modified.timeIntervalSince1970)".utf8), to: &hash)
    }
    return digest(hash)
}

private func revision(_ candidate: String, at root: URL) throws -> String {
    switch candidate {
    case "guarded-git": return try GitCanonicalRevisionCalculator().current(at: root).rawValue
    case "double-byte-scan": return try fullByteRevision(at: root)
    case "size-mtime": return try metadataRevision(at: root)
    default: throw IndexError.unverifiableSource
    }
}

private func percentile(_ sorted: [Double], _ rank: Double) -> Double {
    sorted[max(0, Int(ceil(Double(sorted.count) * rank)) - 1)]
}

@main struct Main {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 3 else { fatalError("usage: probe <identity|bench> <candidate|all> <root> [runs]") }
        let root = URL(fileURLWithPath: args[2]).standardizedFileURL
        if args[0] == "race" {
            let result = try inconsistentSnapshotProbe(at: root)
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return
        }
        if args[0] == "identity" {
            do {
                print(try revision(args[1], at: root))
            } catch {
                print("REJECT:\(error)")
            }
            return
        }
        guard args[0] == "bench", args[1] == "all", args.count == 4, let runs = Int(args[3]), runs > 0 else {
            fatalError("invalid benchmark arguments")
        }
        let names = ["guarded-git", "double-byte-scan", "size-mtime"]
        var samples: [String: [Double]] = [:]
        for name in names { _ = try revision(name, at: root); samples[name] = [] }
        for run in 0..<runs {
            for offset in 0..<names.count {
                let name = names[(run + offset) % names.count]
                let start = DispatchTime.now().uptimeNanoseconds
                _ = try revision(name, at: root)
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                samples[name, default: []].append(elapsed)
            }
        }
        var output: [String: Any] = [:]
        for name in names {
            let raw = samples[name]!
            let sorted = raw.sorted()
            output[name] = ["raw_ms": raw, "p50_ms": percentile(sorted, 0.50), "p95_ms": percentile(sorted, 0.95)] as [String: Any]
        }
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
