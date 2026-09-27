import Darwin
import Foundation
import HamiiApplication
import HamiiCore

public enum MergePublicationError: Error, CustomStringConvertible {
    case invalidRecord
    case unknownSourceState
    case candidateUnavailable
    case candidateMismatch
    case gitLockOwnershipUnknown(String)

    public var description: String {
        switch self {
        case .invalidRecord: return "Merge publication record is invalid; the worktree remains gated"
        case .unknownSourceState: return "Source ref is neither the expected old nor validated candidate OID"
        case .candidateUnavailable: return "Validated candidate commit is not retained"
        case .candidateMismatch: return "Materialized Canonical data differs from the validated candidate"
        case .gitLockOwnershipUnknown(let path):
            return "Git lock ownership is unknown at \(path); publication remains pending until the owner is verified and the lock is removed"
        }
    }
}

enum MergePublicationStep: Equatable {
    case pending, beforeRefCAS, afterRefCAS, beforeMaterialization, materialized
    case beforeCanonicalValidation, duringCanonicalValidation, canonicalVerified
    case beforeIndexBuild, indexBuilt, beforeGateRelease, gateReleased
}

private enum PublicationPhase: String, Codable {
    case pending, refPublished, worktreeMaterialized, canonicalVerified, indexPublished
}

private struct MergePublicationRecord: Codable {
    let formatVersion: Int
    let publicationID: UUID
    let sourceRef: String
    let expectedSourceOID: String
    let sourceCanonicalIdentity: String
    let targetOID: String
    let candidateOID: String
    let retentionRef: String
    let candidateWorktreePath: String
    let candidateCanonicalIdentity: String
    let validatedIndexSourceIdentity: String
    let documentID: String
    var phase: PublicationPhase
}

/// Orchestrates an immutable Git candidate, Canonical validation and a derived
/// Index behind the shared worktree gate. Git ref CAS is the commit point;
/// recovery never rolls Canonical data back to compensate for Index failure.
public final class ValidatedMergePublisher {
    public let root: URL
    private let coordinator: WorktreeCoordinator
    private let repository: CanonicalRepository
    private let index: any MergeIndexPublishing
    private let hook: ((MergePublicationStep) throws -> Void)?

    public init(root: URL, index: any MergeIndexPublishing) {
        self.root = root.standardizedFileURL
        coordinator = WorktreeCoordinator(root: self.root)
        repository = CanonicalRepository(root: self.root)
        self.index = index
        hook = nil
    }

    init(root: URL, index: any MergeIndexPublishing, hook: @escaping (MergePublicationStep) throws -> Void) {
        self.root = root.standardizedFileURL
        coordinator = WorktreeCoordinator(root: self.root)
        repository = CanonicalRepository(root: self.root)
        self.index = index
        self.hook = hook
    }

    public var hasPendingPublication: Bool { coordinator.mergePublicationPending() }

