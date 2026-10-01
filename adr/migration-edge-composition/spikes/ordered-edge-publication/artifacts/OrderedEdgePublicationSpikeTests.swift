// Test-only composition/publication harness. Installed v1->v2 edge is used unchanged.
import Foundation
import XCTest
import HamiiCore
import HamiiFormat
import HamiiMigrations

private enum SpikeFailure: Error, Equatable {
    case invalidCatalog, noPath, ambiguousPath, invalidFormat, mismatch, stopped(String), unknownSource
}

private struct SpikeEdge: Codable, Equatable, Hashable {
    var source: Int
    var target: Int
    var id: String { "\(source)->\(target)" }
}

private struct EdgeReceipt: Codable, Equatable {
    var sourceVersion: Int
    var targetVersion: Int
    var edgeID: String
    var inputIdentity: String
    var outputIdentity: String
    var classification: String
}

private struct ComposedFiles {
    var final: [String: Data]
    var receipts: [EdgeReceipt]
    var decisions: [MigrationResolutionDecision]
    var losses: [MigrationResolutionLoss]
}

private enum SpikeEdges {
    static let installedAndSynthetic = [SpikeEdge(source: 1, target: 2), SpikeEdge(source: 2, target: 3)]

    static func route(from source: Int, to target: Int, catalog: [SpikeEdge]) throws -> [SpikeEdge] {
        var pairs = Set<String>()
        var graph: [Int: [Int]] = [:]
        for edge in catalog {
            guard edge.source < edge.target, pairs.insert(edge.id).inserted else {
                throw SpikeFailure.invalidCatalog
            }
            graph[edge.source, default: []].append(edge.target)
        }
        // A forward-only format catalog cannot contain a cycle. Rejecting backward
        // edges is a deliberately narrow test-only policy, not a production route decision.
        if source == target { return [] }
        var routes: [[SpikeEdge]] = []
        func walk(_ current: Int, _ path: [SpikeEdge]) {
            if current == target { routes.append(path); return }
            for next in graph[current] ?? [] where next <= target {
                walk(next, path + [SpikeEdge(source: current, target: next)])
            }
        }
        walk(source, [])
        guard !routes.isEmpty else { throw SpikeFailure.noPath }
        guard routes.count == 1 else { throw SpikeFailure.ambiguousPath }
        return routes[0]
    }

    static func format(_ files: [String: Data]) throws -> Int {
        guard let bytes = files["hamii.json"],
              let manifest = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let version = manifest["formatVersion"] as? Int,
              let versions = manifest["versions"] as? [String: Any],
              versions["document"] as? Int == version else { throw SpikeFailure.invalidFormat }
        return version
    }

    static func identity(_ files: [String: Data]) -> String {
        CanonicalByteIdentity.compute(files: files).rawValue
    }

    static func syntheticV3(_ input: [String: Data]) throws -> [String: Data] {
        guard try format(input) == 2 else { throw SpikeFailure.invalidFormat }
        var output = input
        guard let manifestBytes = input["hamii.json"],
              var manifest = try JSONSerialization.jsonObject(with: manifestBytes) as? [String: Any],
              var versions = manifest["versions"] as? [String: Any] else { throw SpikeFailure.invalidFormat }
        manifest["formatVersion"] = 3
        versions["document"] = 3
        manifest["versions"] = versions
        output["hamii.json"] = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        for (path, bytes) in input where path.hasPrefix("screens/") && path.hasSuffix(".json") {
            guard var screen = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  screen["semantics"] == nil else { throw SpikeFailure.invalidFormat }
            screen["semantics"] = ["sources": [], "outputs": [], "relations": []]
            output[path] = try JSONSerialization.data(withJSONObject: screen, options: [.sortedKeys])
        }
        return output
    }

    static func validateV3(_ files: [String: Data]) throws -> (id: String, revision: Int) {
        guard try format(files) == 3,
              let manifestBytes = files["hamii.json"],
              let manifest = try JSONSerialization.jsonObject(with: manifestBytes) as? [String: Any],
              let id = (manifest["id"] as? [String: Any])?["rawValue"] as? String,
              let revision = manifest["revision"] as? Int else { throw SpikeFailure.invalidFormat }
        for (path, bytes) in files where path.hasPrefix("screens/") && path.hasSuffix(".json") {
            guard let screen = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let semantics = screen["semantics"] as? [String: Any],
                  Set(semantics.keys) == ["sources", "outputs", "relations"],
                  ["sources", "outputs", "relations"].allSatisfy({ (semantics[$0] as? [Any])?.isEmpty == true }) else {
                throw SpikeFailure.invalidFormat
            }
        }
        return (id, revision)
    }

