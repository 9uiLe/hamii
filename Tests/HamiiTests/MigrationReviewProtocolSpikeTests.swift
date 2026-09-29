import CryptoKit
import Darwin
import Foundation
import MachO
import HamiiCore
@testable import HamiiFormat
import HamiiIndex
import HamiiMigrationBoundarySpike
import XCTest

/// Test-only workflow prototype; the production Format reader remains v1.
final class MigrationReviewProtocolSpikeTests: XCTestCase {
    private enum ProbeFailure: Error { case dirty, stale, invalidCandidate, ambiguous, gated, unknown, injected }
    private let folders = ["pages", "screens", "scopes", "components", "tokens", "assets", "interactions", "motions", "fixtures", "targets"]

    private struct Review: Codable {
        let root: URL
        let candidateRoot: URL
        let sourceRef: String
        let sourceOID: String
        let sourceTreeOID: String
        let candidateOID: String
        let candidateTreeOID: String
        let retentionRef: String
        let edgePath: [String]
        let classification: String
        let changedPaths: [String]
        let diffNameStatus: String
        let diffStat: String
    }

    private enum Phase: String, Codable { case pending, refPublished, worktreeMaterialized, currentValidated, indexPublished }
    private struct Pending: Codable {
        let formatVersion: Int
        let publicationID: UUID
        let sourceRef: String
        let expectedSourceOID: String
        let candidateOID: String
        let candidateTreeOID: String
        let retentionRef: String
        let sourceFormatVersion: Int
        let targetFormatVersion: Int
        var phase: Phase
    }

    private func temp(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("hamii-review-\(suffix)-\(UUID().uuidString)")
    }

    @discardableResult
    private func git(_ root: URL, _ args: String...) throws -> String {
        try git(root, args)
    }

