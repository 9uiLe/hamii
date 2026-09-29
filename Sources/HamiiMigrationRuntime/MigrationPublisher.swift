import Foundation
import HamiiCore
import HamiiFormat
import HamiiIndex
import HamiiMigrations

public enum MigrationPublicationError: Error, CustomStringConvertible {
    case invalidReview
    case candidateMismatch
    case sourceChanged
    case unknownSourceState

    public var description: String {
        switch self {
        case .invalidReview: "Migration review record or explicit confirmation is invalid"
        case .candidateMismatch: "Retained candidate differs from the reviewed and validated Canonical state"
        case .sourceChanged: "Historical source changed after candidate review"
        case .unknownSourceState: "Source ref is neither reviewed old nor candidate OID; migration remains gated"
        }
    }
}

enum MigrationPublicationStep: Equatable {
    case pending, beforeRefCAS, afterRefCAS, beforeMaterialization, materialized
    case beforeCanonicalValidation, duringCanonicalValidation, canonicalVerified, beforeIndexBuild, indexBuilt
    case beforeIndexVerification, indexPublished, beforeGateRelease, gateReleased
}

private enum MigrationPublicationPhase: String, Codable {
    case pending, refPublished, worktreeMaterialized, canonicalVerified, indexPublished
}

private struct MigrationPublicationRecord: Codable {
    let formatVersion: Int
    let publicationID: UUID
    let reviewID: String
    let sourceRef: String
    let expectedSourceOID: String
    let sourceTreeOID: String
    let sourceCanonicalRevision: String
    let sourceCanonicalIdentity: String
    let sourceDocumentRevision: Int
    let candidateOID: String
    let candidateTreeOID: String
    let candidateCanonicalIdentity: String
    let candidateDocumentID: String
    let candidateDocumentRevision: Int
    let retentionRef: String
    let operationID: UUID
    var phase: MigrationPublicationPhase
}

public struct MigrationPublicationResult: Encodable {
    public let sourceRef: String
    public let candidateOID: String
    public let documentID: String
    public let documentRevision: Int
    public let canonicalSnapshotIdentity: String
    public let indexGenerationID: String
    public let recovered: Bool
}

/// Publication is a coordinated, fail-closed transition. The Git ref CAS is
/// the Canonical commit point; a later Index failure leaves a recoverable gate.
public final class MigrationPublisher {
    public let root: URL
    private let coordinator: WorktreeCoordinator
    private let repository: CanonicalRepository
    private let generations: CanonicalGenerationStore
    private let reviews: MigrationReviewStore
    private let index: any CanonicalIndexPublishing
    private let hook: ((MigrationPublicationStep) throws -> Void)?

    public init(root: URL, index: any CanonicalIndexPublishing) {
        self.root = root.standardizedFileURL
        coordinator = WorktreeCoordinator(root: self.root)
        repository = CanonicalRepository(root: self.root)
        generations = CanonicalGenerationStore(root: self.root)
        reviews = MigrationReviewStore(root: self.root)
        self.index = index
        hook = nil
    }

    init(root: URL, index: any CanonicalIndexPublishing,
         hook: @escaping (MigrationPublicationStep) throws -> Void) {
        self.root = root.standardizedFileURL
        coordinator = WorktreeCoordinator(root: self.root)
        repository = CanonicalRepository(root: self.root)
        generations = CanonicalGenerationStore(root: self.root)
        reviews = MigrationReviewStore(root: self.root)
        self.index = index
        self.hook = hook
    }

    public var hasPendingPublication: Bool { coordinator.migrationPublicationPending() }

