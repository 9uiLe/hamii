import Foundation
import XCTest
import HamiiApplication
import HamiiCore
@testable import HamiiFormat

final class AuthoringPolicyCanonicalTests: XCTestCase {
    private let screenID = EntityID("screen_policy")
    private let stackID = EntityID("layer_stack")

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("hamii-policy-canonical-\(UUID().uuidString)")
    }

    private func tokenlessProject(at root: URL) throws -> (CanonicalRepository, ProjectObservation) {
        let repository = CanonicalRepository(root: root)
        _ = try repository.create(name: "Policy")
        let initial = try repository.observe()
        var document = initial.document
        let stack = Layer(id: stackID, kind: .stack, name: "Root",
            layout: Layout(axis: .vertical))
        document.screens = [Screen(id: screenID, name: "Screen", scopeID: document.scopes[0].id,
            root: stack)]
        document.authoringHarness.requireTokenSpacing = false
        document.revision += 1
        return (repository, try repository.commit(document, expected: initial))
    }

    private func canonicalBytes(at root: URL) throws -> [String: Data] {
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw NSError(domain: "PolicyCanonicalTest", code: 1)
        }
        var result: [String: Data] = [:]
        for case let file as URL in enumerator where file.pathExtension == "json" {
            let relative = String(file.path.dropFirst(root.path.count + 1))
            if relative == ".hamii" || relative.hasPrefix(".hamii/") { continue }
            result[relative] = try Data(contentsOf: file)
        }
        return result
    }

    private func assertSpacingViolation(_ error: Error,
                                        file: StaticString = #filePath, line: UInt = #line) {
        guard case CanonicalError.invalid(let diagnostics) = error else {
            return XCTFail("Expected invalid Canonical document, got \(error)", file: file, line: line)
        }
        XCTAssertTrue(diagnostics.contains {
            $0.rule == "token.spacingRequired" && $0.entityID == stackID && $0.severity == .error
        }, file: file, line: line)
    }

    func testStricterPolicyCannotPersistExistingViolationAndPreservesCanonicalBytes() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (repository, valid) = try tokenlessProject(at: root)
        let beforeBytes = try canonicalBytes(at: root)
        XCTAssertTrue(DocumentValidator.validate(valid.document).isEmpty)
        var strict = valid.document
        strict.authoringHarness.requireTokenSpacing = true
        strict.revision += 1
        XCTAssertThrowsError(try repository.commit(strict, expected: valid)) {
            self.assertSpacingViolation($0)
        }
        XCTAssertEqual(try canonicalBytes(at: root), beforeBytes)
        let after = try repository.observe()
        XCTAssertEqual(after.document.revision, valid.document.revision)
        XCTAssertFalse(after.document.authoringHarness.requireTokenSpacing)
        XCTAssertEqual(after.document, valid.document)
    }

    func testExternalInvalidPolicyManifestFailsOnLoadBeforeMutationWithoutWrites() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (repository, valid) = try tokenlessProject(at: root)
        let manifestURL = root.appendingPathComponent("hamii.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: manifestURL)) as? [String: Any])
        var harness = try XCTUnwrap(manifest["authoringHarness"] as? [String: Any])
        harness["requireTokenSpacing"] = true
        manifest["authoringHarness"] = harness
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: manifestURL)
        let invalidBytes = try canonicalBytes(at: root)

        XCTAssertThrowsError(try repository.observe()) { self.assertSpacingViolation($0) }
        let service = ProjectService(repository: repository)
        XCTAssertThrowsError(try service.mutate(.createPage(name: "Unrelated"),
            expectedState: valid.statePrecondition, author: .human)) {
            self.assertSpacingViolation($0)
        }
        XCTAssertEqual(try canonicalBytes(at: root), invalidBytes)
    }

    func testRemediationAndStricterPolicyCanBeCommittedAsOneValidCandidate() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (repository, valid) = try tokenlessProject(at: root)
        var candidate = valid.document
        let token = EntityID("token_policy_spacing")
        candidate.tokens.append(DesignToken(id: token, name: "Spacing", kind: .spacing,
            ownerScopeID: candidate.scopes[0].id, value: .literal("8")))
        candidate.screens[0].root.layout.spacingTokenID = token
        candidate.authoringHarness.requireTokenSpacing = true
        candidate.revision += 1
        XCTAssertTrue(DocumentValidator.validate(candidate).isEmpty)
        let committed = try repository.commit(candidate, expected: valid)
        XCTAssertTrue(committed.document.authoringHarness.requireTokenSpacing)
        XCTAssertEqual(committed.document.screens[0].root.layout.spacingTokenID, token)
        let reopened = try CanonicalRepository(root: root).observe()
        XCTAssertEqual(reopened.document, candidate)
        XCTAssertTrue(DocumentValidator.validate(reopened.document).isEmpty)
        XCTAssertNoThrow(try ProjectService(repository: repository).mutate(
            .createPage(name: "Unrelated"), expectedState: reopened.statePrecondition, author: .human))
    }
}
