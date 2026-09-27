import Darwin
import Foundation
import HamiiCore
import HamiiFormat

enum IndexRecoveryStep: Hashable {
    case phase1LockAcquired
    case phase1Complete
    case sourceCaptured
    case candidateCreated
    case candidateWriting
    case candidateBuilt
    case candidateValidated
    case phase2LockAcquired
    case beforePublish
    case published
    case phase2Complete
}

enum RecoveryEligibility: Equatable {
    case alreadyCurrent
    case autoRecoverable(String)
    case manualOnly(String)
    case blocked(String)
}

enum IndexRecoveryOutcome: Equatable {
    case published(IndexGenerationID)
    case reused(IndexGenerationID)
    case notEligible
}

/// Bounded full rebuild from one strict coordinated source observation. The
/// Canonical generation is never created or repaired here. The caller owns
/// one Query retry after a published or reused complete generation.
final class IndexRecoveryService {
    private struct Source {
        let snapshot: CanonicalSnapshot
        let stable: StableCanonicalGeneration
        let revision: CanonicalRevision
        let expected: PublishedIndexState
    }

    private struct Candidate {
        let root: URL
        let url: URL
        let descriptor: IndexGenerationDescriptor
    }

    private let root: URL
    private let storageRoot: URL?
    private let repository: CanonicalRepository
    private let calculator: any CanonicalRevisionCalculating
    private let probe = PublishedIndexProbe()
    private let hook: ((IndexRecoveryStep) throws -> Void)?

    init(projectRoot: URL, revisionCalculator: any CanonicalRevisionCalculating,
         storageRoot: URL?, hook: ((IndexRecoveryStep) throws -> Void)? = nil) {
        root = projectRoot.standardizedFileURL
        self.storageRoot = storageRoot
        repository = CanonicalRepository(root: root)
        calculator = revisionCalculator
        self.hook = hook
    }

    func recoverOnce() throws -> IndexRecoveryOutcome {
        let source: Source
        do {
            guard let captured = try captureEligibleSource() else { return .notEligible }
            source = captured
        } catch CanonicalGenerationError.missing,
                CanonicalGenerationError.pending,
                CanonicalGenerationError.corrupt,
                CanonicalGenerationError.unknownState,
                CanonicalError.managedGitPending,
                CanonicalError.transactionConflict,
                CanonicalError.transactionCorrupt,
                IndexError.unverifiableSource,
                IndexError.stale {
            return .notEligible
        }
        try hook?(.sourceCaptured)
        let candidate = try buildCandidate(from: source)
        defer { try? FileManager.default.removeItem(at: candidate.root) }
        return try publishOrReuse(candidate, from: source)
    }

    private func captureEligibleSource() throws -> Source? {
        try repository.withStableSnapshotForDerivedRecovery(
            onLockAcquired: { try self.hook?(.phase1LockAcquired) }
        ) { snapshot, stable in
            let revision = try calculator.current(at: root)
            let published = try probe.inspect(at: destination(for: snapshot.document.id))
            switch eligibility(published, snapshot: snapshot, stable: stable, revision: revision) {
            case .autoRecoverable:
                try hook?(.phase1Complete)
                return Source(snapshot: snapshot, stable: stable, revision: revision,
                              expected: published.state)
            case .alreadyCurrent, .manualOnly, .blocked:
                return nil
            }
        }
    }

    func eligibility(_ published: PublishedIndexObservation, snapshot: CanonicalSnapshot,
                     stable: StableCanonicalGeneration,
                     revision: CanonicalRevision) -> RecoveryEligibility {
        switch published.assessment {
        case .missing: return .autoRecoverable("missingIndex")
        case .obsolete: return .autoRecoverable("obsoleteSchema")
        case .malformed: return .autoRecoverable("malformedMetadata")
        case .corrupt: return .autoRecoverable("corruptSQLite")
        case .valid(let descriptor, let sourceRevision):
            let matches = descriptor.documentID == snapshot.document.id &&
                descriptor.documentRevision == snapshot.document.revision &&
                descriptor.sourceCanonicalIdentity == snapshot.identity &&
                sourceRevision == revision
            switch descriptor.sourceGenerationBinding {
            case .bound(let generation):
                return matches && generation == stable.generation
                    ? .alreadyCurrent : .autoRecoverable("staleBoundIndex")
            case .explicitlyUnbound:
                return matches ? .alreadyCurrent : .manualOnly("unboundSourceChanged")
            }
        }
    }

