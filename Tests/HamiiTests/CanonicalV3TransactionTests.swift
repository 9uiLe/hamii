import Foundation
import XCTest
import HamiiCore
@testable import HamiiFormat

final class CanonicalV3TransactionTests: XCTestCase {
    private enum Stop: Error { case requested }

    private func document(name: String) -> Document {
        var result = Document(name: name)
        result.id = EntityID("document_journal_v3")
        result.scopes = [ArchitectureScope(id: EntityID("scope_app"), name: "App", parentID: nil)]
        result.versions.document = 3
        var text = Layer(id: EntityID("layer_title"), kind: .text, name: "Title", text: "Preview")
        text.textBinding = "profile.title"
        var screen = Screen(id: EntityID("screen_main"), name: "Main",
                            scopeID: EntityID("scope_app"), root: text)
        screen.semantics = ScreenSemantics(
            sources: [SemanticSource(key: SemanticSourceKey("profile.title"), valueKind: .text)],
            outputs: [SemanticOutput(key: SemanticOutputKey("title"),
                anchor: .direct(layerID: text.id, property: .text), binding: "profile.title")],
            relations: [SemanticRelation(output: SemanticOutputKey("title"),
                source: SemanticSourceKey("profile.title"), whenNil: .literal("Untitled"))])
        result.screens = [screen]
        return result
    }

    private func install(_ files: [String: Data], at root: URL) throws {
        for (path, bytes) in files {
            let destination = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try bytes.write(to: destination)
        }
    }

    private func read(_ paths: Set<String>, at root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for path in paths {
            let destination = root.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: destination.path) {
                result[path] = try Data(contentsOf: destination)
            }
        }
        return result
    }

    private func token(for files: [String: Data], at root: URL) throws -> ClientPrecondition {
        try CanonicalRepository(root: root).clientPreconditionForCanonicalPaths(
            files.keys.sorted().map { root.appendingPathComponent($0) })
    }

    func testV3ScreenJournalRecoveryPreservesExactOldOrNewCanonicalSet() throws {
        let old = document(name: "Before")
        var new = old
        new.revision = 1
        new.name = "After"
        new.screens[0].root.text = "Changed"
        var updatedSemantics = try XCTUnwrap(new.screens[0].semantics)
        updatedSemantics.relations[0].whenNil = .literal("Missing title")
        new.screens[0].semantics = updatedSemantics
        let oldFiles = try CanonicalDocumentV3Codec.encode(document: old)
        let newFiles = try CanonicalDocumentV3Codec.encode(document: new)
        XCTAssertNotEqual(CanonicalByteIdentity.compute(files: oldFiles),
                          CanonicalByteIdentity.compute(files: newFiles))
        XCTAssertEqual(try CanonicalDocumentV3Codec.decode(files: oldFiles), old)
        XCTAssertEqual(try CanonicalDocumentV3Codec.decode(files: newFiles), new)

        let stops: [(String, (TransactionStep) -> Bool, Bool)] = [
            ("prepared", { if case .prepared = $0 { return true }; return false }, false),
            ("ready", { if case .ready = $0 { return true }; return false }, false),
            ("screenApplied", { if case .applied("screens/screen_main.json") = $0 { return true }; return false }, false),
            ("manifestApplied", { if case .applied("hamii.json") = $0 { return true }; return false }, true),
            ("complete", { if case .complete = $0 { return true }; return false }, true)
        ]
        for (name, shouldStop, committed) in stops {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("hamii-v3-journal-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try install(oldFiles, at: root)
            try FileManager.default.createDirectory(at: root.appendingPathComponent(".hamii", isDirectory: true),
                                                    withIntermediateDirectories: true)
            let previousToken = try token(for: oldFiles, at: root)
            let coordinator = WorktreeCoordinator(root: root)
            try coordinator.withExclusive { try coordinator.invalidateClientObservations() }
            let transaction = CanonicalTransaction(root: root) { step in
                if shouldStop(step) { throw Stop.requested }
            }
            XCTAssertThrowsError(try transaction.commit(newFiles: newFiles, expectedOldFiles: oldFiles,
                                                        oldRevision: old.revision, newRevision: new.revision), name)
            let ready = root.appendingPathComponent(".hamii/transaction.ready")
            XCTAssertEqual(FileManager.default.fileExists(atPath: ready.path),
                           name == "ready" || name == "screenApplied" || name == "manifestApplied", name)

            try CanonicalTransaction(root: root).recoverIfNeeded()
            try CanonicalTransaction(root: root).recoverIfNeeded() // recovery is idempotent
            let expected = committed ? newFiles : oldFiles
            let actual = try read(Set(oldFiles.keys).union(newFiles.keys), at: root)
            XCTAssertEqual(actual, expected, name)
            XCTAssertEqual(CanonicalByteIdentity.compute(files: actual),
                           CanonicalByteIdentity.compute(files: expected), name)
            let decoded = try CanonicalDocumentV3Codec.decode(files: actual)
            XCTAssertEqual(decoded, committed ? new : old, name)
            XCTAssertFalse(DocumentValidator.validate(decoded).contains { $0.severity == .error }, name)
            XCTAssertNotEqual(try token(for: actual, at: root), previousToken,
                              "The interrupted transition must not revive an earlier client observation: \(name)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: ready.path), name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".hamii/transaction.complete").path), name)
        }
    }
}
