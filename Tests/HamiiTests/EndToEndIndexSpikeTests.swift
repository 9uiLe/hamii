import Foundation
import XCTest
import HamiiCore
import HamiiFormat
@testable import HamiiIndex

/// Current full-rebuild path timing; not a chosen CanonicalSnapshot or incremental design.
final class EndToEndIndexSpikeTests: XCTestCase {
    private func timed<T>(_ operation: () throws -> T) rethrows -> (T, Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = try operation()
        return (value, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }

    private func percentile(_ samples: [Double], _ fraction: Double) -> Double {
        let sorted = samples.sorted()
        return sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)]
    }

    func testCurrentFullRebuildPipelineTimings() throws {
        guard let resultPath = ProcessInfo.processInfo.environment["HAMII_E2E_SPIKE_RESULT"] else {
            throw XCTSkip("Run with HAMII_E2E_SPIKE_RESULT to collect the pipeline benchmark")
        }
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sample = repoRoot.appendingPathComponent("Samples/Starter")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let project = temporary.appendingPathComponent("Project")
        try FileManager.default.copyItem(at: sample, to: project)
        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", project.path] + arguments
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " "))
        }
        try git(["init", "-q", "-b", "main"])
        try git(["add", "-A"])
        try git(["-c", "user.name=Spike", "-c", "user.email=spike@example.invalid", "commit", "-qm", "baseline"])
        let repository = CanonicalRepository(root: project)
        let baseline = try repository.load()
        let consumer = try XCTUnwrap(baseline.scopes.first?.id)
        let calculator = GitCanonicalRevisionCalculator()
        let index = try LocalIndex(projectRoot: project, documentID: baseline.id, revisionCalculator: calculator,
                                   storageRoot: temporary.appendingPathComponent("Indexes"))
        let keys = ["preRevision", "canonicalLoad", "postRevision", "fullProjection", "rebuildAggregate", "publishVerification", "firstQuery", "total"]
        var samples = Dictionary(uniqueKeysWithValues: keys.map { ($0, [Double]()) })
        for _ in 0..<15 {
            let start = DispatchTime.now().uptimeNanoseconds
            let (before, preMs) = try timed { try calculator.current(at: project) }
            let (document, loadMs) = try timed { try repository.load() }
            let (stable, postMs) = try timed { try calculator.current(at: project) }
            XCTAssertEqual(before, stable)
            let (projection, projectionMs) = timed { IndexProjection(document: document) }
            XCTAssertEqual(projection.components.count, document.components.count)
            let (_, rebuildMs) = try timed { try index.rebuild(from: document, canonicalRevision: stable) }
            let (published, verifyMs) = try timed { try calculator.current(at: project) }
            XCTAssertEqual(stable, published)
            let (hits, queryMs) = try timed {
                try index.components(matching: "Button", consumerScopeID: consumer,
                                     documentID: document.id, revision: document.revision)
            }
            XCTAssertTrue(hits.isEmpty)
            let values = ["preRevision": preMs, "canonicalLoad": loadMs, "postRevision": postMs,
                          "fullProjection": projectionMs, "rebuildAggregate": rebuildMs,
                          "publishVerification": verifyMs, "firstQuery": queryMs,
                          "total": Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000]
            for key in keys { samples[key, default: []].append(values[key]!) }
        }
        let timing: [String: Any] = Dictionary(uniqueKeysWithValues: keys.map { key in
            let raw = samples[key]!
            return (key, ["runs": raw.count, "rawMs": raw,
                          "p50Ms": percentile(raw, 0.5), "p95Ms": percentile(raw, 0.95)] as [String: Any])
        })
        let result: [String: Any] = [
            "environment": "macOS 26.2 arm64, Swift 6.4 debug XCTest, disposable Starter copy in independent Git repo, 8 Canonical JSON, 15 in-process runs",
            "timings": timing,
            "limits": "Current full rebuild path only. canonicalLoad is not a proven CanonicalSnapshot. rebuildAggregate recomputes IndexProjection and includes SQLite write/commit; fullProjection is separately measured and duplicated for instrumentation. First query includes revision calculation. No CLI startup or external writer.",
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: resultPath))
    }
}
