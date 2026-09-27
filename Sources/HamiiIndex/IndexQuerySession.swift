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

enum QueryObservationStep: Hashable {
    case fastLockAcquired
    case slowLockAcquired
    case slowSnapshotAcquired
    case slowAttemptFailed
    case slowRowsRead
    case fastRowsRead
    case retryStarted
}

/// A long-lived Query session. Freshness and SQLite rows are read while one
/// WorktreeCoordinator lock is held. A CLI invocation is a new, cold session.
public final class IndexQuerySession {
    private final class RecoverySeedBox {
        var seed: RecoverySourceSeed?
    }

    private let root: URL
    private let storageRoot: URL?
    private let revisionCalculator: any CanonicalRevisionCalculating
    private let coordinator: WorktreeCoordinator
    private let repository: CanonicalRepository
    private let generations: CanonicalGenerationStore
    private let recovery: IndexRecoveryService
    private let afterFastVerdict: (() -> Void)?
    private let onReadBoundaryAcquired: ((Double) -> Void)?
    private let automaticRecoveryEnabled: Bool
    private let onBeforeRecoveryRetry: (() throws -> Void)?
    private let onObservationStep: ((QueryObservationStep) -> Void)?
    private let observationHandoffEnabled: Bool
    private var witness: VerifiedCurrentWitness?

    public convenience init(projectRoot: URL) {
        self.init(projectRoot: projectRoot, revisionCalculator: GitCanonicalRevisionCalculator(),
                  storageRoot: nil, afterFastVerdict: nil, onReadBoundaryAcquired: nil)
    }

    // A barrier for production-path race regressions. It is never invoked
    // outside the coordinated read boundary.
    init(projectRoot: URL, revisionCalculator: any CanonicalRevisionCalculating,
         storageRoot: URL? = nil, afterFastVerdict: (() -> Void)?,
         onReadBoundaryAcquired: ((Double) -> Void)? = nil,
         automaticRecoveryEnabled: Bool = true,
         onRecoveryStep: ((IndexRecoveryStep) throws -> Void)? = nil,
         onBeforeRecoveryRetry: (() throws -> Void)? = nil,
         onObservationStep: ((QueryObservationStep) -> Void)? = nil,
         observationHandoffEnabled: Bool = false) {
        root = projectRoot.standardizedFileURL
        self.storageRoot = storageRoot
        self.revisionCalculator = revisionCalculator
        coordinator = WorktreeCoordinator(root: root)
        repository = CanonicalRepository(root: root)
        generations = CanonicalGenerationStore(root: root)
        recovery = IndexRecoveryService(projectRoot: root, revisionCalculator: revisionCalculator,
                                        storageRoot: storageRoot, hook: onRecoveryStep)
        self.afterFastVerdict = afterFastVerdict
        self.onReadBoundaryAcquired = onReadBoundaryAcquired
        self.automaticRecoveryEnabled = automaticRecoveryEnabled
        self.onBeforeRecoveryRetry = onBeforeRecoveryRetry
        self.onObservationStep = onObservationStep
        self.observationHandoffEnabled = observationHandoffEnabled
    }

    public func components(matching text: String, consumerScopeID: EntityID) throws -> [ComponentHit] {
        try componentsWithVerification(matching: text, consumerScopeID: consumerScopeID).hits
    }

    // Tests distinguish the real slow and fast paths without making a query
    // implementation detail part of the public automation contract.
    func componentsWithVerification(matching text: String, consumerScopeID: EntityID)
        throws -> (hits: [ComponentHit], path: QueryVerificationPath) {
        let seedBox = RecoverySeedBox()
        do {
            return try queryAttempt(matching: text, consumerScopeID: consumerScopeID,
                                    seedBox: seedBox)
        } catch let failure as IndexError {
            guard automaticRecoveryEnabled else { throw failure }
            if case .unverifiableSource = failure { throw failure }
            let result = try recovery.recoverOnce(using: seedBox.seed)
            switch result.outcome {
            case .published, .reused:
                if observationHandoffEnabled, let proof = result.proof {
                    witness = VerifiedCurrentWitness(worktreePath: proof.worktreePath,
                        documentID: proof.documentID, indexPath: proof.indexPath,
                        canonicalGeneration: proof.canonicalGeneration,
                        snapshotIdentity: proof.snapshotIdentity,
                        indexGenerationID: proof.indexGenerationID)
                } else {
                    witness = nil
                }
                try onBeforeRecoveryRetry?()
                onObservationStep?(.retryStarted)
                // One recovery and exactly one retry. This direct call cannot
                // recursively reset the recovery budget.
                return try queryAttempt(matching: text, consumerScopeID: consumerScopeID,
                                        seedBox: RecoverySeedBox())
            case .notEligible:
                throw failure
            }
        }
    }

    private func queryAttempt(matching text: String, consumerScopeID: EntityID,
                              seedBox: RecoverySeedBox)
        throws -> (hits: [ComponentHit], path: QueryVerificationPath) {
        let lockAttempt = onReadBoundaryAcquired.map { _ in ProcessInfo.processInfo.systemUptime }
        let fast = try coordinator.withReadyExclusive { () -> FastResult in
            onObservationStep?(.fastLockAcquired)
            if let lockAttempt {
                onReadBoundaryAcquired?((ProcessInfo.processInfo.systemUptime - lockAttempt) * 1_000)
            }
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
            onObservationStep?(.fastRowsRead)
            return .rows(hits)
        }
        switch fast {
        case .rows(let hits): return (hits, .fast)
        case .stale: throw IndexError.stale
        case .unknown: return try slowComponents(matching: text, consumerScopeID: consumerScopeID,
                                                 seedBox: seedBox)
        }
    }

    private func slowComponents(matching text: String, consumerScopeID: EntityID,
                                seedBox: RecoverySeedBox)
        throws -> (hits: [ComponentHit], path: QueryVerificationPath) {
        try repository.withStableRecordSnapshotForQuery(
            onLockAcquired: { self.onObservationStep?(.slowLockAcquired) }
        ) { snapshot, stable in
            onObservationStep?(.slowSnapshotAcquired)
            do {
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
                guard stable.snapshotIdentity == snapshot.identity,
                      source == stable.generation else { throw IndexError.stale }
                boundGeneration = source
            case .explicitlyUnbound:
                boundGeneration = nil
            }
            // Existing Git oracle and its post-row guard remain the cold path.
            let hits = try index.components(matching: text, consumerScopeID: consumerScopeID,
                                            documentID: snapshot.document.id,
                                            revision: snapshot.document.revision,
                                            expectedSourceIdentity: snapshot.identity)
            onObservationStep?(.slowRowsRead)
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
            } catch let failure as IndexError {
                if observationHandoffEnabled {
                    seedBox.seed = try? recovery.seedFromObserved(snapshot: snapshot, stable: stable)
                }
                onObservationStep?(.slowAttemptFailed)
                throw failure
            }
        }
    }

    private func makeIndex(documentID: EntityID) throws -> LocalIndex {
        try LocalIndex.openExisting(projectRoot: root, documentID: documentID,
                                    revisionCalculator: revisionCalculator, storageRoot: storageRoot)
    }

    private enum FastResult {
        case rows([ComponentHit])
        case stale
        case unknown
    }
}