    static func compose(_ source: [String: Data], route: [SpikeEdge],
                        sourceOID: String, resolution: MigrationResolutionManifest? = nil) throws -> ComposedFiles {
        guard resolution == nil || route.contains(where: { $0.source == 1 && $0.target == 2 }) else {
            throw SpikeFailure.mismatch
        }
        var files = source
        var receipts: [EdgeReceipt] = []
        var decisions: [MigrationResolutionDecision] = []
        var losses: [MigrationResolutionLoss] = []
        for edge in route {
            guard try format(files) == edge.source else { throw SpikeFailure.invalidFormat }
            let before = identity(files)
            let classification: String
            switch (edge.source, edge.target) {
            case (1, 2):
                let candidate: MigrationCandidate
                if let resolution {
                    let binding = MigrationResolutionSourceBinding(sourceOID: sourceOID,
                        sourceCanonicalIdentity: identity(source))
                    candidate = try MigrationRegistry.transform(MigrationFileSet(files: files),
                        applying: resolution, actualSourceBinding: binding)
                } else {
                    candidate = try MigrationRegistry.transform(MigrationFileSet(files: files))
                }
                guard candidate.edgePath == [edge.id], candidate.remainingUnresolved.isEmpty,
                      let kind = candidate.classification else { throw SpikeFailure.mismatch }
                files = candidate.files.files
                decisions = candidate.resolutionDecisions
                losses = candidate.losses
                classification = kind.rawValue
            case (2, 3):
                files = try syntheticV3(files)
                classification = MigrationClassification.lossless.rawValue
            default: throw SpikeFailure.noPath
            }
            guard try format(files) == edge.target else { throw SpikeFailure.invalidFormat }
            receipts.append(.init(sourceVersion: edge.source, targetVersion: edge.target,
                                  edgeID: edge.id, inputIdentity: before,
                                  outputIdentity: identity(files), classification: classification))
        }
        return .init(final: files, receipts: receipts, decisions: decisions, losses: losses)
    }
}

private struct SpikeReview: Codable {
    var sourceRef: String
    var sourceOID: String
    var sourceTreeOID: String
    var sourceIdentity: String
    var sourceFormat: Int
    var targetFormat: Int
    var receipts: [EdgeReceipt]
    var resolution: MigrationResolutionManifest?
    var decisions: [MigrationResolutionDecision]
    var losses: [MigrationResolutionLoss]
    var candidateOID: String
    var candidateTreeOID: String
    var candidateIdentity: String
    var changedPaths: [String]
    var retentionRef: String
}

private struct SpikePending: Codable {
    var review: SpikeReview
    var sourceGeneration: Int
    var candidateGeneration: Int
}

private struct SpikeIndex: Codable, Equatable {
    var id: String
    var sourceCanonicalIdentity: String
    var sourceGeneration: Int
    var documentID: String
    var documentRevision: Int
}

private enum SpikeRepository {
    static func git(_ root: URL, _ args: [String]) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = ["-C", root.path] + args
        let out = Pipe()
        let err = Pipe()
        task.standardOutput = out
        task.standardError = err
        try task.run()
        task.waitUntilExit()
        let output = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard task.terminationStatus == 0 else { throw SpikeFailure.mismatch }
        _ = error
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func bytes(_ root: URL) throws -> [String: Data] {
        try MigrationRepositoryInput.load(from: root).files
    }

    static func write(_ files: [String: Data], at root: URL) throws {
        for (path, bytes) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
    }

    static func changed(_ old: [String: Data], _ new: [String: Data]) -> [String] {
        Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }.sorted()
    }

    static func candidateFiles(_ root: URL, oid: String) throws -> [String: Data] {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("hamii-edge-read-\(UUID().uuidString)")
        let worktree = container.appendingPathComponent("worktree")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        _ = try git(root, ["worktree", "add", "--detach", worktree.path, oid])
        defer {
            _ = try? git(root, ["worktree", "remove", "--force", worktree.path])
            try? FileManager.default.removeItem(at: container)
        }
        return try bytes(worktree)
    }
}

private final class SpikePublisher {
    let root: URL
    private var reviewURL: URL { root.appendingPathComponent(".hamii/spike-review.json") }
    private var pendingURL: URL { root.appendingPathComponent(".hamii/migration-publication.pending.json") }
    private var indexURL: URL { root.appendingPathComponent(".hamii/spike-index.json") }

    init(root: URL) { self.root = root }

    var isPending: Bool { FileManager.default.fileExists(atPath: pendingURL.path) }

