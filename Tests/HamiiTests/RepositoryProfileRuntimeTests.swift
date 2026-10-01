import CryptoKit
import Foundation
import XCTest
import HamiiCore
@testable import HamiiFormat
import HamiiIntegration
@testable import HamiiIntegrationRuntime

final class RepositoryProfileRuntimeTests: XCTestCase {
    private let screenID = EntityID("screen_profile")
    private let profilePath = "config/profile file.json"

    private struct Fixture {
        let directory: URL
        let hamii: URL
        let product: URL
        let profilePath: String
    }

    private func fixture(profilePath: String = "config/profile file.json") throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("repository-profile-\(UUID().uuidString)")
        let hamii = directory.appendingPathComponent("hamii")
        let product = directory.appendingPathComponent("Product")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repository = CanonicalRepository(root: hamii)
        _ = try repository.create(name: "Profile")
        let observed = try repository.observe()
        var document = observed.document
        let scope = EntityID("scope_app")
        document.scopes = [ArchitectureScope(id: scope, name: "App", parentID: nil)]
        document.screens = [
            Screen(id: screenID, name: "Profile", scopeID: scope,
                root: Layer(id: EntityID("layer_root"), kind: .stack, name: "Root")),
            Screen(id: EntityID("screen_other"), name: "Other", scopeID: scope,
                root: Layer(id: EntityID("layer_other"), kind: .stack, name: "Other Root"))
        ]
        document.revision += 1
        _ = try repository.commit(document, expected: observed)