    public func publish(reviewID: String, confirmedSourceOID: String,
                        confirmedCandidateOID: String) throws -> MigrationPublicationResult {
        let review: MigrationReviewPackage
        do { review = try reviews.load(reviewID) }
        catch { throw MigrationPublicationError.invalidReview }
        guard review.sourceOID == confirmedSourceOID,
              review.candidateOID == confirmedCandidateOID else { throw MigrationPublicationError.invalidReview }
        do { try validateRetainedCandidate(review) }
        catch { throw MigrationPublicationError.candidateMismatch }
        let result = try coordinator.withExclusive { () throws -> MigrationPublicationResult in
            try coordinator.requireReady()
            try requireWorktreeRoot()
            try validateSource(review)
            let sourceIdentity = try identity(review.sourceCanonicalIdentity)
            let candidateIdentity = try identity(review.validation.canonicalSnapshotIdentity)
            let old: StableCanonicalGeneration
            do { old = try generations.requireMatchingStable(validatedIdentity: sourceIdentity) }
            catch CanonicalGenerationError.missing {
                old = try generations.bootstrapVerified(validatedIdentity: sourceIdentity)
            }
            let operationID = UUID()
            let record = MigrationPublicationRecord(formatVersion: 1, publicationID: UUID(), reviewID: reviewID,
                sourceRef: review.sourceRef, expectedSourceOID: review.sourceOID,
                sourceTreeOID: review.sourceTreeOID, sourceCanonicalRevision: review.sourceCanonicalRevision,
                sourceCanonicalIdentity: review.sourceCanonicalIdentity,
                sourceDocumentRevision: review.sourceDocumentRevision,
                candidateOID: review.candidateOID, candidateTreeOID: review.candidateTreeOID,
                candidateCanonicalIdentity: review.validation.canonicalSnapshotIdentity,
                candidateDocumentID: review.validation.documentID,
                candidateDocumentRevision: review.candidateDocumentRevision,
                retentionRef: review.retentionRef, operationID: operationID, phase: .pending)
            try coordinator.beginMigrationPublication(try JSONEncoder().encode(record))
            try hook?(.pending)
            _ = try generations.beginPending(old: old, expectedNewIdentity: candidateIdentity,
                                             operationID: operationID)
            return try publishPending(record, recovering: false)
        }
        cleanup(reviewID: reviewID, retentionRef: review.retentionRef, candidateOID: review.candidateOID)
        return result
    }

    public func recover() throws -> MigrationPublicationResult {
        let (result, cleanupRecord) = try coordinator.withExclusive { () throws -> (MigrationPublicationResult, MigrationPublicationRecord?) in
            try requireWorktreeRoot()
            guard let bytes = try coordinator.migrationPublicationRecord() else {
                try coordinator.requireReady()
                let ref = try git("symbolic-ref", "--quiet", "HEAD")
                let head = try git("rev-parse", "HEAD")
                try requireClean()
                let files = try MigrationRepositoryInput.load(from: root)
                let manifest = try historicalManifest(files)
                if manifest.version == 1 {
                    _ = try generations.requireMatchingStable(validatedIdentity:
                        CanonicalByteIdentity.compute(files: files.files))
                    return (MigrationPublicationResult(sourceRef: ref, candidateOID: head,
                        documentID: manifest.id, documentRevision: manifest.revision,
                        canonicalSnapshotIdentity: CanonicalByteIdentity.compute(files: files.files).rawValue,
                        indexGenerationID: "", recovered: true), nil)
                }
                let snapshot = try repository.snapshotDuringMigrationPublication()
                let stable = try generations.requireMatchingStable(snapshot)
                let published = try index.verifyPublished(at: root, snapshot: snapshot)
                guard published.sourceGenerationBinding == .bound(stable.generation) else {
                    throw MigrationPublicationError.candidateMismatch
                }
                return (MigrationPublicationResult(sourceRef: ref, candidateOID: head,
                    documentID: snapshot.document.id.rawValue, documentRevision: snapshot.document.revision,
                    canonicalSnapshotIdentity: snapshot.identity.rawValue,
                    indexGenerationID: published.id.rawValue, recovered: true), nil)
            }
            let record = try decode(bytes)
            try GitLockGuard.requireAbsent(root: root, sourceRef: record.sourceRef)
            guard try git("symbolic-ref", "--quiet", "HEAD") == record.sourceRef else {
                throw MigrationPublicationError.unknownSourceState
            }
            try coordinator.invalidateClientObservations()
            let head = try git("rev-parse", "HEAD")
            if head == record.expectedSourceOID {
                try requireNoCanonicalJournal()
                try requireClean()
                guard try git("rev-parse", "HEAD^{tree}") == record.sourceTreeOID,
                      try rawIdentity() == identity(record.sourceCanonicalIdentity) else {
                    throw MigrationPublicationError.unknownSourceState
                }
                _ = try generations.reconcile(validatedIdentity: try identity(record.sourceCanonicalIdentity),
                                              expectedOperationID: record.operationID)
                try coordinator.finishMigrationPublication()
                return (MigrationPublicationResult(sourceRef: record.sourceRef, candidateOID: record.expectedSourceOID,
                    documentID: record.candidateDocumentID, documentRevision: record.sourceDocumentRevision,
                    canonicalSnapshotIdentity: record.sourceCanonicalIdentity, indexGenerationID: "", recovered: true), nil)
            }
            guard head == record.candidateOID else { throw MigrationPublicationError.unknownSourceState }
            try ensurePendingGeneration(record)
            return (try publishPending(record, recovering: true), record)
        }
        if let cleanupRecord {
            cleanup(reviewID: cleanupRecord.reviewID, retentionRef: cleanupRecord.retentionRef,
                    candidateOID: cleanupRecord.candidateOID)
        }
        return result
    }

