import Foundation
import XCTest
@testable import HamiiMigrationRuntime
@testable import HamiiFormat
import HamiiCore
import HamiiMigrations

final class MigrationCandidatePreparationTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func git(_ root: URL, _ args: String...) throws -> String { try GitCommand.run(at: root, args) }
    private func git(_ root: URL, _ args: [String]) throws -> String { try GitCommand.run(at: root, args) }

    private func fixture(current: Bool = false) throws -> URL {
        let source = repositoryRoot.appendingPathComponent(current ? "Samples/Starter" : "Tests/Fixtures/format-v1-safe-project")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hamii-migration-source-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: root)
        try Data(".hamii/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        _ = try git(root, "init", "-q")
        _ = try git(root, "checkout", "-q", "-b", "main")
        _ = try git(root, "add", ".")
        _ = try git(root, "-c", "user.name=Test", "-c", "user.email=test@localhost", "commit", "-q", "-m", "v1")
        return root
    }

    private func retentionRefs(_ root: URL) throws -> [String] {
        let output = try git(root, "for-each-ref", "--format=%(refname)", "refs/hamii/migration-candidates")
        return output.split(separator: "\n").map(String.init)
    }

    func testSafeSourceProducesImmutableReviewPackageAndDeterministicTree() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let head = try git(root, "rev-parse", "HEAD")
        let tree = try git(root, "rev-parse", "HEAD^{tree}")
        let sourceBytes = try Data(contentsOf: root.appendingPathComponent("hamii.json"))
        let epoch = root.appendingPathComponent(".hamii/client-observation-epoch")
        try FileManager.default.createDirectory(at: epoch.deletingLastPathComponent(), withIntermediateDirectories: true)
        let oldEpoch = Data((UUID().uuidString + "\n").utf8)
        try oldEpoch.write(to: epoch)
        var worktrees: [URL] = []
        let preparer = MigrationCandidatePreparer { step in
            if case .beforeRetention(let url) = step { worktrees.append(url) }
        }
        var packages: [MigrationPreparedReview] = []
        for _ in 0..<3 {
            packages.append(try preparer.prepare(repository: root))
        }
        XCTAssertEqual(Set(packages.map(\.candidateTreeOID)).count, 1)
        for review in packages {
            XCTAssertEqual(review.sourceRef, "refs/heads/main")
            XCTAssertEqual(review.sourceOID, head)
            XCTAssertEqual(review.sourceTreeOID, tree)
            XCTAssertEqual(review.sourceDocumentRevision, review.candidateDocumentRevision)
            XCTAssertEqual(review.validation.currentFormat, 3)
            XCTAssertEqual(review.validation.canonicalSnapshotIdentity, review.indexValidation.sourceCanonicalIdentity)
            XCTAssertEqual(try git(root, "rev-parse", review.retentionRef), review.candidateOID)
            XCTAssertEqual(try git(root, "rev-list", "--parents", "-n", "1", review.candidateOID), "\(review.candidateOID) \(head)")
            XCTAssertEqual(try git(root, "rev-parse", "\(review.candidateOID)^{tree}"), review.candidateTreeOID)
            XCTAssertTrue(review.changedPaths.contains("hamii.json"))
            XCTAssertTrue(review.changedPaths.contains("screens/screen_main.json"))
            XCTAssertTrue(review.changedPaths.contains("components/component_badge.json"))
            XCTAssertTrue(review.diffNameStatus.contains("hamii.json"))
            XCTAssertTrue(review.diffStat.contains("hamii.json"))
        }
        XCTAssertEqual(try retentionRefs(root).count, 3)
        XCTAssertTrue(worktrees.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(try git(root, "worktree", "list", "--porcelain").components(separatedBy: "worktree ").count, 2)
        XCTAssertEqual(try git(root, "rev-parse", "HEAD"), head)
        XCTAssertEqual(try git(root, "rev-parse", "refs/heads/main"), head)
        XCTAssertEqual(try git(root, "status", "--porcelain=v1", "--untracked-files=all"), "")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("hamii.json")), sourceBytes)
        XCTAssertEqual(try Data(contentsOf: epoch), oldEpoch)
    }

    func testCurrentManualDirtyAndDetachedSourcesProduceNoRetention() throws {
        let current = try fixture(current: true)
        defer { try? FileManager.default.removeItem(at: current) }
        XCTAssertThrowsError(try MigrationCandidatePreparer().prepare(repository: current)) { error in
            guard case MigrationPreparationError.alreadyCurrent = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(try retentionRefs(current).isEmpty)
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("dirty\n".utf8).write(to: root.appendingPathComponent("untracked.txt"))
        XCTAssertThrowsError(try MigrationCandidatePreparer().prepare(repository: root))
        try FileManager.default.removeItem(at: root.appendingPathComponent("untracked.txt"))
        try Data("dirty\n".utf8).write(to: root.appendingPathComponent("hamii.json"))
        XCTAssertThrowsError(try MigrationCandidatePreparer().prepare(repository: root))
        _ = try git(root, "checkout", "--", "hamii.json")
        _ = try git(root, "checkout", "--detach", "-q")
        XCTAssertThrowsError(try MigrationCandidatePreparer().prepare(repository: root)) { error in
            guard case MigrationPreparationError.detachedSource = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(try retentionRefs(root).isEmpty)
    }

    func testFailureInjectionNeverCreatesReviewReadyRetention() throws {
        for stage in ["transform", "validation", "index", "unexpected", "sourceMoved", "branchMoved"] {
            let root = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let oldHead = try git(root, "rev-parse", "HEAD")
            var candidateRoot: URL?
            let preparer = MigrationCandidatePreparer { step in
                switch (stage, step) {
                case ("transform", .afterTransform(let url)):
                    candidateRoot = url
                    throw MigrationPreparationError.invalidCandidate("injected transform failure")
                case ("unexpected", .afterTransform(let url)):
                    candidateRoot = url
                    try Data("extra\n".utf8).write(to: url.appendingPathComponent("README.md"))
                case ("validation", .beforeCurrentValidation(let url)):
                    candidateRoot = url
                    try FileManager.default.removeItem(at: url.appendingPathComponent("tokens/token_space.json"))
                case ("index", .beforeIndexValidation(let url)):
                    candidateRoot = url
                    try Data("not a directory".utf8).write(to: url.deletingLastPathComponent().appendingPathComponent("indexes"))
                case ("sourceMoved", .beforeRetention(let url)):
                    candidateRoot = url
                    try Data("new\n".utf8).write(to: root.appendingPathComponent("external.txt"))
                    _ = try self.git(root, "add", "external.txt")
                    _ = try self.git(root, "-c", "user.name=Test", "-c", "user.email=test@localhost", "commit", "-q", "-m", "external")
                case ("branchMoved", .beforeRetention(let url)):
                    candidateRoot = url
                    _ = try self.git(root, "branch", "alternate")
                    _ = try self.git(root, "switch", "-q", "alternate")
                default: break
                }
            }
            XCTAssertThrowsError(try preparer.prepare(repository: root), stage)
            XCTAssertTrue(try retentionRefs(root).isEmpty, stage)
            XCTAssertFalse(FileManager.default.fileExists(atPath: candidateRoot?.path ?? "missing"), stage)
            if stage != "sourceMoved" { XCTAssertEqual(try git(root, "rev-parse", "HEAD"), oldHead, stage) }
        }
    }

    func testReviewRecordFailureRemovesRetentionRef() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent(".hamii")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: local.appendingPathComponent("migration-reviews"))
        XCTAssertThrowsError(try MigrationCandidatePreparer().prepare(repository: root))
        XCTAssertTrue(try retentionRefs(root).isEmpty)
        XCTAssertEqual(try git(root, "status", "--porcelain=v1", "--untracked-files=all"), "")
    }

    func testHiddenGitIndexFlagsDoNotPassCleanSourceGate() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try git(root, "update-index", "--assume-unchanged", "hamii.json")
        XCTAssertThrowsError(try MigrationCandidatePreparer().prepare(repository: root))
        XCTAssertTrue(try retentionRefs(root).isEmpty)
    }

    func testAnyUnrecoveredCanonicalJournalBlocksPreparation() throws {
        for name in ["transaction.prepare", "transaction.ready", "transaction.complete"] {
            let root = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let journal = root.appendingPathComponent(".hamii/\(name)")
            try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
            XCTAssertEqual(try MigrationPreflight.plan(repository: root).state, "pendingCanonicalTransaction")
            XCTAssertThrowsError(try MigrationCandidatePreparer().prepare(repository: root), name)
            XCTAssertTrue(try retentionRefs(root).isEmpty)
        }
    }

    func testChangedCandidateCommitCannotReuseOriginalReviewIdentity() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var changedOID: String?
        let preparer = MigrationCandidatePreparer { step in
            if case .beforeRetention(let candidate) = step {
                _ = try self.git(candidate, "-c", "user.name=Test", "-c", "user.email=test@localhost",
                                 "-c", "core.hooksPath=/dev/null", "commit", "--amend", "--no-gpg-sign", "-q", "-m", "Changed after validation")
                changedOID = try self.git(candidate, "rev-parse", "HEAD")
            }
        }
        let review = try preparer.prepare(repository: root)
        XCTAssertNotEqual(changedOID, review.candidateOID)
        XCTAssertEqual(try git(root, "rev-parse", review.retentionRef), review.candidateOID)
        XCTAssertEqual(try git(root, "rev-parse", "\(review.candidateOID)^{tree}"), review.candidateTreeOID)
    }

    func testManualHistoricalResidualAndMissingRepositoryAssetReject() throws {
        for manual in [true, false] {
            let root = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let path = manual ? "screens/screen_main.json" : "assets/asset_symbol.json"
            let url = root.appendingPathComponent(path)
            var entity = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            if manual {
                var layer = try XCTUnwrap(entity["root"] as? [String: Any])
                layer["assetID"] = ["rawValue": "asset_symbol"]
                entity["root"] = layer
            } else {
                entity["source"] = ["repository": ["path": "assets/blobs/sha256/missing"]]
                entity["contentHash"] = String(repeating: "a", count: 64)
            }
            try JSONSerialization.data(withJSONObject: entity).write(to: url)
            _ = try git(root, "add", path)
            _ = try git(root, "-c", "user.name=Test", "-c", "user.email=test@localhost", "commit", "-q", "-m", "case")
            XCTAssertThrowsError(try MigrationCandidatePreparer().prepare(repository: root))
            XCTAssertTrue(try retentionRefs(root).isEmpty)
        }
    }

    func testCLIJSONReviewPackageAndStructuredManualBlocker() throws {
        let executable = repositoryRoot.appendingPathComponent(".build/out/Products/Debug/hamii")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        func invoke(_ root: URL) throws -> (Int32, [String: Any]) {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--project", root.path, "migrate", "prepare", "--json"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any]))
        }
        let safe = try fixture()
        defer { try? FileManager.default.removeItem(at: safe) }
        let (successCode, success) = try invoke(safe)
        XCTAssertEqual(successCode, 0)
        XCTAssertEqual(success["ok"] as? Bool, true)
        let review = try XCTUnwrap(success["migrationReview"] as? [String: Any])
        for field in ["sourceOID", "candidateOID", "candidateTreeOID", "retentionRef", "classification", "edgePath", "changedPaths", "validation", "indexValidation"] {
            XCTAssertNotNil(review[field], field)
        }
        XCTAssertNil(review["published"])
        XCTAssertNil(review["applied"])

        let manual = try fixture()
        defer { try? FileManager.default.removeItem(at: manual) }
        let screenURL = manual.appendingPathComponent("screens/screen_main.json")
        var screen = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: screenURL)) as? [String: Any])
        var layer = try XCTUnwrap(screen["root"] as? [String: Any])
        layer["assetID"] = ["rawValue": "asset_symbol"]
        screen["root"] = layer
        try JSONSerialization.data(withJSONObject: screen).write(to: screenURL)
        _ = try git(manual, "add", "screens/screen_main.json")
        _ = try git(manual, "-c", "user.name=Test", "-c", "user.email=test@localhost", "commit", "-q", "-m", "manual")
        let (failureCode, failure) = try invoke(manual)
        XCTAssertEqual(failureCode, 6)
        XCTAssertEqual(failure["ok"] as? Bool, false)
        XCTAssertEqual(failure["category"] as? String, "migration")
        XCTAssertTrue((failure["blockers"] as? [String] ?? []).contains { $0.contains("layer_root") })
        XCTAssertTrue(try retentionRefs(manual).isEmpty)
    }
}