        try FileManager.default.createDirectory(at: product, withIntermediateDirectories: true)
        try git(product, "init", "-q")
        try git(product, "config", "user.name", "Profile Test")
        try git(product, "config", "user.email", "profile@example.invalid")
        let path = product.appendingPathComponent(profilePath)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(IntegrationProfile(repositoryName: "Product")).write(to: path)
        try git(product, "add", "--", profilePath)
        try git(product, "commit", "-qm", "Add profile")
        return Fixture(directory: directory, hamii: hamii, product: product, profilePath: profilePath)
    }

    @discardableResult private func git(_ root: URL, _ args: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + args
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "GitTest", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func plan(_ fixture: Fixture, path: String? = nil) throws -> RepositoryProfilePlanResult {
        try RepositoryProfileRuntime.plan(hamiiRoot: fixture.hamii, productRoot: fixture.product,
            profilePath: path ?? fixture.profilePath, screenID: screenID)
    }

    private func assertIssue(_ category: String, _ reason: String, _ action: () throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) { error in
            XCTAssertEqual(error as? RepositoryProfileRuntimeError,
                RepositoryProfileRuntimeError(category: category, reason: reason), file: file, line: line)
        }
    }

    func testReceiptPinsCommittedBlobAndExactHamiiObservation() throws {
        let item = try fixture()
        defer { try? FileManager.default.removeItem(at: item.directory) }
        let headBefore = try git(item.product, "rev-parse", "HEAD")
        let branchBefore = try git(item.product, "branch", "--show-current")
        let statusBefore = try git(item.product, "status", "--porcelain=v2", "--untracked-files=all")
        let indexURL = item.product.appendingPathComponent(".git/index")
        let indexBefore = try Data(contentsOf: indexURL)
        let worktreeBefore = try Data(contentsOf: item.product.appendingPathComponent(profilePath))
        let result = try plan(item)
        XCTAssertEqual(try git(item.product, "rev-parse", "HEAD"), headBefore)
        XCTAssertEqual(try git(item.product, "branch", "--show-current"), branchBefore)
        XCTAssertEqual(try git(item.product, "status", "--porcelain=v2", "--untracked-files=all"), statusBefore)
        XCTAssertEqual(try Data(contentsOf: indexURL), indexBefore)
        XCTAssertEqual(try Data(contentsOf: item.product.appendingPathComponent(profilePath)), worktreeBefore)
        let receipt = result.receipt
        let observation = try CanonicalRepository(root: item.hamii).observe()
        XCTAssertEqual(receipt.productCommitOID, try git(item.product, "rev-parse", "HEAD"))
        XCTAssertEqual(receipt.profilePath, profilePath)
        XCTAssertEqual(receipt.profileFormatVersion, 1)
        XCTAssertEqual(receipt.hamiiDocumentID, observation.document.id)
        XCTAssertEqual(receipt.hamiiDocumentRevision, observation.document.revision)
        XCTAssertEqual(receipt.hamiiStatePrecondition, observation.statePrecondition)
        XCTAssertEqual(receipt.screenID, screenID)
        XCTAssertEqual(receipt.profileSHA256, hash(try Data(contentsOf: item.product.appendingPathComponent(profilePath))))
        let contract = try IntegrationContracts.make(screenID: screenID, document: observation.document)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(receipt.contractSHA256, hash(try encoder.encode(contract)))
        XCTAssertFalse(result.plan.needsResolution)
        XCTAssertEqual(try plan(item).receipt, receipt)
        let other = try RepositoryProfileRuntime.plan(hamiiRoot: item.hamii, productRoot: item.product,
            profilePath: profilePath, screenID: EntityID("screen_other"))
        XCTAssertEqual(other.receipt.hamiiStatePrecondition, receipt.hamiiStatePrecondition)
        XCTAssertNotEqual(other.receipt.contractSHA256, receipt.contractSHA256)

        let clone = item.directory.appendingPathComponent("Relocated Product")
        try git(item.directory, "clone", "-q", item.product.path, clone.path)
        let moved = try RepositoryProfileRuntime.plan(hamiiRoot: item.hamii, productRoot: clone,
            profilePath: profilePath, screenID: screenID)
        XCTAssertEqual(moved.receipt, receipt)
        XCTAssertEqual(try RepositoryProfileRuntime.verify(receipt: receipt, hamiiRoot: item.hamii,
            productRoot: clone).receipt, receipt)
        try git(item.product, "branch", "-m", "renamed-profile-branch")
        XCTAssertEqual(try RepositoryProfileRuntime.verify(receipt: receipt, hamiiRoot: item.hamii,
            productRoot: item.product).receipt, receipt)
        try git(item.product, "branch", "same-commit-branch")
        try git(item.product, "switch", "same-commit-branch")
        XCTAssertEqual(try RepositoryProfileRuntime.verify(receipt: receipt, hamiiRoot: item.hamii,
            productRoot: item.product).receipt, receipt)
    }

    func testPathAndTreeChecksRejectWrongSource() throws {
        let item = try fixture()
        defer { try? FileManager.default.removeItem(at: item.directory) }
        assertIssue("git", "invalidProductRoot") {
            _ = try RepositoryProfileRuntime.plan(hamiiRoot: item.hamii,
                productRoot: item.product.appendingPathComponent("config"),
                profilePath: item.profilePath, screenID: screenID)
        }
        for path in ["../profile.json", "/tmp/profile.json", "config//profile.json", "config/./profile.json"] {
            assertIssue("usage", "invalidProfilePath") { _ = try plan(item, path: path) }
        }
        assertIssue("contract", "missingProfile") { _ = try plan(item, path: "config/absent.json") }
        assertIssue("contract", "nonRegularProfile") { _ = try plan(item, path: "config") }
        assertIssue("contract", "missingProfile") { _ = try plan(item, path: "config/*.json") }
    }

    func testDirtyAndHiddenIndexChangesFailClosed() throws {
        let item = try fixture()
        defer { try? FileManager.default.removeItem(at: item.directory) }
        let file = item.product.appendingPathComponent(profilePath)
        try Data("different".utf8).write(to: file)
        assertIssue("conflict", "dirtyProduct") { _ = try plan(item) }
        try git(item.product, "checkout", "--", profilePath)
        try Data("staged".utf8).write(to: file)
        try git(item.product, "add", "--", profilePath)
        assertIssue("conflict", "dirtyProduct") { _ = try plan(item) }
        try git(item.product, "checkout", "HEAD", "--", profilePath)
        let untracked = item.product.appendingPathComponent("untracked.txt")
        try Data("new".utf8).write(to: untracked)
        assertIssue("conflict", "dirtyProduct") { _ = try plan(item) }
        try FileManager.default.removeItem(at: untracked)
        try git(item.product, "update-index", "--assume-unchanged", "--", profilePath)
        try Data("hidden".utf8).write(to: file)
        assertIssue("conflict", "unsafeGitMetadata") { _ = try plan(item) }
    }

    func testMissingUntrackedAndSymlinkProfileAreContractErrors() throws {
        let item = try fixture()
        defer { try? FileManager.default.removeItem(at: item.directory) }
        try Data("untracked".utf8).write(to: item.product.appendingPathComponent("extra.json"))
        assertIssue("contract", "missingProfile") { _ = try plan(item, path: "extra.json") }
        try FileManager.default.removeItem(at: item.product.appendingPathComponent(profilePath))
        try FileManager.default.createSymbolicLink(atPath: item.product.appendingPathComponent(profilePath).path,
            withDestinationPath: "../extra.json")
        try git(item.product, "add", "-A", "--", profilePath)
        try git(item.product, "commit", "-qm", "Replace profile with symlink")
        // The unrelated untracked file is still dirty, but the HEAD tree type is rejected first.
        assertIssue("contract", "nonRegularProfile") { _ = try plan(item) }
    }

    func testGitlinkAtProfilePathIsNonRegular() throws {
        let item = try fixture()
        defer { try? FileManager.default.removeItem(at: item.directory) }
        let commit = try git(item.product, "rev-parse", "HEAD")
        try git(item.product, "update-index", "--add", "--cacheinfo", "160000,\(commit),\(profilePath)")
        try git(item.product, "commit", "-qm", "Track gitlink at profile path")
        XCTAssertTrue(try git(item.product, "ls-tree", "HEAD", "--", profilePath).hasPrefix("160000 commit "))
        assertIssue("contract", "nonRegularProfile") { _ = try plan(item) }
    }

    func testDocumentProfileMarkerHasIndependentMigrationBoundary() throws {
        let item = try fixture()
        defer { try? FileManager.default.removeItem(at: item.directory) }
        let repository = CanonicalRepository(root: item.hamii)
        let observed = try repository.observe()
        var document = observed.document
        document.versions.integrationProfile = 2
        document.revision += 1
        _ = try repository.commit(document, expected: observed)
        assertIssue("migrationRequired", "unsupportedDocumentProfileVersion") { _ = try plan(item) }
    }

    func testCleanWorktreeWithGitEOLConversionPlansFromBlobBytes() throws {
        let item = try fixture()
        defer { try? FileManager.default.removeItem(at: item.directory) }
        let file = item.product.appendingPathComponent(profilePath)
        var bytes = try JSONEncoder().encode(IntegrationProfile(repositoryName: "Product"))
        bytes.append(UInt8(ascii: "\n"))
        try bytes.write(to: file)
        try Data("*.json text eol=crlf\n".utf8).write(to: item.product.appendingPathComponent(".gitattributes"))
        try git(item.product, "add", "--", profilePath, ".gitattributes")
        try git(item.product, "commit", "-qm", "Use CRLF worktree profile")
        try FileManager.default.removeItem(at: file)
        try git(item.product, "checkout", "HEAD", "--", profilePath)
        let worktreeBytes = try Data(contentsOf: file)
        XCTAssertNotEqual(worktreeBytes, bytes)
        XCTAssertTrue(try git(item.product, "status", "--porcelain=v2", "--untracked-files=all").isEmpty)
        let result = try plan(item)
        let blobBytes = try GitCommand.runData(at: item.product, ["cat-file", "blob", result.receipt.profileBlobOID])
        XCTAssertEqual(blobBytes, bytes)
        XCTAssertEqual(result.receipt.profileSHA256, hash(blobBytes))
        XCTAssertNotEqual(result.receipt.profileSHA256, hash(worktreeBytes))
    }

    func testChangedProductOrHamiiAfterCaptureIsRejected() throws {
        let item = try fixture()
        defer { try? FileManager.default.removeItem(at: item.directory) }
        assertIssue("conflict", "staleProduct") {
            _ = try RepositoryProfileRuntime.plan(hamiiRoot: item.hamii, productRoot: item.product,
                profilePath: profilePath, screenID: screenID, beforeFinalVerification: {
                    let extra = item.product.appendingPathComponent("README.md")
                    try Data("next".utf8).write(to: extra)
                    try git(item.product, "add", "README.md")
                    try git(item.product, "commit", "-qm", "Next commit")
                })
        }
        assertIssue("conflict", "staleHamiiObservation") {
            _ = try RepositoryProfileRuntime.plan(hamiiRoot: item.hamii, productRoot: item.product,
                profilePath: profilePath, screenID: screenID, beforeFinalVerification: {
                    let repository = CanonicalRepository(root: item.hamii)
                    let observed = try repository.observe()
                    var document = observed.document
                    document.name = "Changed"
                    document.revision += 1
                    _ = try repository.commit(document, expected: observed)
                })
        }
    }

    func testOldReceiptCannotBeReusedAfterProductOrHamiiChanges() throws {
        let item = try fixture()
        defer { try? FileManager.default.removeItem(at: item.directory) }
        let receipt = try plan(item).receipt
        let sourceDir = item.product.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try Data("struct Product {}".utf8).write(to: sourceDir.appendingPathComponent("Product.swift"))
        try git(item.product, "add", "Sources/Product.swift")
        try git(item.product, "commit", "-qm", "Change Product source")
        assertIssue("conflict", "staleProduct") {
            _ = try RepositoryProfileRuntime.verify(receipt: receipt, hamiiRoot: item.hamii, productRoot: item.product)
        }
        let sourceReceipt = try plan(item).receipt
        try Data("documentation".utf8).write(to: item.product.appendingPathComponent("README.md"))
        try git(item.product, "add", "README.md")
        try git(item.product, "commit", "-qm", "Documentation")
        assertIssue("conflict", "staleProduct") {
            _ = try RepositoryProfileRuntime.verify(receipt: sourceReceipt, hamiiRoot: item.hamii, productRoot: item.product)
        }
        let newer = try plan(item).receipt
        var mapping = IntegrationProfile(repositoryName: "Product")
        mapping.stateMappings["profile.name"] = "Product.Profile.name"
        try JSONEncoder().encode(mapping).write(to: item.product.appendingPathComponent(profilePath))
        try git(item.product, "add", "--", profilePath)
        try git(item.product, "commit", "-qm", "Change mapping")
        assertIssue("conflict", "staleProduct") {
            _ = try RepositoryProfileRuntime.verify(receipt: newer, hamiiRoot: item.hamii, productRoot: item.product)
        }
        let latest = try plan(item).receipt
        let repository = CanonicalRepository(root: item.hamii)
        let observed = try repository.observe()
        var document = observed.document
        document.name = "Updated"
        document.revision += 1
        _ = try repository.commit(document, expected: observed)
        assertIssue("conflict", "staleHamiiObservation") {
            _ = try RepositoryProfileRuntime.verify(receipt: latest, hamiiRoot: item.hamii, productRoot: item.product)
        }
    }

    func testUnrelatedRepositoryWithSameProfileBytesRejectsOldReceipt() throws {
        let original = try fixture()
        defer { try? FileManager.default.removeItem(at: original.directory) }
        let unrelated = try fixture()
        defer { try? FileManager.default.removeItem(at: unrelated.directory) }
        let sharedBytes = try Data(contentsOf: original.product.appendingPathComponent(profilePath))
        if try Data(contentsOf: unrelated.product.appendingPathComponent(profilePath)) != sharedBytes {
            try sharedBytes.write(to: unrelated.product.appendingPathComponent(profilePath))
            try git(unrelated.product, "add", "--", profilePath)
            try git(unrelated.product, "commit", "-qm", "Use identical profile bytes")
        }
        XCTAssertEqual(sharedBytes, try Data(contentsOf: unrelated.product.appendingPathComponent(profilePath)))
        try Data("other history".utf8).write(to: unrelated.product.appendingPathComponent("README.md"))
        try git(unrelated.product, "add", "README.md")
        try git(unrelated.product, "commit", "-qm", "Different history")
        let receipt = try plan(original).receipt
        assertIssue("conflict", "staleProduct") {
            _ = try RepositoryProfileRuntime.verify(receipt: receipt, hamiiRoot: original.hamii,
                productRoot: unrelated.product)
        }
    }

    func testStrictProfileDecodeAndIndependentVersionBoundary() throws {
        let item = try fixture()
        defer { try? FileManager.default.removeItem(at: item.directory) }
        let file = item.product.appendingPathComponent(profilePath)
        let original = try String(contentsOf: file, encoding: .utf8)
        try Data(original.replacingOccurrences(of: "\"formatVersion\":1", with: "\"formatVersion\":2").utf8).write(to: file)
        try git(item.product, "add", "--", profilePath)
        try git(item.product, "commit", "-qm", "Future profile")
        assertIssue("migrationRequired", "unsupportedProfileVersion") { _ = try plan(item) }
        let future = try String(contentsOf: file, encoding: .utf8)
        try Data(future.replacingOccurrences(of: "\"formatVersion\":2", with: "\"formatVersion\":1,\"formatVersion\":1").utf8).write(to: file)
        try git(item.product, "add", "--", profilePath)
        try git(item.product, "commit", "-qm", "Duplicate key")
        assertIssue("contract", "invalidProfile") { _ = try plan(item) }
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