    private func validateRetainedCandidate(_ review: MigrationReviewPackage) throws {
        guard review.recordFormatVersion == 1, review.sourceFormatVersion == 1,
              review.targetFormatVersion == 2,
              review.classification == .losslessWithNormalization,
              review.edgePath == ["1->2"],
              review.validation.currentFormat == 2,
              review.validation.documentRevision == review.candidateDocumentRevision,
              review.indexValidation.sourceCanonicalIdentity == review.validation.canonicalSnapshotIdentity,
              IndexGenerationID(rawValue: review.indexValidation.indexGenerationID) != nil,
              review.retentionRef == "refs/hamii/migration-candidates/\(review.reviewID)",
              try git("rev-parse", "--verify", "\(review.retentionRef)^{commit}") == review.candidateOID,
              try git("cat-file", "-t", review.candidateOID) == "commit",
              try git("rev-parse", "\(review.candidateOID)^{tree}") == review.candidateTreeOID,
              try git("rev-list", "--parents", "-n", "1", review.candidateOID) == "\(review.candidateOID) \(review.sourceOID)" else {
            throw MigrationPublicationError.candidateMismatch
        }
        let paths = try gitPaths(GitCommand.runData(at: root,
            ["diff", "--name-only", "-z", review.sourceOID, review.candidateOID]))
        guard paths == review.changedPaths else { throw MigrationPublicationError.candidateMismatch }
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("hamii-migration-publish-check-\(UUID().uuidString)")
        let candidateRoot = container.appendingPathComponent("worktree")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        var added = false
        defer {
            if added { _ = try? git("worktree", "remove", "--force", candidateRoot.path) }
            try? FileManager.default.removeItem(at: container)
        }
        _ = try git("worktree", "add", "--detach", candidateRoot.path, review.candidateOID)
        added = true
        try requireClean(at: candidateRoot)
        let snapshot = try CanonicalRepository(root: candidateRoot).withCoordinatedSnapshot { $0 }
        guard snapshot.document.versions.document == 2,
              snapshot.identity.rawValue == review.validation.canonicalSnapshotIdentity,
              snapshot.document.id.rawValue == review.validation.documentID,
              snapshot.document.revision == review.candidateDocumentRevision,
              snapshot.document.revision == review.validation.documentRevision else {
            throw MigrationPublicationError.candidateMismatch
        }
        try index.validateCandidate(at: candidateRoot, snapshot: snapshot)
    }

