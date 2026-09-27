import Foundation
import HamiiCore
import HamiiFormat

/// Process-local evidence that one published Index was verified against one
/// coordinated Canonical observation. It is never persisted or shared across
/// worktrees, Documents, or Index namespaces.
private struct VerifiedCurrentWitness {
    let worktreePath: String
    let documentID: EntityID
    let indexPath: String
    let canonicalGeneration: CanonicalGeneration
    let snapshotIdentity: CanonicalSnapshotIdentity
    let indexGenerationID: IndexGenerationID
}

enum QueryVerificationPath: Equatable { case slowBound, slowUnbound, fast }

/// A long-lived Query session. Freshness and SQLite rows are read while one
/// WorktreeCoordinator lock is held. A CLI invocation is a new, cold session.
public final class IndexQuerySession {
    private let root: URL
    private let storageRoot: URL?
    private let revisionCalculator: any CanonicalRevisionCalculating
    private let coordinator: WorktreeCoordinator
    private let repository: CanonicalRepository
    private let generations: CanonicalGenerationStore
    private let afterFastVerdict: (() -> Void)?
    private var witness: VerifiedCurrentWitness?

    public convenience init(projectRoot: URL) {
        self.init(projectRoot: projectRoot, revisionCalculator: GitCanonicalRevisionCalculator(),
                  storageRoot: nil, afterFastVerdict: nil)
    }

    // A barrier for production-path race regressions. It is never invoked
    // outside the coordinated read boundary.
    init(projectRoot: URL, revisionCalculator: any CanonicalRevisionCalculating,
         storageRoot: URL? = nil, afterFastVerdict: (() -> Void)?) {
        root = projectRoot.standardizedFileURL
        self.storageRoot = storageRoot
        self.revisionCalculator = revisionCalculator
        coordinator = WorktreeCoordinator(root: root)
        repository = CanonicalRepository(root: root)
        generations = CanonicalGenerationStore(root: root)
        self.afterFastVerdict = afterFastVerdict
    }

    public func components(matching text: String, consumerScopeID: EntityID) throws -> [ComponentHit] {
        try componentsWithVerification(matching: text, consumerScopeID: consumerScopeID).hits
    }

    // Tests distinguish the real slow and fast paths without making a query
    // implementation detail part of the public automation contract.
    func componentsWithVerification(matching text: String, consumerScopeID: EntityID)
        throws -> (hits: [ComponentHit], path: QueryVerificationPath) {
        let fast = try coordinator.withReadyExclusive { () -> FastResult in
            guard let witness else { return .unknown }
            let stable: StableCanonicalGeneration
            do { stable = try generations.readStable() }
            catch { self.witness = nil; throw IndexError.stale }
            guard witness.worktreePath == root.resolvingSymlinksInPath().path else {
                self.witness = nil
                return .stale
            }
            let index = try makeIndex(documentID: witness.documentID)
            let published: IndexGenerationDescriptor
            do { published = try index.publishedGeneration() }
            catch { self.witness = nil; throw IndexError.stale }
            guard index.url.path == witness.indexPath, published.documentID == witness.documentID else {
                self.witness = nil
                return .stale
            }
            if published.sourceGenerationBinding == .explicitlyUnbound {
                self.witness = nil
                return .unknown
            }
            guard published.sourceGenerationBinding == .bound(stable.generation),
                  published.sourceCanonicalIdentity == stable.snapshotIdentity else {
                self.witness = nil
                return .stale
            }
            guard stable.generation == witness.canonicalGeneration,
                  stable.snapshotIdentity == witness.snapshotIdentity,
                  published.id == witness.indexGenerationID else {
                self.witness = nil
                return .unknown
            }
            afterFastVerdict?()
            let hits = try index.components(matching: text, consumerScopeID: consumerScopeID,
                                            verifiedGeneration: published)
            return .rows(hits)
        }
        switch fast {
        case .rows(let hits): return (hits, .fast)
        case .stale: throw IndexError.stale
        case .unknown: return try slowComponents(matching: text, consumerScopeID: consumerScopeID)
        }
    }

    private func slowComponents(matching text: String, consumerScopeID: EntityID)
        throws -> (hits: [ComponentHit], path: QueryVerificationPath) {
        try repository.withCoordinatedSnapshot { snapshot in
            let index = try makeIndex(documentID: snapshot.document.id)
            let published = try index.publishedGeneration()
            guard published.documentID == snapshot.document.id,
                  published.documentRevision == snapshot.document.revision else {
                throw IndexError.stale
            }
            if published.sourceCanonicalIdentity != snapshot.identity {
                // Retain the Git flag/filter diagnostic of the slow oracle.
                _ = try revisionCalculator.current(at: root)
                throw IndexError.stale
            }
            let boundGeneration: CanonicalGeneration?
            switch published.sourceGenerationBinding {
            case .bound(let source):
                let stable = try generations.requireMatchingStable(snapshot)
                guard source == stable.generation else { throw IndexError.stale }
                boundGeneration = source
            case .explicitlyUnbound:
                boundGeneration = nil
            }
            // Existing Git oracle and its post-row guard remain the cold path.
            let hits = try index.components(matching: text, consumerScopeID: consumerScopeID,
                                            documentID: snapshot.document.id,
                                            revision: snapshot.document.revision,
                                            expectedSourceIdentity: snapshot.identity)
            guard try index.publishedGeneration() == published else { throw IndexError.stale }
            if let boundGeneration {
                witness = VerifiedCurrentWitness(
                    worktreePath: root.resolvingSymlinksInPath().path,
                    documentID: snapshot.document.id,
                    indexPath: index.url.path,
                    canonicalGeneration: boundGeneration,
                    snapshotIdentity: snapshot.identity,
                    indexGenerationID: published.id)
                return (hits, .slowBound)
            }
            witness = nil
            return (hits, .slowUnbound)
        }
    }

    private func makeIndex(documentID: EntityID) throws -> LocalIndex {
        try LocalIndex(projectRoot: root, documentID: documentID,
                       revisionCalculator: revisionCalculator, storageRoot: storageRoot)
    }

    private enum FastResult {
        case rows([ComponentHit])
        case stale
        case unknown
    }
}
