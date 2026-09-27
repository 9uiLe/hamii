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

    public func validateCandidate(at root: URL, snapshot: CanonicalSnapshot) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("hamii-candidate-index-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        _ = try build(at: root, snapshot: snapshot, storageRoot: temporary, isPublication: false)
    }

    public func rebuildPublished(at root: URL, snapshot: CanonicalSnapshot) throws -> IndexGenerationDescriptor {
        let destination = LocalIndexLocation.url(projectRoot: root, documentID: snapshot.document.id)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".hamii-index-build-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        hook?(.beforeBuild)
        let generated = try build(at: root, snapshot: snapshot, storageRoot: temporary, isPublication: true)
        hook?(.built)
        // SQLite's journal files belong to the previous disposable generation.
        // The source worktree gate excludes coordinated query connections here.
        for suffix in ["-journal", "-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: destination.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) { try FileManager.default.removeItem(at: sidecar) }
        }
        hook?(.beforePublish)
        guard rename(generated.url.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        hook?(.published)
        let published = try verifyPublished(at: root, snapshot: snapshot)
        guard published == generated.generation else { throw IndexError.stale }
        return published
    }

    public func verifyPublished(at root: URL, snapshot: CanonicalSnapshot) throws -> IndexGenerationDescriptor {
        let calculator = GitCanonicalRevisionCalculator()
        let index = try LocalIndex(projectRoot: root, documentID: snapshot.document.id, revisionCalculator: calculator)
        return try index.assertCurrent(documentID: snapshot.document.id, revision: snapshot.document.revision,
                                       expectedSourceIdentity: snapshot.identity)
    }

    private func build(at root: URL, snapshot: CanonicalSnapshot, storageRoot: URL,
                       isPublication: Bool) throws -> (url: URL, generation: IndexGenerationDescriptor) {
        let calculator = GitCanonicalRevisionCalculator()
        let source = try calculator.current(at: root)
        let sourceBinding: IndexSourceGenerationBinding
        if let generation = try? CanonicalGenerationStore(root: root).requireMatchingStable(snapshot).generation {
            sourceBinding = .bound(generation)
        } else {
            sourceBinding = .explicitlyUnbound
        }
        let generated: URL
        let generation: IndexGenerationDescriptor
        do {
            let index = try LocalIndex(projectRoot: root, documentID: snapshot.document.id,
                                       revisionCalculator: calculator, storageRoot: storageRoot)
            generation = try index.rebuild(from: snapshot, canonicalRevision: source,
                                           sourceGenerationBinding: sourceBinding, transactionHook: isPublication ? {
                hook?(.duringTransaction)
            } : nil)
            let verified = try index.assertCurrent(documentID: snapshot.document.id,
                revision: snapshot.document.revision, expectedSourceIdentity: snapshot.identity)
            guard verified == generation else { throw IndexError.stale }
            generated = index.url
        }
        guard try calculator.current(at: root) == source else { throw IndexError.stale }
        return (generated, generation)
    }
}