    private func validateSource(_ review: MigrationReviewPackage) throws {
        try requireNoCanonicalJournal()
        guard try git("symbolic-ref", "--quiet", "HEAD") == review.sourceRef,
              try git("rev-parse", "HEAD") == review.sourceOID,
              try git("rev-parse", "HEAD^{tree}") == review.sourceTreeOID,
              try GitCanonicalRevisionCalculator().current(at: root).rawValue == review.sourceCanonicalRevision else {
            throw MigrationPublicationError.sourceChanged
        }
        try requireClean()
        let historical = try MigrationRepositoryInput.load(from: root)
        let analysis = try MigrationRegistry.analyze(historical)
        guard analysis.automaticCandidateEligible,
              analysis.classification == .losslessWithNormalization,
              CanonicalByteIdentity.compute(files: historical.files) == (try identity(review.sourceCanonicalIdentity)),
              try historicalRevision(historical) == review.sourceDocumentRevision else {
            throw MigrationPublicationError.sourceChanged
        }
    }

    private func publishPending(_ initial: MigrationPublicationRecord,
                                recovering: Bool) throws -> MigrationPublicationResult {
        var record = initial
        guard try git("rev-parse", "--verify", "\(record.retentionRef)^{commit}") == record.candidateOID,
              try git("rev-parse", "\(record.candidateOID)^{tree}") == record.candidateTreeOID else {
            throw MigrationPublicationError.candidateMismatch
        }
        try GitLockGuard.requireAbsent(root: root, sourceRef: record.sourceRef)
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
        try requireClean()
        try hook?(.beforeCanonicalValidation)
        let snapshot = try repository.snapshotDuringMigrationPublication {
            try self.hook?(.duringCanonicalValidation)
        }
        guard snapshot.identity.rawValue == record.candidateCanonicalIdentity,
              snapshot.document.id.rawValue == record.candidateDocumentID,
              snapshot.document.revision == record.candidateDocumentRevision,
              snapshot.document.versions.document == 2 else {
            throw MigrationPublicationError.candidateMismatch
        }
        record.phase = .canonicalVerified
        try save(record)
        try hook?(.canonicalVerified)
        _ = try generations.finalizeVerifiedTransition(snapshot, expectedOperationID: record.operationID)
        try hook?(.beforeIndexBuild)
        let built = try index.rebuildPublished(at: root, snapshot: snapshot)
        try hook?(.indexBuilt)
        guard built.sourceCanonicalIdentity == snapshot.identity,
              built.sourceGenerationBinding == .bound(try generations.requireMatchingStable(snapshot).generation),
              built.documentID == snapshot.document.id,
              built.documentRevision == snapshot.document.revision else {
            throw MigrationPublicationError.candidateMismatch
        }
        try hook?(.beforeIndexVerification)
        let after = try repository.snapshotDuringMigrationPublication()
        guard try git("symbolic-ref", "--quiet", "HEAD") == record.sourceRef,
              try git("rev-parse", "HEAD") == record.candidateOID,
              after.identity == snapshot.identity,
              try index.verifyPublished(at: root, snapshot: after) == built else {
            throw MigrationPublicationError.candidateMismatch
        }
        try requireClean()
        record.phase = .indexPublished
        try save(record)
        try hook?(.indexPublished)
        try hook?(.beforeGateRelease)
        try coordinator.finishMigrationPublication()
        try hook?(.gateReleased)
        return MigrationPublicationResult(sourceRef: record.sourceRef, candidateOID: record.candidateOID,
            documentID: snapshot.document.id.rawValue, documentRevision: snapshot.document.revision,
            canonicalSnapshotIdentity: snapshot.identity.rawValue,
            indexGenerationID: built.id.rawValue, recovered: recovering)
    }