    private func reviewBytes(_ review: SpikeReview) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(review)
    }

    func requireReady() throws {
        if isPending { throw SpikeFailure.mismatch }
    }

    func requireCurrentQueryReady() throws {
        try requireReady()
        let files = try SpikeRepository.bytes(root)
        let state = try SpikeEdges.validateV3(files)
        guard let index = try readIndex(), !index.id.isEmpty,
              index.sourceCanonicalIdentity == SpikeEdges.identity(files),
              index.sourceGeneration == 2,
              index.documentID == state.id,
              index.documentRevision == state.revision else {
            throw SpikeFailure.mismatch
        }
    }

    func prepare(resolution: MigrationResolutionManifest? = nil,
                 alteredIntermediate: ((inout [String: Data]) throws -> Void)? = nil) throws -> SpikeReview {
        try requireReady()
        let source = try SpikeRepository.bytes(root)
        let sourceOID = try SpikeRepository.git(root, ["rev-parse", "HEAD"])
        let sourceTree = try SpikeRepository.git(root, ["rev-parse", "HEAD^{tree}"])
        guard try SpikeRepository.git(root, ["status", "--porcelain=v1", "--untracked-files=all"]).isEmpty else {
            throw SpikeFailure.mismatch
        }
        let route = try SpikeEdges.route(from: SpikeEdges.format(source), to: 3,
                                        catalog: SpikeEdges.installedAndSynthetic)
        var composed = try SpikeEdges.compose(source, route: route, sourceOID: sourceOID,
                                               resolution: resolution)
        if let alteredIntermediate {
            // Explicit malicious cache/candidate injection; never used by the valid path.
            guard route.first?.id == "1->2" else { throw SpikeFailure.invalidFormat }
            let v2 = try SpikeEdges.compose(source, route: [route[0]], sourceOID: sourceOID,
                                            resolution: resolution).final
            var changedV2 = v2
            try alteredIntermediate(&changedV2)
            let final = try SpikeEdges.syntheticV3(changedV2)
            composed.final = final
            composed.receipts[1].inputIdentity = SpikeEdges.identity(changedV2)
            composed.receipts[1].outputIdentity = SpikeEdges.identity(final)
        }
        _ = try SpikeEdges.validateV3(composed.final)
        let changed = SpikeRepository.changed(source, composed.final)
        guard !changed.isEmpty else { throw SpikeFailure.mismatch }
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("hamii-edge-candidate-\(UUID().uuidString)")
        let worktree = container.appendingPathComponent("worktree")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        _ = try SpikeRepository.git(root, ["worktree", "add", "--detach", worktree.path, sourceOID])
        defer {
            _ = try? SpikeRepository.git(root, ["worktree", "remove", "--force", worktree.path])
            try? FileManager.default.removeItem(at: container)
        }
        try SpikeRepository.write(composed.final.filter { changed.contains($0.key) }, at: worktree)
        _ = try SpikeRepository.git(worktree, ["add", "--"] + changed)
        _ = try SpikeRepository.git(worktree, ["-c", "user.name=Spike", "-c", "user.email=spike@example.invalid",
                                              "commit", "--no-gpg-sign", "-qm", "synthetic composed candidate"])
        let candidateOID = try SpikeRepository.git(worktree, ["rev-parse", "HEAD"])
        let candidateTree = try SpikeRepository.git(worktree, ["rev-parse", "HEAD^{tree}"])
        guard try SpikeRepository.bytes(worktree) == composed.final,
              try SpikeRepository.git(root, ["rev-parse", "HEAD"]) == sourceOID else {
            throw SpikeFailure.mismatch
        }
        let retained = "refs/hamii/migration-candidates/\(UUID().uuidString.lowercased())"
        _ = try SpikeRepository.git(root, ["update-ref", retained, candidateOID,
                                           String(repeating: "0", count: sourceOID.count)])
        let review = SpikeReview(sourceRef: try SpikeRepository.git(root, ["symbolic-ref", "HEAD"]),
            sourceOID: sourceOID, sourceTreeOID: sourceTree, sourceIdentity: SpikeEdges.identity(source),
            sourceFormat: try SpikeEdges.format(source), targetFormat: 3,
            receipts: composed.receipts, resolution: resolution,
            decisions: composed.decisions, losses: composed.losses,
            candidateOID: candidateOID, candidateTreeOID: candidateTree,
            candidateIdentity: SpikeEdges.identity(composed.final), changedPaths: changed,
            retentionRef: retained)
        try FileManager.default.createDirectory(at: reviewURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try reviewBytes(review).write(to: reviewURL, options: .atomic)
        return review
    }

    func validate(_ review: SpikeReview) throws {
        try requireReady()
        guard review.targetFormat == 3,
              review.sourceRef == "refs/heads/main",
              try SpikeRepository.git(root, ["symbolic-ref", "HEAD"]) == review.sourceRef,
              try SpikeRepository.git(root, ["rev-parse", "HEAD"]) == review.sourceOID,
              try SpikeRepository.git(root, ["rev-parse", "HEAD^{tree}"]) == review.sourceTreeOID,
              try SpikeRepository.git(root, ["status", "--porcelain=v1", "--untracked-files=all"]).isEmpty else {
            throw SpikeFailure.mismatch
        }
        guard SpikeEdges.identity(try SpikeRepository.bytes(root)) == review.sourceIdentity else {
            throw SpikeFailure.mismatch
        }
        try validateCommittedCandidate(review)
    }

    private func validateCommittedCandidate(_ review: SpikeReview) throws {
        guard review.targetFormat == 3,
              try SpikeRepository.git(root, ["rev-parse", "\(review.sourceOID)^{tree}"]) == review.sourceTreeOID,
              try SpikeRepository.git(root, ["rev-parse", "\(review.retentionRef)^{commit}"]) == review.candidateOID,
              try SpikeRepository.git(root, ["rev-parse", "\(review.candidateOID)^{tree}"]) == review.candidateTreeOID,
              try SpikeRepository.git(root, ["rev-list", "--parents", "-n", "1", review.candidateOID]) ==
                    "\(review.candidateOID) \(review.sourceOID)" else { throw SpikeFailure.mismatch }
        let source = try SpikeRepository.candidateFiles(root, oid: review.sourceOID)
        guard SpikeEdges.identity(source) == review.sourceIdentity,
              try SpikeEdges.format(source) == review.sourceFormat else { throw SpikeFailure.mismatch }
        let route = try SpikeEdges.route(from: review.sourceFormat, to: review.targetFormat,
                                        catalog: SpikeEdges.installedAndSynthetic)
        let composed = try SpikeEdges.compose(source, route: route,
                                              sourceOID: review.sourceOID, resolution: review.resolution)
        let candidate = try SpikeRepository.candidateFiles(root, oid: review.candidateOID)
        guard composed.receipts == review.receipts,
              composed.decisions == review.decisions,
              composed.losses == review.losses,
              composed.final == candidate,
              SpikeEdges.identity(candidate) == review.candidateIdentity,
              SpikeRepository.changed(source, candidate) == review.changedPaths else {
            throw SpikeFailure.mismatch
        }
        _ = try SpikeEdges.validateV3(candidate)
    }

    func publish(_ review: SpikeReview, stopAt: String? = nil) throws {
        let reviewed = try Data(contentsOf: reviewURL)
        guard reviewed == (try reviewBytes(review)) else { throw SpikeFailure.mismatch }
        try validate(review)
        let pending = SpikePending(review: review, sourceGeneration: 1, candidateGeneration: 2)
        try JSONEncoder().encode(pending).write(to: pendingURL, options: .atomic)
        try stop("S1", at: stopAt)
        _ = try SpikeRepository.git(root, ["update-ref", review.sourceRef, review.candidateOID, review.sourceOID])
        try stop("S2", at: stopAt)
        try materialize(review)
        try stop("S3", at: stopAt)
        let state = try verifyWorktree(review)
        try stop("S4", at: stopAt)
        _ = try publishIndex(pending, state: state)
        try stop("S5", at: stopAt)
        try FileManager.default.removeItem(at: pendingURL)
    }

    @discardableResult func recover() throws -> String {
        guard isPending else {
            // Repeated recovery cannot advance a published generation.
            if FileManager.default.fileExists(atPath: indexURL.path) {
                let current = try SpikeRepository.bytes(root)
                let index = try JSONDecoder().decode(SpikeIndex.self, from: Data(contentsOf: indexURL))
                guard index.sourceCanonicalIdentity == SpikeEdges.identity(current) else {
                    throw SpikeFailure.mismatch
                }
            }
            return try SpikeRepository.git(root, ["rev-parse", "HEAD"])
        }
        let pending = try JSONDecoder().decode(SpikePending.self, from: Data(contentsOf: pendingURL))
        let review = pending.review
        guard review.sourceOID != review.candidateOID,
              try Data(contentsOf: reviewURL) == reviewBytes(review) else {
            throw SpikeFailure.mismatch
        }
        guard try SpikeRepository.git(root, ["symbolic-ref", "HEAD"]) == review.sourceRef else {
            throw SpikeFailure.unknownSource
        }
        let head = try SpikeRepository.git(root, ["rev-parse", "HEAD"])
        if head == review.sourceOID {
            try validateCommittedCandidate(review)
            guard try SpikeRepository.git(root, ["status", "--porcelain=v1", "--untracked-files=all"]).isEmpty,
                  SpikeEdges.identity(try SpikeRepository.bytes(root)) == review.sourceIdentity else {
                throw SpikeFailure.unknownSource
            }
            try FileManager.default.removeItem(at: pendingURL)
            return head
        }
        guard head == review.candidateOID,
              try SpikeRepository.git(root, ["rev-parse", "\(review.retentionRef)^{commit}"]) == review.candidateOID else {
            throw SpikeFailure.unknownSource
        }
        try validateCommittedCandidate(review)
        try materialize(review)
        let state = try verifyWorktree(review)
        _ = try publishIndex(pending, state: state)
        try FileManager.default.removeItem(at: pendingURL)
        return head
    }

    func readIndex() throws -> SpikeIndex? {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return nil }
        return try JSONDecoder().decode(SpikeIndex.self, from: Data(contentsOf: indexURL))
    }

    private func stop(_ name: String, at selected: String?) throws {
        if selected == name { throw SpikeFailure.stopped(name) }
    }

    private func materialize(_ review: SpikeReview) throws {
        _ = try SpikeRepository.git(root, ["read-tree", "--reset", "-u", review.candidateOID])
    }

    private func verifyWorktree(_ review: SpikeReview) throws -> (id: String, revision: Int) {
        let files = try SpikeRepository.bytes(root)
        guard SpikeEdges.identity(files) == review.candidateIdentity,
              try SpikeRepository.git(root, ["rev-parse", "HEAD"]) == review.candidateOID,
              try SpikeRepository.git(root, ["status", "--porcelain=v1", "--untracked-files=all"]).isEmpty else {
            throw SpikeFailure.mismatch
        }
        return try SpikeEdges.validateV3(files)
    }

    private func publishIndex(_ pending: SpikePending, state: (id: String, revision: Int)) throws -> SpikeIndex {
        let expected = SpikeIndex(id: "", sourceCanonicalIdentity: pending.review.candidateIdentity,
                                  sourceGeneration: pending.candidateGeneration,
                                  documentID: state.id, documentRevision: state.revision)
        if let existing = try readIndex() {
            guard existing.sourceCanonicalIdentity == expected.sourceCanonicalIdentity,
                  existing.sourceGeneration == expected.sourceGeneration,
                  existing.documentID == expected.documentID,
                  existing.documentRevision == expected.documentRevision else {
                throw SpikeFailure.mismatch
            }
            return existing
        }
        var built = expected
        built.id = UUID().uuidString.lowercased()
        try JSONEncoder().encode(built).write(to: indexURL, options: .atomic)
        return built
    }
}