    private func buildCandidate(from source: Source) throws -> Candidate {
        let destination = destination(for: source.snapshot.document.id)
        let parent = destination.deletingLastPathComponent()
        do { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
        catch { throw IndexError.sqlite("Cannot create Index candidate directory: \(error)") }
        let candidateRoot = parent.appendingPathComponent(".hamii-index-recovery-\(UUID().uuidString)",
                                                          isDirectory: true)
        do {
            try hook?(.candidateCreated)
            let candidateURL: URL
            let descriptor: IndexGenerationDescriptor
            do {
                let index: LocalIndex
                do {
                    index = try LocalIndex(projectRoot: root, documentID: source.snapshot.document.id,
                        revisionCalculator: calculator, storageRoot: candidateRoot)
                } catch let error as IndexError {
                    throw error
                } catch {
                    throw IndexError.sqlite("Cannot create Index candidate: \(error)")
                }
                descriptor = try index.rebuild(from: source.snapshot, canonicalRevision: source.revision,
                    sourceGenerationBinding: .bound(source.stable.generation),
                    transactionHook: { try self.hook?(.candidateWriting) })
                candidateURL = index.url
            }
            try hook?(.candidateBuilt)
            let verified = try probe.inspect(at: candidateURL)
            guard case .valid(let actual, let revision) = verified.assessment,
                  actual == descriptor, revision == source.revision else {
                throw IndexError.stale
            }
            try hook?(.candidateValidated)
            return Candidate(root: candidateRoot, url: candidateURL, descriptor: descriptor)
        } catch {
            try? FileManager.default.removeItem(at: candidateRoot)
            throw error
        }
    }

    private func publishOrReuse(_ candidate: Candidate, from source: Source) throws -> IndexRecoveryOutcome {
        try repository.withStableGenerationForDerivedRecovery(
            onLockAcquired: { try self.hook?(.phase2LockAcquired) }
        ) { stable in
            guard stable == source.stable,
                  try calculator.current(at: root) == source.revision else { throw IndexError.stale }
            let destination = destination(for: source.snapshot.document.id)
            let current = try probe.inspect(at: destination)
            if case .valid(let descriptor, let revision) = current.assessment,
               descriptor.documentID == source.snapshot.document.id,
               descriptor.documentRevision == source.snapshot.document.revision,
               descriptor.sourceCanonicalIdentity == source.snapshot.identity,
               descriptor.sourceGenerationBinding == .bound(source.stable.generation),
               revision == source.revision {
                try hook?(.phase2Complete)
                return .reused(descriptor.id)
            }
            guard current.state == source.expected else { throw IndexError.stale }
            try hook?(.beforePublish)
            // A prior disposable generation may have SQLite sidecars. The
            // coordinated boundary excludes every participating reader.
            for suffix in ["-journal", "-wal", "-shm"] {
                let sidecar = URL(fileURLWithPath: destination.path + suffix)
                if FileManager.default.fileExists(atPath: sidecar.path) {
                    do { try FileManager.default.removeItem(at: sidecar) }
                    catch { throw IndexError.sqlite("Cannot remove disposable Index sidecar: \(error)") }
                }
            }
            guard rename(candidate.url.path, destination.path) == 0 else {
                throw IndexError.sqlite("Cannot publish Index generation: POSIX code \(errno)")
            }
            try hook?(.published)
            let published = try probe.inspect(at: destination)
            guard case .valid(let actual, let revision) = published.assessment,
                  actual == candidate.descriptor, revision == source.revision else {
                throw IndexError.stale
            }
            try hook?(.phase2Complete)
            return .published(actual.id)
        }
    }

    private func destination(for documentID: EntityID) -> URL {
        LocalIndexLocation.url(projectRoot: root, documentID: documentID, storageRoot: storageRoot)
    }
}