    public func publish(_ targetBranch: String, expectedState: ClientPrecondition) throws -> ProjectObservation {
        let source = try coordinator.withExclusive { () throws -> (ref: String, oid: String, identity: String, documentID: String, target: String) in
            try coordinator.requireReady()
            try requireWorktreeRoot()
            let observed = try repository.observeDuringManagedGitTransition()
            guard observed.statePrecondition == expectedState else { throw AuthoringError.staleState }
            try requireCleanWorktree()
            guard (try? git("check-ref-format", "--branch", targetBranch)) != nil,
                  let target = try? git("rev-parse", "--verify", "refs/heads/\(targetBranch)^{commit}") else {
                throw ManagedGitError.invalidBranch(targetBranch)
            }
            let snapshot = try repository.snapshotDuringManagedGitTransition()
            return (try git("symbolic-ref", "--quiet", "HEAD"), try git("rev-parse", "HEAD"),
                    snapshot.identity, snapshot.document.id.rawValue, target)
        }

        let publicationID = UUID()
        let retentionRef = "refs/hamii/merge-candidates/\(publicationID.uuidString.lowercased())"
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("hamii-merge-publish-\(publicationID.uuidString)", isDirectory: true)
        let candidateRoot = container.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        var added = false
        var retained = false
        var pending = false
        defer {
            if added { _ = try? git("worktree", "remove", "--force", candidateRoot.path) }
            try? FileManager.default.removeItem(at: container)
            if retained && !pending { _ = try? git("update-ref", "-d", retentionRef) }
        }
        _ = try git("worktree", "add", "--detach", candidateRoot.path, source.oid)
        added = true
        _ = try GitCommand.run(at: candidateRoot, ["merge", "--no-ff", "--no-edit", source.target])
        let candidateOID = try GitCommand.run(at: candidateRoot, ["rev-parse", "HEAD"])
        let candidateCoordinator = WorktreeCoordinator(root: candidateRoot)
        let candidate = try candidateCoordinator.withExclusive {
            try CanonicalRepository(root: candidateRoot).snapshotDuringManagedGitTransition()
        }
        guard candidate.document.id.rawValue == source.documentID else { throw MergePublicationError.candidateMismatch }
        try index.validateCandidate(at: candidateRoot, document: candidate.document)
        _ = try git("update-ref", retentionRef, candidateOID)
        retained = true

        let initial = MergePublicationRecord(formatVersion: 1, publicationID: publicationID, sourceRef: source.ref,
            expectedSourceOID: source.oid, sourceCanonicalIdentity: source.identity,
            targetOID: source.target, candidateOID: candidateOID, retentionRef: retentionRef,
            candidateWorktreePath: candidateRoot.path,
            candidateCanonicalIdentity: candidate.identity, validatedIndexSourceIdentity: candidate.identity,
            documentID: source.documentID, phase: .pending)

        let result = try coordinator.withExclusive { () throws -> ProjectObservation in
            try coordinator.requireReady()
            try requireWorktreeRoot()
            guard try git("symbolic-ref", "--quiet", "HEAD") == source.ref,
                  try git("rev-parse", "HEAD") == source.oid,
                  try git("rev-parse", "--verify", "refs/heads/\(targetBranch)^{commit}") == source.target,
                  try repository.observeDuringManagedGitTransition().statePrecondition == expectedState else {
                throw ManagedGitError.changedDuringTransition
            }
            try requireCleanWorktree()
            try coordinator.beginMergePublication(try JSONEncoder().encode(initial))
            pending = true
            try hook?(.pending)
            let observed = try publishPending(initial)
            cleanupCandidate(initial)
            return observed
        }
        return result
    }

    public func recover() throws -> ProjectObservation {
        try coordinator.withExclusive {
            try requireWorktreeRoot()
            guard let bytes = try coordinator.mergePublicationRecord() else {
                try coordinator.requireReady()
                return try repository.observeDuringManagedGitTransition()
            }
            let record = try decode(bytes)
            guard try git("symbolic-ref", "--quiet", "HEAD") == record.sourceRef else {
                throw MergePublicationError.unknownSourceState
            }
            try requireGitLocksAbsent(record)
            // Recovery itself is a coordinated transition. No old client token
            // may become valid again even if the content returns to old bytes.
            try coordinator.invalidateClientObservations()
            let current = try git("rev-parse", "HEAD")
            if current == record.expectedSourceOID {
                try requireCleanWorktree()
                let snapshot = try repository.snapshotDuringManagedGitTransition()
                guard snapshot.identity == record.sourceCanonicalIdentity else { throw MergePublicationError.unknownSourceState }
                try coordinator.finishMergePublication()
                cleanupCandidate(record)
                return try repository.observeDuringManagedGitTransition()
            }
            guard current == record.candidateOID else { throw MergePublicationError.unknownSourceState }
            let result = try publishPending(record, recovering: true)
            cleanupCandidate(record)
            return result
        }
    }