final class OrderedEdgePublicationSpikeTests: XCTestCase {
    private var fixtureRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/format-v1-safe-project")
    }

    private func v1Files() throws -> [String: Data] {
        try MigrationRepositoryInput.load(from: fixtureRoot).files
    }

    private func v2Files() throws -> [String: Data] {
        try MigrationRegistry.transform(MigrationFileSet(files: v1Files())).files.files
    }

    private func root(version: Int, ambiguous: Bool = false) throws -> URL {
        var files = try version == 1 ? v1Files() : v2Files()
        if ambiguous {
            guard version == 1, let bytes = files["hamii.json"],
                  var manifest = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  var declarations = manifest["capabilityDeclarations"] as? [[String: Any]],
                  var duplicate = declarations.first else { throw SpikeFailure.invalidFormat }
            duplicate["support"] = "portable"
            duplicate["reason"] = "ambiguous historical support"
            declarations.append(duplicate)
            manifest["capabilityDeclarations"] = declarations
            files["hamii.json"] = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hamii-edge-spike-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try SpikeRepository.write(files, at: directory)
        try Data(".hamii/\n".utf8).write(to: directory.appendingPathComponent(".gitignore"))
        let blob = directory.appendingPathComponent("assets/blobs/sha256/spike-example")
        try FileManager.default.createDirectory(at: blob.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0, 1, 2, 255]).write(to: blob)
        _ = try SpikeRepository.git(directory, ["init", "-q"])
        _ = try SpikeRepository.git(directory, ["checkout", "-q", "-b", "main"])
        _ = try SpikeRepository.git(directory, ["add", "-A"])
        _ = try SpikeRepository.git(directory, ["-c", "user.name=Spike", "-c", "user.email=spike@example.invalid",
                                               "commit", "--no-gpg-sign", "-qm", "source"])
        return directory
    }

    private func resolvedManifest(_ root: URL) throws -> MigrationResolutionManifest {
        let source = try SpikeRepository.bytes(root)
        let sourceOID = try SpikeRepository.git(root, ["rev-parse", "HEAD"])
        let binding = MigrationResolutionSourceBinding(sourceOID: sourceOID,
            sourceCanonicalIdentity: SpikeEdges.identity(source))
        let report = try MigrationRegistry.resolutionReport(MigrationFileSet(files: source), sourceBinding: binding)
        guard !report.items.isEmpty,
              report.items.allSatisfy({ !$0.choices.isEmpty }) else { throw SpikeFailure.mismatch }
        return MigrationResolutionManifest(source: report.source,
            decisions: report.items.map { MigrationResolutionDecision(item: $0.id,
                selectedCandidateID: $0.choices[0].id) })
    }

    func testRouteMatrixRejectsMissingAmbiguousCycleSelfAndDuplicate() throws {
        let catalog = SpikeEdges.installedAndSynthetic
        XCTAssertEqual(try SpikeEdges.route(from: 1, to: 3, catalog: catalog).map(\.id), ["1->2", "2->3"])
        XCTAssertEqual(try SpikeEdges.route(from: 2, to: 3, catalog: catalog).map(\.id), ["2->3"])
        XCTAssertTrue(try SpikeEdges.route(from: 3, to: 3, catalog: catalog).isEmpty)
        XCTAssertThrowsError(try SpikeEdges.route(from: 1, to: 3, catalog: [.init(source: 1, target: 2)])) {
            XCTAssertEqual($0 as? SpikeFailure, .noPath)
        }
        XCTAssertThrowsError(try SpikeEdges.route(from: 1, to: 3,
            catalog: catalog + [.init(source: 1, target: 3)])) {
            XCTAssertEqual($0 as? SpikeFailure, .ambiguousPath)
        }
        for bad in [catalog + [.init(source: 3, target: 1)],
                    catalog + [.init(source: 2, target: 2)],
                    catalog + [.init(source: 1, target: 2)]] {
            XCTAssertThrowsError(try SpikeEdges.route(from: 1, to: 3, catalog: bad)) {
                XCTAssertEqual($0 as? SpikeFailure, .invalidCatalog)
            }
        }
    }

    func testPureCompositionReceiptsDeterminismAndUnrelatedBytes() throws {
        for version in [1, 2] {
            var source = try version == 1 ? v1Files() : v2Files()
            source["assets/blobs/sha256/spike-example"] = Data([0, 1, 2, 255])
            let route = try SpikeEdges.route(from: version, to: 3, catalog: SpikeEdges.installedAndSynthetic)
            let first = try SpikeEdges.compose(source, route: route, sourceOID: "fixture")
            let second = try SpikeEdges.compose(source, route: route, sourceOID: "fixture")
            XCTAssertEqual(first.final, second.final)
            XCTAssertEqual(first.receipts, second.receipts)
            XCTAssertEqual(first.receipts.map(\.edgeID), version == 1 ? ["1->2", "2->3"] : ["2->3"])
            XCTAssertEqual(first.receipts.first?.inputIdentity, SpikeEdges.identity(source))
            XCTAssertEqual(first.receipts.last?.outputIdentity, SpikeEdges.identity(first.final))
            for pair in zip(first.receipts, first.receipts.dropFirst()) {
                XCTAssertEqual(pair.0.outputIdentity, pair.1.inputIdentity)
            }
            _ = try SpikeEdges.validateV3(first.final)
            XCTAssertThrowsError(try SpikeEdges.validateV3(v2Files()))
            XCTAssertEqual(first.final["assets/blobs/sha256/spike-example"], source["assets/blobs/sha256/spike-example"])
            let v2 = version == 1 ? try SpikeEdges.compose(source, route: [route[0]], sourceOID: "fixture").final : source
            for (path, bytes) in v2 where path != "hamii.json" && !path.hasPrefix("screens/") {
                XCTAssertEqual(first.final[path], bytes, path)
            }
            print("SPIKE pure sourceFormat=\(version) finalIdentity=\(SpikeEdges.identity(first.final)) receipts=\(first.receipts.map(\.edgeID))")
        }
    }

    func testV1HumanResolutionIsBoundOnlyToFirstEdge() throws {
        let directory = try root(version: 1, ambiguous: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let publisher = SpikePublisher(root: directory)
        XCTAssertThrowsError(try publisher.prepare())
        let manifest = try resolvedManifest(directory)
        XCTAssertEqual(manifest.sourceFormatVersion, 1)
        XCTAssertEqual(manifest.targetFormatVersion, 2)
        let v2Directory = try root(version: 2)
        defer { try? FileManager.default.removeItem(at: v2Directory) }
        XCTAssertThrowsError(try SpikePublisher(root: v2Directory).prepare(resolution: manifest),
                             "resolution for an edge outside the selected route")
        let review = try publisher.prepare(resolution: manifest)
        XCTAssertEqual(review.targetFormat, 3)
        XCTAssertEqual(review.receipts.map(\.edgeID), ["1->2", "2->3"])
        XCTAssertEqual(review.decisions, manifest.decisions)
        XCTAssertEqual(review.receipts[1].classification, MigrationClassification.lossless.rawValue)
        XCTAssertNoThrow(try publisher.validate(review))
        var wrong = review
        wrong.resolution = MigrationResolutionManifest(source: manifest.sourceBinding,
            decisions: manifest.decisions.map { .init(item: $0.item, selectedCandidateID: "wrong-choice") })
        XCTAssertThrowsError(try publisher.validate(wrong))
        print("SPIKE resolved sourceOID=\(review.sourceOID) finalOID=\(review.candidateOID) finalIdentity=\(review.candidateIdentity) lossCount=\(review.losses.count)")
    }

    func testPublisherRecomputesAndRejectsTamperedReviewCandidateAndIntermediate() throws {
        let directory = try root(version: 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        let publisher = SpikePublisher(root: directory)
        let review = try publisher.prepare()
        XCTAssertNoThrow(try publisher.validate(review))
        var wrong = review
        wrong.receipts.reverse()
        XCTAssertThrowsError(try publisher.validate(wrong), "edge order")
        wrong = review; wrong.receipts[0].edgeID = "1->3"
        XCTAssertThrowsError(try publisher.validate(wrong), "edge ID")
        wrong = review; wrong.sourceIdentity = String(repeating: "a", count: 64)
        XCTAssertThrowsError(try publisher.validate(wrong), "source identity")
        wrong = review; wrong.receipts[0].classification = "lossless"
        XCTAssertThrowsError(try publisher.validate(wrong), "edge classification")
        wrong = review; wrong.candidateIdentity = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try publisher.validate(wrong), "final bytes identity")
        wrong = review; wrong.candidateTreeOID = review.sourceTreeOID
        XCTAssertThrowsError(try publisher.validate(wrong), "final candidate tree")
        wrong = review; wrong.candidateOID = review.sourceOID
        XCTAssertThrowsError(try publisher.validate(wrong), "final candidate OID")
        wrong = review; wrong.changedPaths = []
        XCTAssertThrowsError(try publisher.validate(wrong), "changed paths")

        let screen = directory.appendingPathComponent("screens/screen_main.json")
        let original = try Data(contentsOf: screen)
        try Data("{}\n".utf8).write(to: screen)
        XCTAssertThrowsError(try publisher.validate(review), "source mutation after review")
        try original.write(to: screen)
        XCTAssertNoThrow(try publisher.validate(review))

        let malicious = try publisher.prepare(alteredIntermediate: { files in
            guard let bytes = files["screens/screen_main.json"],
                  var screen = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                throw SpikeFailure.invalidFormat
            }
            screen["name"] = "Tampered intermediate"
            files["screens/screen_main.json"] = try JSONSerialization.data(withJSONObject: screen, options: [.sortedKeys])
        })
        XCTAssertThrowsError(try publisher.validate(malicious), "intermediate v2 bytes")

        let candidateContainer = FileManager.default.temporaryDirectory.appendingPathComponent("hamii-edge-tampered-\(UUID().uuidString)")
        let candidateWorktree = candidateContainer.appendingPathComponent("worktree")
        try FileManager.default.createDirectory(at: candidateContainer, withIntermediateDirectories: true)
        _ = try SpikeRepository.git(directory, ["worktree", "add", "--detach", candidateWorktree.path, review.candidateOID])
        defer {
            _ = try? SpikeRepository.git(directory, ["worktree", "remove", "--force", candidateWorktree.path])
            try? FileManager.default.removeItem(at: candidateContainer)
        }
        let candidateScreen = candidateWorktree.appendingPathComponent("screens/screen_main.json")
        guard var finalScreen = try JSONSerialization.jsonObject(with: Data(contentsOf: candidateScreen)) as? [String: Any] else {
            throw SpikeFailure.invalidFormat
        }
        finalScreen["name"] = "Tampered final bytes"
        try JSONSerialization.data(withJSONObject: finalScreen, options: [.sortedKeys]).write(to: candidateScreen)
        _ = try SpikeRepository.git(candidateWorktree, ["add", "screens/screen_main.json"])
        _ = try SpikeRepository.git(candidateWorktree, ["-c", "user.name=Spike", "-c", "user.email=spike@example.invalid",
                                                          "commit", "--no-gpg-sign", "-qm", "tampered final bytes"])
        let alteredOID = try SpikeRepository.git(candidateWorktree, ["rev-parse", "HEAD"])
        _ = try SpikeRepository.git(directory, ["update-ref", review.retentionRef, alteredOID, review.candidateOID])
        XCTAssertThrowsError(try publisher.validate(review), "retained candidate final bytes changed")
        _ = try SpikeRepository.git(directory, ["update-ref", review.retentionRef, review.candidateOID, alteredOID])

        _ = try SpikeRepository.git(directory, ["update-ref", review.retentionRef, review.sourceOID, review.candidateOID])
        XCTAssertThrowsError(try publisher.validate(review), "retained candidate ref tampering")
        XCTAssertFalse(publisher.isPending)
        XCTAssertEqual(try SpikeRepository.git(directory, ["rev-parse", "HEAD"]), review.sourceOID)
    }

    func testStopMatrixCASRecoveryAndIdempotentIndex() throws {
        let matrix: [(Int, [String])] = [(1, ["S1", "S2", "S3", "S4", "S5"]),
                                       (2, ["S1", "S2", "S4"])]
        for (version, stops) in matrix {
            for stop in stops {
                let directory = try root(version: version)
                defer { try? FileManager.default.removeItem(at: directory) }
                let publisher = SpikePublisher(root: directory)
                let review = try publisher.prepare()
                let blob = directory.appendingPathComponent("assets/blobs/sha256/spike-example")
                let originalBlob = try Data(contentsOf: blob)
                XCTAssertThrowsError(try publisher.publish(review, stopAt: stop), "v\(version) \(stop)") {
                    XCTAssertEqual($0 as? SpikeFailure, .stopped(stop))
                }
                XCTAssertTrue(publisher.isPending)
                XCTAssertThrowsError(try publisher.requireReady())
                XCTAssertThrowsError(try publisher.requireCurrentQueryReady())
                let head = try SpikeRepository.git(directory, ["rev-parse", "HEAD"])
                XCTAssertEqual(head, stop == "S1" ? review.sourceOID : review.candidateOID)
                if stop == "S2" { XCTAssertNotEqual(SpikeEdges.identity(try SpikeRepository.bytes(directory)), review.candidateIdentity) }
                if stop == "S4" { XCTAssertNil(try publisher.readIndex()) }
                let beforeIndex = try publisher.readIndex()
                let restarted = SpikePublisher(root: directory)
                let recovered = try restarted.recover()
                XCTAssertEqual(recovered, stop == "S1" ? review.sourceOID : review.candidateOID)
                XCTAssertFalse(restarted.isPending)
                XCTAssertEqual(try restarted.recover(), recovered)
                XCTAssertEqual(try Data(contentsOf: blob), originalBlob)
                if stop == "S1" {
                    XCTAssertEqual(try SpikeEdges.format(SpikeRepository.bytes(directory)), version)
                    XCTAssertNil(try restarted.readIndex())
                    XCTAssertThrowsError(try restarted.requireCurrentQueryReady(),
                                         "historical source retained, Current query unavailable")
                } else {
                    let final = try SpikeRepository.bytes(directory)
                    XCTAssertEqual(SpikeEdges.identity(final), review.candidateIdentity)
                    let state = try SpikeEdges.validateV3(final)
                    let index = try XCTUnwrap(restarted.readIndex())
                    XCTAssertEqual(index.sourceCanonicalIdentity, review.candidateIdentity)
                    XCTAssertEqual(index.sourceGeneration, 2)
                    XCTAssertEqual(index.documentID, state.id)
                    XCTAssertEqual(index.documentRevision, state.revision)
                    if stop == "S5" { XCTAssertEqual(index, beforeIndex) }
                    XCTAssertEqual(try restarted.readIndex(), index)
                    XCTAssertNoThrow(try restarted.requireCurrentQueryReady())
                    if stop == "S5" {
                        let indexURL = directory.appendingPathComponent(".hamii/spike-index.json")
                        let originalIndex = try Data(contentsOf: indexURL)
                        try FileManager.default.removeItem(at: indexURL)
                        XCTAssertThrowsError(try SpikePublisher(root: directory).requireCurrentQueryReady(),
                                             "no pending, but missing Index on restart")
                        var wrongGeneration = index
                        wrongGeneration.sourceGeneration += 1
                        try JSONEncoder().encode(wrongGeneration).write(to: indexURL, options: .atomic)
                        XCTAssertThrowsError(try SpikePublisher(root: directory).requireCurrentQueryReady(),
                                             "no pending, but wrong source generation")
                        try originalIndex.write(to: indexURL, options: .atomic)
                        XCTAssertNoThrow(try SpikePublisher(root: directory).requireCurrentQueryReady())
                    }
                }
                print("SPIKE stop=\(stop) sourceFormat=\(version) sourceOID=\(review.sourceOID) finalOID=\(review.candidateOID) finalIdentity=\(review.candidateIdentity) recovered=\(recovered)")
            }
        }
    }

    func testUnknownHeadWorktreeMismatchAndWrongIndexRemainClosed() throws {
        let unknownRoot = try root(version: 1)
        defer { try? FileManager.default.removeItem(at: unknownRoot) }
        let unknownPublisher = SpikePublisher(root: unknownRoot)
        let unknownReview = try unknownPublisher.prepare()
        XCTAssertThrowsError(try unknownPublisher.publish(unknownReview, stopAt: "S1"))
        let note = unknownRoot.appendingPathComponent("unrelated.txt")
        try Data("other ref\n".utf8).write(to: note)
        _ = try SpikeRepository.git(unknownRoot, ["add", "unrelated.txt"])
        _ = try SpikeRepository.git(unknownRoot, ["-c", "user.name=Spike", "-c", "user.email=spike@example.invalid",
                                                  "commit", "--no-gpg-sign", "-qm", "unrelated"])
        XCTAssertThrowsError(try SpikePublisher(root: unknownRoot).recover()) {
            XCTAssertEqual($0 as? SpikeFailure, .unknownSource)
        }
        XCTAssertTrue(SpikePublisher(root: unknownRoot).isPending)

        let changedRoot = try root(version: 2)
        defer { try? FileManager.default.removeItem(at: changedRoot) }
        let changedPublisher = SpikePublisher(root: changedRoot)
        let changedReview = try changedPublisher.prepare()
        XCTAssertThrowsError(try changedPublisher.publish(changedReview, stopAt: "S3"))
        let screen = changedRoot.appendingPathComponent("screens/screen_main.json")
        try Data("{}\n".utf8).write(to: screen)
        XCTAssertThrowsError(try changedPublisher.requireReady())
        XCTAssertNotEqual(SpikeEdges.identity(try SpikeRepository.bytes(changedRoot)), changedReview.candidateIdentity)
        XCTAssertEqual(try SpikePublisher(root: changedRoot).recover(), changedReview.candidateOID)
        XCTAssertEqual(SpikeEdges.identity(try SpikeRepository.bytes(changedRoot)), changedReview.candidateIdentity)

        let indexRoot = try root(version: 2)
        defer { try? FileManager.default.removeItem(at: indexRoot) }
        let indexPublisher = SpikePublisher(root: indexRoot)
        let indexReview = try indexPublisher.prepare()
        XCTAssertThrowsError(try indexPublisher.publish(indexReview, stopAt: "S5"))
        var wrongIndex = try XCTUnwrap(indexPublisher.readIndex())
        wrongIndex.sourceCanonicalIdentity = String(repeating: "f", count: 64)
        try JSONEncoder().encode(wrongIndex).write(to: indexRoot.appendingPathComponent(".hamii/spike-index.json"))
        XCTAssertThrowsError(try SpikePublisher(root: indexRoot).recover())
        XCTAssertTrue(SpikePublisher(root: indexRoot).isPending)
    }

    func testRecoveryRevalidatesFullEdgePathAfterCAS() throws {
        let directory = try root(version: 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        let publisher = SpikePublisher(root: directory)
        let review = try publisher.prepare()
        XCTAssertThrowsError(try publisher.publish(review, stopAt: "S2"))
        let record = directory.appendingPathComponent(".hamii/migration-publication.pending.json")
        let original = try Data(contentsOf: record)
        var pending = try JSONDecoder().decode(SpikePending.self, from: original)
        pending.review.receipts[0].edgeID = "tampered"
        try JSONEncoder().encode(pending).write(to: record, options: .atomic)
        XCTAssertThrowsError(try SpikePublisher(root: directory).recover())
        XCTAssertTrue(SpikePublisher(root: directory).isPending)
        XCTAssertEqual(try SpikeRepository.git(directory, ["rev-parse", "HEAD"]), review.candidateOID)
        try original.write(to: record, options: .atomic)
        XCTAssertEqual(try SpikePublisher(root: directory).recover(), review.candidateOID)
        XCTAssertFalse(SpikePublisher(root: directory).isPending)
    }

    func testPendingRecordCannotReclassifyPublishedCandidateAsOldSource() throws {
        let directory = try root(version: 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        let publisher = SpikePublisher(root: directory)
        let review = try publisher.prepare()
        XCTAssertThrowsError(try publisher.publish(review, stopAt: "S3")) {
            XCTAssertEqual($0 as? SpikeFailure, .stopped("S3"))
        }
        let record = directory.appendingPathComponent(".hamii/migration-publication.pending.json")
        let original = try Data(contentsOf: record)
        var pending = try JSONDecoder().decode(SpikePending.self, from: original)
        pending.review.sourceOID = review.candidateOID
        pending.review.sourceIdentity = review.candidateIdentity
        try JSONEncoder().encode(pending).write(to: record, options: .atomic)
        XCTAssertThrowsError(try SpikePublisher(root: directory).recover())
        XCTAssertTrue(SpikePublisher(root: directory).isPending)
        XCTAssertThrowsError(try SpikePublisher(root: directory).requireCurrentQueryReady())
        try original.write(to: record, options: .atomic)
        XCTAssertEqual(try SpikePublisher(root: directory).recover(), review.candidateOID)
        XCTAssertNoThrow(try SpikePublisher(root: directory).requireCurrentQueryReady())
    }
}
