import Darwin
import Foundation
import HamiiCore
import HamiiFormat

/// Full rebuild path for validated merge publication. The source gate remains
/// pending until a separately built database replaces the published one and
/// its Canonical revision has been checked again.
enum MergeIndexStep { case beforeBuild, duringTransaction, built, beforePublish, published }

public struct PublishedMergeIndex: MergeIndexPublishing {
    private let hook: ((MergeIndexStep) -> Void)?
    public init() { hook = nil }
    init(hook: @escaping (MergeIndexStep) -> Void) { self.hook = hook }

    public func validateCandidate(at root: URL, document: Document) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("hamii-candidate-index-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try build(at: root, document: document, storageRoot: temporary, isPublication: false)
    }

    public func rebuildPublished(at root: URL, document: Document) throws {
        let destination = LocalIndexLocation.url(projectRoot: root, documentID: document.id)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".hamii-index-build-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        hook?(.beforeBuild)
        let generated = try build(at: root, document: document, storageRoot: temporary, isPublication: true)
        hook?(.built)
        // SQLite's journal files belong to the previous disposable generation.
        // The source worktree gate excludes coordinated query connections here.
        for suffix in ["-journal", "-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: destination.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) { try FileManager.default.removeItem(at: sidecar) }
        }
        hook?(.beforePublish)
        guard rename(generated.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        hook?(.published)
        try verifyPublished(at: root, document: document)
    }

    public func verifyPublished(at root: URL, document: Document) throws {
        let calculator = GitCanonicalRevisionCalculator()
        let index = try LocalIndex(projectRoot: root, documentID: document.id, revisionCalculator: calculator)
        try index.assertCurrent(documentID: document.id, revision: document.revision)
    }

    @discardableResult
    private func build(at root: URL, document: Document, storageRoot: URL, isPublication: Bool) throws -> URL {
        let calculator = GitCanonicalRevisionCalculator()
        let source = try calculator.current(at: root)
        let generated: URL
        do {
            let index = try LocalIndex(projectRoot: root, documentID: document.id,
                                       revisionCalculator: calculator, storageRoot: storageRoot)
            try index.rebuild(from: document, canonicalRevision: source, transactionHook: isPublication ? {
                hook?(.duringTransaction)
            } : nil)
            try index.assertCurrent(documentID: document.id, revision: document.revision)
            generated = index.url
        }
        guard try calculator.current(at: root) == source else { throw IndexError.stale }
        return generated
    }
}