    private func ensurePendingGeneration(_ record: MigrationPublicationRecord) throws {
        let oldIdentity = try identity(record.sourceCanonicalIdentity)
        if let stable = try? generations.readStable(), stable.snapshotIdentity == oldIdentity {
            _ = try generations.beginPending(old: stable,
                expectedNewIdentity: try identity(record.candidateCanonicalIdentity),
                operationID: record.operationID)
        }
    }

    private func decode(_ bytes: Data) throws -> MigrationPublicationRecord {
        guard let record = try? JSONDecoder().decode(MigrationPublicationRecord.self, from: bytes),
              record.formatVersion == 1,
              record.sourceRef.hasPrefix("refs/heads/"),
              record.retentionRef == "refs/hamii/migration-candidates/\(record.reviewID)",
              UUID(uuidString: record.reviewID) != nil,
              CanonicalSnapshotIdentity(rawValue: record.sourceCanonicalIdentity) != nil,
              CanonicalSnapshotIdentity(rawValue: record.candidateCanonicalIdentity) != nil else {
            throw MigrationPublicationError.invalidReview
        }
        return record
    }

    private func save(_ record: MigrationPublicationRecord) throws {
        try coordinator.writeMigrationPublicationRecord(JSONEncoder().encode(record))
    }

    private func cleanup(reviewID: String, retentionRef: String, candidateOID: String) {
        _ = try? git("update-ref", "-d", retentionRef, candidateOID)
        try? reviews.remove(reviewID)
    }

    private func requireWorktreeRoot() throws {
        let actual = try git("rev-parse", "--show-toplevel")
        guard URL(fileURLWithPath: actual).resolvingSymlinksInPath().standardizedFileURL ==
              root.resolvingSymlinksInPath().standardizedFileURL else { throw MigrationPreparationError.invalidWorktree }
    }

    private func requireClean() throws { try requireClean(at: root) }

    private func requireNoCanonicalJournal() throws {
        guard !["transaction.prepare", "transaction.ready", "transaction.complete"].contains(where: {
            FileManager.default.fileExists(atPath: root.appendingPathComponent(".hamii/\($0)").path)
        }) else { throw MigrationPublicationError.sourceChanged }
    }
    private func requireClean(at path: URL) throws {
        guard try GitCommand.run(at: path, ["status", "--porcelain=v1", "--untracked-files=all"]).isEmpty else {
            throw MigrationPreparationError.dirtySource
        }
    }

    private func rawIdentity() throws -> CanonicalSnapshotIdentity {
        CanonicalByteIdentity.compute(files: try MigrationRepositoryInput.load(from: root).files)
    }

    private func historicalRevision(_ files: MigrationFileSet) throws -> Int {
        try historicalManifest(files).revision
    }

    private func historicalManifest(_ files: MigrationFileSet) throws -> (version: Int, id: String, revision: Int) {
        guard let bytes = files.files["hamii.json"],
              let manifest = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let version = manifest["formatVersion"] as? Int,
              let id = manifest["id"] as? [String: String],
              let rawID = id["rawValue"],
              let revision = manifest["revision"] as? Int else { throw MigrationPublicationError.sourceChanged }
        return (version, rawID, revision)
    }

    private func identity(_ raw: String) throws -> CanonicalSnapshotIdentity {
        guard let identity = CanonicalSnapshotIdentity(rawValue: raw) else { throw MigrationPublicationError.invalidReview }
        return identity
    }

    private func gitPaths(_ bytes: Data) throws -> [String] {
        try bytes.split(separator: 0).map { part in
            guard let path = String(data: Data(part), encoding: .utf8) else { throw MigrationPublicationError.candidateMismatch }
            return path
        }.sorted()
    }

    @discardableResult
    private func git(_ args: String...) throws -> String { try GitCommand.run(at: root, args) }
}