    @discardableResult
    private func git(_ root: URL, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + args
        let output = Pipe(); let error = Pipe()
        process.standardOutput = output; process.standardError = error
        try process.run(); process.waitUntilExit()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw NSError(domain: "git", code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")): \(stderr)"]) }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fixture() throws -> URL {
        let root = temp("source")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sample = repositoryRoot.appendingPathComponent("Samples/Starter")
        for name in ["hamii.json", "hamii-agent-profiles.json"] + folders {
            let source = sample.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: root.appendingPathComponent(name))
            }
        }
        try Data(".hamii/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try git(root, "init", "-q")
        try git(root, "config", "user.name", "hamii test")
        try git(root, "config", "user.email", "hamii-test@example.invalid")
        let repository = CanonicalRepository(root: root)
        let original = try repository.load()
        let blob = try CanonicalBlobStore(root: root).put(Data("migration asset".utf8))
        var withAsset = original
        withAsset.assets.append(Asset(id: EntityID("asset_migration_required"), name: "Required", ownerScopeID: original.scopes[0].id,
                                      mediaType: "text/plain", source: .repository(path: blob.relativePath), contentHash: blob.sha256))
        withAsset.screens[0].root.layout.paddingTokenID = EntityID("token_120e0eb8-13a3-43ae-b5b2-29276c9a06ac")
        withAsset.revision += 1
        try repository.save(withAsset, expected: original)
        try git(root, "add", "-A")
        try git(root, "commit", "-qm", "historical source")
        XCTAssertTrue(try git(root, "status", "--porcelain", "--untracked-files=all").isEmpty)
        return root
    }

    private func files(_ root: URL) throws -> RawFormatUpgradeProbe.Files {
        var paths = ["hamii.json", "hamii-agent-profiles.json"]
        for folder in folders {
            let directory = root.appendingPathComponent(folder)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            paths += try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasSuffix(".json") }.map { "\(folder)/\($0)" }
        }
        return try Dictionary(uniqueKeysWithValues: paths.map { ($0, try Data(contentsOf: root.appendingPathComponent($0))) })
    }

    private func adaptLayer(_ input: [String: Any]) throws -> [String: Any] {
        var layer = input
        if let effects = layer.removeValue(forKey: "effects") as? [[String: Any]] {
            guard effects.count == 1, effects[0]["kind"] as? String == "padding",
                  let token = effects[0]["tokenID"] as? [String: Any] else { throw ProbeFailure.invalidCandidate }
            var layout = layer["layout"] as? [String: Any] ?? [:]
            guard layout["paddingTokenID"] == nil else { throw ProbeFailure.invalidCandidate }
            layout["paddingTokenID"] = token; layer["layout"] = layout
        }
        if let children = layer["children"] as? [[String: Any]] { layer["children"] = try children.map(adaptLayer) }
        if var component = layer["component"] as? [String: Any],
           var slots = component["slotContent"] as? [String: [[String: Any]]] {
            for name in slots.keys.sorted() { slots[name] = try slots[name]!.map(adaptLayer) }
            component["slotContent"] = slots; layer["component"] = component
        }
        return layer
    }

    private func adapted(_ original: RawFormatUpgradeProbe.Files) throws -> RawFormatUpgradeProbe.Files {
        var result = original
        guard let bytes = original["hamii.json"],
              var manifest = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              var versions = manifest["versions"] as? [String: Any] else { throw ProbeFailure.invalidCandidate }
        manifest["formatVersion"] = 1; versions["document"] = 1; manifest["versions"] = versions
        result["hamii.json"] = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        for path in original.keys where path.hasPrefix("screens/") || path.hasPrefix("components/") {
            guard let bytes = original[path], var json = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let root = json["root"] as? [String: Any] else { throw ProbeFailure.invalidCandidate }
            json["root"] = try adaptLayer(root)
            result[path] = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        }
        return result
    }

    private func materialize(_ files: RawFormatUpgradeProbe.Files, at root: URL) throws {
        for (path, bytes) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
    }

    private func copyBlobs(from source: URL, to destination: URL) throws {
        let blobs = source.appendingPathComponent("assets/blobs")
        if FileManager.default.fileExists(atPath: blobs.path) {
            try FileManager.default.createDirectory(at: destination.appendingPathComponent("assets"), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: blobs, to: destination.appendingPathComponent("assets/blobs"))
        }
    }

    private func validate(_ files: RawFormatUpgradeProbe.Files, blobsFrom source: URL) throws {
        let current = temp("oracle")
        defer { try? FileManager.default.removeItem(at: current) }
        try materialize(try adapted(files), at: current)
        try copyBlobs(from: source, to: current)
        _ = try CanonicalRepository(root: current).load()
    }

    private func freshIndex(_ files: RawFormatUpgradeProbe.Files, blobsFrom source: URL) throws {
        let current = temp("index-oracle")
        let storage = temp("index-store")
        defer {
            try? FileManager.default.removeItem(at: current)
            try? FileManager.default.removeItem(at: storage)
        }
        try materialize(try adapted(files), at: current)
        try copyBlobs(from: source, to: current)
        try git(current, "init", "-q")
        try git(current, "config", "user.name", "hamii test")
        try git(current, "config", "user.email", "hamii-test@example.invalid")
        try Data(".hamii/\n".utf8).write(to: current.appendingPathComponent(".gitignore"))
        try git(current, "add", "-A")
        try git(current, "commit", "-qm", "oracle")
        let repository = CanonicalRepository(root: current)
        let snapshot = try repository.withCoordinatedSnapshot { $0 }
        let calculator = GitCanonicalRevisionCalculator()
        let index = try LocalIndex(projectRoot: current, documentID: snapshot.document.id,
                                   revisionCalculator: calculator, storageRoot: storage)
        _ = try index.rebuild(from: snapshot, canonicalRevision: calculator.current(at: current))
        _ = try index.components(matching: "", consumerScopeID: snapshot.document.scopes[0].id,
                                 documentID: snapshot.document.id, revision: snapshot.document.revision,
                                 expectedSourceIdentity: snapshot.identity)
    }

    private func pendingURL(_ root: URL) -> URL { root.appendingPathComponent(".hamii/migration-publication.pending.json") }
    private func readPending(_ root: URL) throws -> Pending {
        try JSONDecoder().decode(Pending.self, from: Data(contentsOf: pendingURL(root)))
    }
    private func writePending(_ record: Pending, at root: URL) throws {
        try JSONEncoder().encode(record).write(to: pendingURL(root), options: .atomic)
    }

    private func prepare(_ root: URL, stop: ((String) throws -> Void)? = nil,
                         failCandidateValidation: Bool = false,
                         requiredObjectAvailable: Bool = true) throws -> Review {
        guard try git(root, "status", "--porcelain", "--untracked-files=all").isEmpty else { throw ProbeFailure.dirty }
        let sourceRef = try git(root, "symbolic-ref", "--quiet", "HEAD")
        let sourceOID = try git(root, "rev-parse", "HEAD")
        let sourceTreeOID = try git(root, "rev-parse", "HEAD^{tree}")
        let candidateRoot = temp("candidate")
        try git(root, "worktree", "add", "--detach", candidateRoot.path, sourceOID)
        var retained = false
        defer {
            if !retained {
                _ = try? git(root, "worktree", "remove", "--force", candidateRoot.path)
                try? FileManager.default.removeItem(at: candidateRoot)
            }
        }
        try stop?("transform")
        let migrated = try RawFormatUpgradeProbe.migrate(files(candidateRoot), to: 3) { candidate, version in
            XCTAssertEqual(try RawFormatUpgradeProbe.version(candidate), version)
            try self.validate(candidate, blobsFrom: candidateRoot)
        }
        try materialize(migrated.files, at: candidateRoot)
        if !requiredObjectAvailable {
            let blobs = candidateRoot.appendingPathComponent("assets/blobs")
            try FileManager.default.removeItem(at: blobs)
        }
        if failCandidateValidation {
            try FileManager.default.removeItem(at: candidateRoot.appendingPathComponent("tokens/token_120e0eb8-13a3-43ae-b5b2-29276c9a06ac.json"))
        }
        try validate(files(candidateRoot), blobsFrom: candidateRoot)
        try freshIndex(files(candidateRoot), blobsFrom: candidateRoot)
        try git(candidateRoot, "add", "-A")
        try git(candidateRoot, "commit", "-qm", "test-only migration candidate")
        let candidateOID = try git(candidateRoot, "rev-parse", "HEAD")
        let candidateTreeOID = try git(candidateRoot, "rev-parse", "HEAD^{tree}")
        XCTAssertEqual(try git(candidateRoot, "rev-parse", "HEAD^"), sourceOID)
        let changed = try git(root, "diff", "--name-only", sourceOID, candidateOID)
            .split(separator: "\n").map(String.init)
        guard changed.allSatisfy({ $0 == "hamii.json" || $0.hasPrefix("screens/") || $0.hasPrefix("components/") }) else {
            throw ProbeFailure.invalidCandidate
        }
        let ref = "refs/hamii/migration-candidates/\(UUID().uuidString.lowercased())"
        try git(root, "update-ref", ref, candidateOID)
        retained = true
        return Review(root: root, candidateRoot: candidateRoot, sourceRef: sourceRef, sourceOID: sourceOID,
                      sourceTreeOID: sourceTreeOID, candidateOID: candidateOID, candidateTreeOID: candidateTreeOID,
                      retentionRef: ref, edgePath: migrated.edges, classification: migrated.classification,
                      changedPaths: changed, diffNameStatus: try git(root, "diff", "--name-status", sourceOID, candidateOID),
                      diffStat: try git(root, "diff", "--stat", sourceOID, candidateOID))
    }

    private func cleanup(_ review: Review) throws {
        if FileManager.default.fileExists(atPath: review.candidateRoot.path) {
            try git(review.root, "worktree", "remove", "--force", review.candidateRoot.path)
        }
        try git(review.root, "update-ref", "-d", review.retentionRef, review.candidateOID)
    }

    private func record(_ name: String, root: URL, review: Review? = nil, sourceDirty: Bool = false,
                        candidateValidated: Bool = false, reviewDecision: String = "notReached",
                        casResult: String = "notAttempted", phaseAtStop: String = "none",
                        recoveryResult: String = "notNeeded", sourceBytesPreserved: Bool,
                        freshIndexResult: String = "notAttempted") throws {
        guard let directory = ProcessInfo.processInfo.environment["HAMII_MIGRATION_REVIEW_ARTIFACT_DIR"] else { return }
        let pending = FileManager.default.fileExists(atPath: pendingURL(root).path)
        let sourceOID: String
        let sourceTreeOID: String
        if let review {
            sourceOID = review.sourceOID
            sourceTreeOID = review.sourceTreeOID
        } else {
            sourceOID = try git(root, "rev-parse", "HEAD")
            sourceTreeOID = try git(root, "rev-parse", "HEAD^{tree}")
        }
        let values: [String: Any] = [
            "case": name, "sourceOID": sourceOID,
            "sourceTreeOID": sourceTreeOID,
            "candidateOID": review.map { $0.candidateOID as Any } ?? NSNull(),
            "candidateTreeOID": review.map { $0.candidateTreeOID as Any } ?? NSNull(),
            "sourceDirty": sourceDirty, "candidateValidated": candidateValidated,
            "reviewDecision": reviewDecision, "sourceOIDAtPublish": try git(root, "rev-parse", "HEAD"),
            "casResult": casResult, "phaseAtStop": phaseAtStop, "recoveryResult": recoveryResult,
            "sourceBytesPreserved": sourceBytesPreserved,
            "worktreeClean": try git(root, "status", "--porcelain", "--untracked-files=all").isEmpty,
            "freshIndexResult": freshIndexResult, "gateReleased": !pending,
            "changedPaths": review?.changedPaths ?? [], "diffNameStatus": review?.diffNameStatus ?? "",
            "diffStat": review?.diffStat ?? "", "retentionRef": review?.retentionRef ?? "",
            "sourceFormatVersion": 1, "targetFormatVersion": review == nil ? NSNull() as Any : 3 as Any,
            "candidateParentOID": review.map { $0.sourceOID as Any } ?? NSNull(),
            "edgePath": review?.edgePath ?? [], "classification": review?.classification ?? "notClassified",
            "unexpectedChangedPaths": review?.changedPaths.filter {
                $0 != "hamii.json" && !$0.hasPrefix("screens/") && !$0.hasPrefix("components/")
            } ?? [],
            "oldSourceCommitReachable": (try? git(root, "cat-file", "-e", "\(sourceOID)^{commit}")) != nil
        ]
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: directory), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) + Data([0x0a])
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).json"))
    }

    private func gatedObservation(_ root: URL) throws {
        try WorktreeCoordinator(root: root).withExclusive {
            guard !FileManager.default.fileExists(atPath: pendingURL(root).path) else { throw ProbeFailure.gated }
        }
    }

    private func publish(_ review: Review, stop: ((String) throws -> Void)? = nil,
                         indexFails: Bool = false, classification: String? = nil) throws {
        guard (classification ?? review.classification) != "manual",
              (classification ?? review.classification) != "potentiallyLossy" else { throw ProbeFailure.ambiguous }
        let root = review.root
        try WorktreeCoordinator(root: root).withExclusive {
            try WorktreeCoordinator(root: root).requireReady()
            guard !FileManager.default.fileExists(atPath: pendingURL(root).path),
                  try git(root, "symbolic-ref", "--quiet", "HEAD") == review.sourceRef,
                  try git(root, "rev-parse", review.sourceRef) == review.sourceOID,
                  try git(root, "rev-parse", review.retentionRef) == review.candidateOID,
                  try git(root, "rev-parse", "\(review.candidateOID)^{tree}") == review.candidateTreeOID,
                  try git(root, "status", "--porcelain", "--untracked-files=all").isEmpty else { throw ProbeFailure.stale }
            let coordinator = WorktreeCoordinator(root: root)
            try coordinator.invalidateClientObservations()
            var record = Pending(formatVersion: 1, publicationID: UUID(), sourceRef: review.sourceRef,
                                 expectedSourceOID: review.sourceOID, candidateOID: review.candidateOID,
                                 candidateTreeOID: review.candidateTreeOID, retentionRef: review.retentionRef,
                                 sourceFormatVersion: 1, targetFormatVersion: 3, phase: .pending)
            try writePending(record, at: root)
            try stop?("pending")
            try git(root, "update-ref", review.sourceRef, review.candidateOID, review.sourceOID)
            record.phase = .refPublished; try writePending(record, at: root)
            try stop?("refPublished")
            try git(root, "reset", "--hard", review.candidateOID)
            record.phase = .worktreeMaterialized; try writePending(record, at: root)
            try stop?("worktreeMaterialized")
            try validate(files(root), blobsFrom: root)
            record.phase = .currentValidated; try writePending(record, at: root)
            try stop?("currentValidated")
            guard !indexFails else { throw ProbeFailure.injected }
            try freshIndex(files(root), blobsFrom: root)
            record.phase = .indexPublished; try writePending(record, at: root)
            try stop?("indexPublished")
            try FileManager.default.removeItem(at: pendingURL(root))
        }
    }

    private func recover(_ root: URL) throws -> String {
        try WorktreeCoordinator(root: root).withExclusive {
            let record = try readPending(root)
            guard try git(root, "rev-parse", record.retentionRef) == record.candidateOID,
                  try git(root, "rev-parse", "\(record.candidateOID)^{tree}") == record.candidateTreeOID else {
                throw ProbeFailure.unknown
            }
            let head = try git(root, "rev-parse", record.sourceRef)
            if head == record.expectedSourceOID {
                guard try git(root, "status", "--porcelain", "--untracked-files=all").isEmpty else { throw ProbeFailure.unknown }
                try FileManager.default.removeItem(at: pendingURL(root))
                return "old"
            }
            guard head == record.candidateOID else { throw ProbeFailure.unknown }
            try git(root, "reset", "--hard", record.candidateOID)
            guard try git(root, "status", "--porcelain", "--untracked-files=all").isEmpty else { throw ProbeFailure.unknown }
            try validate(files(root), blobsFrom: root)
            try freshIndex(files(root), blobsFrom: root)
            try FileManager.default.removeItem(at: pendingURL(root))
            return "candidate"
        }
    }

    func testReviewCandidateAndPublicationMatrix() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try files(root)
        let originalHead = try git(root, "rev-parse", "HEAD")
        let first = try prepare(root)
        XCTAssertEqual(try files(root), original)
        XCTAssertEqual(try git(root, "rev-parse", "HEAD"), originalHead)
        XCTAssertEqual(try git(root, "rev-parse", first.retentionRef), first.candidateOID)
        XCTAssertTrue(first.changedPaths.contains("hamii.json"))
        XCTAssertTrue(first.changedPaths.contains(where: { $0.hasPrefix("screens/") }))
        let second = try prepare(root)
        XCTAssertEqual(second.candidateTreeOID, first.candidateTreeOID)
        XCTAssertEqual(second.sourceOID, first.sourceOID)
        try cleanup(second) // explicit review rejection; source remains unchanged
        XCTAssertEqual(try files(root), original)
        try record("clean-review-reject", root: root, review: second, candidateValidated: true,
                   reviewDecision: "reject", sourceBytesPreserved: true, freshIndexResult: "candidate fresh rebuild passed")
        XCTAssertThrowsError(try publish(first, classification: "manual"))
        XCTAssertThrowsError(try publish(first, classification: "potentiallyLossy"))
        XCTAssertEqual(try files(root), original)
        let oldEpoch = try WorktreeCoordinator(root: root).withExclusive {
            try WorktreeCoordinator(root: root).clientEpoch()
        }
        try publish(first)
        XCTAssertEqual(try git(root, "rev-parse", "HEAD"), first.candidateOID)
        XCTAssertTrue(try git(root, "status", "--porcelain", "--untracked-files=all").isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingURL(root).path))
        XCTAssertNotEqual(try Data(contentsOf: root.appendingPathComponent(".hamii/client-observation-epoch")), Data((oldEpoch + "\n").utf8))
        XCTAssertEqual(try RawFormatUpgradeProbe.version(files(root)), 3)
        try record("clean-review-accept", root: root, review: first, candidateValidated: true,
                   reviewDecision: "accept", casResult: "success", recoveryResult: "ready",
                   sourceBytesPreserved: false, freshIndexResult: "post-CAS fresh rebuild passed")
        try cleanup(first)
    }

    func testDirtySourceAndValidationFailureDoNotPublish() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try files(root)
        let manifest = root.appendingPathComponent("hamii.json")
        try Data("\n".utf8).append(to: manifest)
        XCTAssertThrowsError(try prepare(root))
        try record("dirty-tracked", root: root, sourceDirty: true, sourceBytesPreserved: false)
        try original["hamii.json"]!.write(to: manifest)
        let untracked = root.appendingPathComponent("screens/new-screen.json")
        try Data("{}".utf8).write(to: untracked)
        XCTAssertThrowsError(try prepare(root))
        try record("dirty-untracked", root: root, sourceDirty: true, sourceBytesPreserved: false)
        try FileManager.default.removeItem(at: untracked)
        XCTAssertThrowsError(try prepare(root, failCandidateValidation: true)) { error in
            guard case CanonicalError.invalid(let diagnostics) = error else { return XCTFail("Expected semantic rejection: \(error)") }
            XCTAssertTrue(diagnostics.contains(where: { $0.rule == "token.missing" }))
        }
        try record("candidate-validation-failure", root: root, sourceBytesPreserved: true)
        XCTAssertThrowsError(try prepare(root, requiredObjectAvailable: false)) { error in
            guard case CanonicalError.invalid(let diagnostics) = error else { return XCTFail("Expected asset rejection: \(error)") }
            XCTAssertTrue(diagnostics.contains(where: { $0.rule == "asset.integrity" }))
        }
        try record("required-object-unavailable", root: root, sourceBytesPreserved: true)
        XCTAssertEqual(try files(root), original)
        XCTAssertTrue(try git(root, "status", "--porcelain", "--untracked-files=all").isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingURL(root).path))
    }

    func testSourceMovementAndCandidateMutationRequireNewReview() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let review = try prepare(root)
        let candidateManifest = review.candidateRoot.appendingPathComponent("hamii.json")
        try Data("\n".utf8).append(to: candidateManifest)
        try git(review.candidateRoot, "add", "-A")
        try git(review.candidateRoot, "commit", "-qm", "edited after review")
        XCTAssertNotEqual(try git(review.candidateRoot, "rev-parse", "HEAD"), review.candidateOID)
        XCTAssertEqual(try git(root, "rev-parse", review.retentionRef), review.candidateOID)
        let modifiedOID = try git(review.candidateRoot, "rev-parse", "HEAD")
        let modified = Review(root: review.root, candidateRoot: review.candidateRoot, sourceRef: review.sourceRef,
                              sourceOID: review.sourceOID, sourceTreeOID: review.sourceTreeOID,
                              candidateOID: modifiedOID, candidateTreeOID: try git(root, "rev-parse", "\(modifiedOID)^{tree}"),
                              retentionRef: review.retentionRef, edgePath: review.edgePath,
                              classification: review.classification, changedPaths: review.changedPaths,
                              diffNameStatus: review.diffNameStatus, diffStat: review.diffStat)
        XCTAssertThrowsError(try publish(modified)) // retained review identity is still the old OID
        try record("candidate-edited-after-review", root: root, review: review, candidateValidated: true,
                   reviewDecision: "re-review required", sourceBytesPreserved: true,
                   freshIndexResult: "original candidate fresh rebuild passed")
        try Data("note\n".utf8).write(to: root.appendingPathComponent("note.txt"))
        try git(root, "add", "-A")
        try git(root, "commit", "-qm", "source moved")
        let moved = try git(root, "rev-parse", "HEAD")
        let mergeProbe = temp("cross-format-merge-negative")
        try git(root, "worktree", "add", "--detach", mergeProbe.path, moved)
        defer { _ = try? git(root, "worktree", "remove", "--force", mergeProbe.path) }
        _ = try git(mergeProbe, "merge", "--no-ff", "--no-edit", review.candidateOID)
        XCTAssertNotEqual(try git(mergeProbe, "rev-parse", "HEAD"), review.candidateOID)
        XCTAssertEqual(try git(root, "rev-parse", "HEAD"), moved)
        XCTAssertThrowsError(try publish(review))
        XCTAssertEqual(try git(root, "rev-parse", "HEAD"), moved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingURL(root).path))
        try record("source-moved-after-review", root: root, review: review, candidateValidated: true,
                   reviewDecision: "accept", casResult: "preflight rejected stale source",
                   sourceBytesPreserved: false, freshIndexResult: "candidate fresh rebuild passed")
        try cleanup(review)
    }

    func testPendingRecoveryOldCandidateAndUnknown() throws {
        for stage in ["pending", "refPublished", "worktreeMaterialized", "currentValidated", "indexPublished"] {
            let root = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let review = try prepare(root)
            XCTAssertThrowsError(try publish(review, stop: { if $0 == stage { throw ProbeFailure.injected } }))
            XCTAssertThrowsError(try gatedObservation(root))
            let state = try recover(root)
            XCTAssertEqual(state, stage == "pending" ? "old" : "candidate")
            try gatedObservation(root)
            XCTAssertFalse(FileManager.default.fileExists(atPath: pendingURL(root).path))
            XCTAssertEqual(try git(root, "rev-parse", "HEAD"), stage == "pending" ? review.sourceOID : review.candidateOID)
            try record("injected-\(stage)", root: root, review: review, candidateValidated: true,
                       reviewDecision: "accept", casResult: stage == "pending" ? "notAttempted" : "success",
                       phaseAtStop: stage, recoveryResult: state, sourceBytesPreserved: stage == "pending",
                       freshIndexResult: state == "candidate" ? "recovered fresh rebuild passed" : "candidate fresh rebuild passed")
            try cleanup(review)
        }
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let review = try prepare(root)
        XCTAssertThrowsError(try publish(review, indexFails: true))
        XCTAssertEqual(try git(root, "rev-parse", "HEAD"), review.candidateOID)
        XCTAssertThrowsError(try gatedObservation(root))
        XCTAssertEqual(try recover(root), "candidate")
        try gatedObservation(root)
        try record("index-rebuild-failure", root: root, review: review, candidateValidated: true,
                   reviewDecision: "accept", casResult: "success", phaseAtStop: "currentValidated",
                   recoveryResult: "candidate", sourceBytesPreserved: false,
                   freshIndexResult: "injected failure then recovered fresh rebuild passed")
        try cleanup(review)
    }

    func testUnknownSourceAndCASRaceRemainGated() throws {
        for mode in ["unknownRecovery", "casRace"] {
            let root = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let review = try prepare(root)
            let foreign = try git(root, "commit-tree", review.sourceTreeOID, "-p", review.sourceOID, "-m", "foreign")
            XCTAssertThrowsError(try publish(review, stop: { phase in
                if phase == "pending" {
                    if mode == "casRace" { try self.git(root, "update-ref", review.sourceRef, foreign, review.sourceOID) }
                    else { throw ProbeFailure.injected }
                }
            }))
            if mode == "unknownRecovery" { try git(root, "update-ref", review.sourceRef, foreign, review.sourceOID) }
            XCTAssertEqual(try git(root, "rev-parse", review.sourceRef), foreign)
            XCTAssertThrowsError(try recover(root))
            XCTAssertThrowsError(try gatedObservation(root))
            XCTAssertTrue(FileManager.default.fileExists(atPath: pendingURL(root).path))
            try record(mode, root: root, review: review, candidateValidated: true, reviewDecision: "accept",
                       casResult: mode == "casRace" ? "expected-OID CAS rejected" : "notAttempted",
                       phaseAtStop: "pending", recoveryResult: "unknown; gate remains",
                       sourceBytesPreserved: false, freshIndexResult: "notPublished")
            try git(root, "worktree", "remove", "--force", review.candidateRoot.path)
        }
    }

    private func child(_ method: String, environment: [String: String]) throws -> Process {
        let executable = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw CocoaError(.executableNotLoadable) }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-XCTest", "HamiiTests.MigrationReviewProtocolSpikeTests/\(method)", Bundle(for: Self.self).bundleURL.path]
        var values = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        for index in 0..<_dyld_image_count() {
            guard let image = _dyld_get_image_name(index) else { continue }
            let path = String(cString: image)
            if path.hasSuffix("/libTesting.dylib") {
                values["DYLD_LIBRARY_PATH"] = URL(fileURLWithPath: path).deletingLastPathComponent().path
                break
            }
        }
        process.environment = values
        process.standardOutput = Pipe()
        process.standardError = process.standardOutput
        try process.run()
        return process
    }

    private func awaitFile(_ url: URL, process: Process) throws {
        let deadline = Date().addingTimeInterval(45)
        while !FileManager.default.fileExists(atPath: url.path) && process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            let output = (process.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
            XCTFail("Worker did not signal \(url.lastPathComponent): \(String(decoding: output, as: UTF8.self))")
            throw ProbeFailure.injected
        }
    }

    func testMigrationWorker() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rootPath = environment["HAMII_MIGRATION_REVIEW_ROOT"],
              let stage = environment["HAMII_MIGRATION_REVIEW_STAGE"] else { throw XCTSkip("Worker only") }
        let root = URL(fileURLWithPath: rootPath)
        func stop(_ phase: String) -> Never {
            try! Data(phase.utf8).write(to: root.appendingPathComponent(".hamii/test-migration-paused"))
            while true { Thread.sleep(forTimeInterval: 1) }
        }
        if stage == "transform" {
            _ = try prepare(root, stop: { if $0 == stage { stop($0) } })
        } else {
            let bytes = try Data(contentsOf: root.appendingPathComponent(".hamii/test-migration-review.json"))
            let review = try JSONDecoder().decode(Review.self, from: bytes)
            try publish(review, stop: { if $0 == stage { stop($0) } })
        }
        XCTFail("Worker reached Ready without its requested pause")
    }

    func testMigrationReaderWorker() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rootPath = environment["HAMII_MIGRATION_REVIEW_ROOT"],
              let attempt = environment["HAMII_MIGRATION_REVIEW_ATTEMPT"],
              let result = environment["HAMII_MIGRATION_REVIEW_RESULT"] else { throw XCTSkip("Worker only") }
        try Data().write(to: URL(fileURLWithPath: attempt))
        let state: String
        do { try gatedObservation(URL(fileURLWithPath: rootPath)); state = "ready" }
        catch ProbeFailure.gated { state = "pending" }
        try Data(state.utf8).write(to: URL(fileURLWithPath: result))
    }

    func testSIGKILLReviewPublicationStopsAndRecovery() throws {
        for stage in ["transform", "pending", "refPublished", "currentValidated", "indexPublished"] {
            let root = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let sourceOID = try git(root, "rev-parse", "HEAD")
            let sourceBytes = try files(root)
            let review = stage == "transform" ? nil : try prepare(root)
            if let review {
                try JSONEncoder().encode(review).write(to: root.appendingPathComponent(".hamii/test-migration-review.json"))
            }
            let paused = root.appendingPathComponent(".hamii/test-migration-paused")
            let attempt = root.appendingPathComponent(".hamii/test-migration-reader-attempt")
            let result = root.appendingPathComponent(".hamii/test-migration-reader-result")
            let environment = ["HAMII_MIGRATION_REVIEW_ROOT": root.path, "HAMII_MIGRATION_REVIEW_STAGE": stage,
                               "HAMII_MIGRATION_REVIEW_ATTEMPT": attempt.path, "HAMII_MIGRATION_REVIEW_RESULT": result.path]
            let writer = try child("testMigrationWorker", environment: environment)
            defer { if writer.isRunning { _ = kill(writer.processIdentifier, SIGKILL); writer.waitUntilExit() } }
            try awaitFile(paused, process: writer)
            let reader = try child("testMigrationReaderWorker", environment: environment)
            defer { if reader.isRunning { _ = kill(reader.processIdentifier, SIGKILL); reader.waitUntilExit() } }
            try awaitFile(attempt, process: reader)
            if stage != "transform" {
                Thread.sleep(forTimeInterval: 0.12)
                XCTAssertFalse(FileManager.default.fileExists(atPath: result.path), "Reader crossed writer lock at \(stage)")
            }
            XCTAssertEqual(kill(writer.processIdentifier, SIGKILL), 0, stage)
            writer.waitUntilExit()
            XCTAssertEqual(writer.terminationReason, .uncaughtSignal, stage)
            XCTAssertEqual(writer.terminationStatus, SIGKILL, stage)
            try awaitFile(result, process: reader)
            reader.waitUntilExit()
            XCTAssertEqual(reader.terminationStatus, 0, stage)
            XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), stage == "transform" ? "ready" : "pending", stage)
            if stage == "transform" {
                XCTAssertEqual(try git(root, "rev-parse", "HEAD"), sourceOID)
                XCTAssertEqual(try files(root), sourceBytes)
                XCTAssertFalse(FileManager.default.fileExists(atPath: pendingURL(root).path))
                try record("sigkill-transform", root: root, phaseAtStop: "transform", recoveryResult: "source untouched",
                           sourceBytesPreserved: true)
                let worktrees = try git(root, "worktree", "list", "--porcelain")
                let mainPath = root.resolvingSymlinksInPath().standardizedFileURL.path
                for line in worktrees.split(separator: "\n") where line.hasPrefix("worktree ") {
                    let path = String(line.dropFirst("worktree ".count))
                    if URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path != mainPath {
                        try git(root, "worktree", "remove", "--force", path)
                    }
                }
            } else {
                XCTAssertThrowsError(try gatedObservation(root))
                XCTAssertEqual(try recover(root), stage == "pending" ? "old" : "candidate")
                XCTAssertEqual(try git(root, "rev-parse", "HEAD"), stage == "pending" ? sourceOID : review!.candidateOID)
                try gatedObservation(root)
                try record("sigkill-\(stage)", root: root, review: review, candidateValidated: true,
                           reviewDecision: "accept", casResult: stage == "pending" ? "notAttempted" : "success",
                           phaseAtStop: stage, recoveryResult: stage == "pending" ? "old" : "candidate",
                           sourceBytesPreserved: stage == "pending",
                           freshIndexResult: "recovery fresh rebuild passed")
                try cleanup(review!)
            }
        }
    }
}

private extension Data {
    func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: self)
    }
}