    private func publishPending(_ initial: MergePublicationRecord, recovering: Bool = false) throws -> ProjectObservation {
        var record = initial
        guard try git("rev-parse", "--verify", "\(record.retentionRef)^{commit}") == record.candidateOID,
              try git("cat-file", "-t", record.candidateOID) == "commit" else {
            throw MergePublicationError.candidateUnavailable
        }
        if !recovering {
            try hook?(.beforeRefCAS)
            _ = try git("update-ref", record.sourceRef, record.candidateOID, record.expectedSourceOID)
            record.phase = .refPublished
            try save(record)
            try hook?(.afterRefCAS)
        }
        try hook?(.beforeMaterialization)
        _ = try git("read-tree", "--reset", "-u", record.candidateOID)
        record.phase = .worktreeMaterialized
        try save(record)
        try hook?(.materialized)
        try requireCleanWorktree()
        try hook?(.beforeCanonicalValidation)
        let snapshot = try repository.snapshotDuringManagedGitTransition {
            try self.hook?(.duringCanonicalValidation)
        }
        guard snapshot.identity == record.candidateCanonicalIdentity,
              snapshot.document.id.rawValue == record.documentID,
              record.validatedIndexSourceIdentity == snapshot.identity else {
            throw MergePublicationError.candidateMismatch
        }
        record.phase = .canonicalVerified
        try save(record)
        try hook?(.canonicalVerified)
        try hook?(.beforeIndexBuild)
        try index.rebuildPublished(at: root, document: snapshot.document)
        try hook?(.indexBuilt)
        let afterIndex = try repository.snapshotDuringManagedGitTransition()
        guard afterIndex.identity == record.candidateCanonicalIdentity else { throw MergePublicationError.candidateMismatch }
        try index.verifyPublished(at: root, document: afterIndex.document)
        record.phase = .indexPublished
        try save(record)
        try hook?(.beforeGateRelease)
        try coordinator.finishMergePublication()
        try hook?(.gateReleased)
        return try repository.observeDuringManagedGitTransition()
    }

    private func save(_ record: MergePublicationRecord) throws {
        try coordinator.writeMergePublicationRecord(JSONEncoder().encode(record))
    }

    private func decode(_ bytes: Data) throws -> MergePublicationRecord {
        guard let record = try? JSONDecoder().decode(MergePublicationRecord.self, from: bytes),
              record.formatVersion == 1,
              record.sourceRef.hasPrefix("refs/heads/"),
              record.retentionRef == "refs/hamii/merge-candidates/\(record.publicationID.uuidString.lowercased())",
              URL(fileURLWithPath: record.candidateWorktreePath).lastPathComponent == "worktree",
              URL(fileURLWithPath: record.candidateWorktreePath).deletingLastPathComponent().lastPathComponent ==
                  "hamii-merge-publish-\(record.publicationID.uuidString)",
              record.candidateCanonicalIdentity == record.validatedIndexSourceIdentity else {
            throw MergePublicationError.invalidRecord
        }
        return record
    }

    private func cleanupCandidate(_ record: MergePublicationRecord) {
        // Cleanup is best effort after Ready. A retained candidate object or
        // temporary worktree costs space but cannot change the published state.
        _ = try? git("worktree", "remove", "--force", record.candidateWorktreePath)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: record.candidateWorktreePath).deletingLastPathComponent())
        _ = try? git("update-ref", "-d", record.retentionRef, record.candidateOID)
    }

    private func requireGitLocksAbsent(_ record: MergePublicationRecord) throws {
        // A pending hamii record does not identify a Git lock's owner. A live
        // raw Git process may have created either path after hamii stopped.
        for path in ["index.lock", "\(record.sourceRef).lock"] {
            let result = try git("rev-parse", "--git-path", path)
            let url = result.hasPrefix("/") ? URL(fileURLWithPath: result) : root.appendingPathComponent(result)
            var info = stat()
            if lstat(url.path, &info) == 0 { throw MergePublicationError.gitLockOwnershipUnknown(url.path) }
            guard errno == ENOENT else { throw CocoaError(.fileReadUnknown) }
        }
    }

    private func requireWorktreeRoot() throws {
        let actual = try git("rev-parse", "--show-toplevel")
        guard URL(fileURLWithPath: actual).resolvingSymlinksInPath().standardizedFileURL == root.resolvingSymlinksInPath().standardizedFileURL else {
            throw ManagedGitError.invalidWorktree
        }
    }

    private func requireCleanWorktree() throws {
        guard try git("status", "--porcelain=v1", "--untracked-files=all").isEmpty else { throw ManagedGitError.dirtyWorktree }
    }

    @discardableResult
    private func git(_ arguments: String...) throws -> String { try GitCommand.run(at: root, arguments) }
}
