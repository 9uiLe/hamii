import Foundation
import CryptoKit
import HamiiCore
import HamiiFormat
import HamiiIndex
import HamiiMigrations

public enum MigrationPublicationError: Error, CustomStringConvertible {
    case invalidReview
    case historicalReviewRequiresReprepare
    case candidateMismatch
    case sourceChanged
    case unknownSourceState

    public var description: String {
        switch self {
        case .invalidReview: "Migration review record or explicit confirmation is invalid"
        case .historicalReviewRequiresReprepare:
            "Historical migration review targets an earlier format; prepare a new Current-format review"
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

/// A composed publication keeps only the immutable review binding and the
/// identities needed to classify the Git commit point. The review is the
/// authority for Canonical and route evidence.
private struct ComposedMigrationPublicationRecord: Codable {
    let formatVersion: Int
    let publicationID: UUID
    let reviewID: String
    let reviewRecordFormatVersion: Int
    let reviewSHA256: String
    let sourceRef: String
    let expectedSourceOID: String
    let candidateOID: String
    let operationID: UUID
    var phase: MigrationPublicationPhase
}

private struct MigrationPublicationCleanup {
    let reviewID: String
    let retentionRef: String
    let candidateOID: String
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
        let recordVersion: Int
        do { recordVersion = try reviews.recordVersion(reviewID) }
        catch { throw MigrationPublicationError.invalidReview }
        guard recordVersion == 3 else {
            if recordVersion == 1 || recordVersion == 2 {
                throw MigrationPublicationError.historicalReviewRequiresReprepare
            }
            throw MigrationPublicationError.invalidReview
        }
        return try publishComposed(reviewID: reviewID,
            confirmedSourceOID: confirmedSourceOID,
            confirmedCandidateOID: confirmedCandidateOID)
    }

    public func recover() throws -> MigrationPublicationResult {
        let (result, cleanupRecord) = try coordinator.withExclusive { () throws -> (MigrationPublicationResult, MigrationPublicationCleanup?) in
            try requireWorktreeRoot()
            guard let bytes = try coordinator.migrationPublicationRecord() else {
                try coordinator.requireReady()
                let ref = try git("symbolic-ref", "--quiet", "HEAD")
                let head = try git("rev-parse", "HEAD")
                try requireClean()
                let files = try MigrationRepositoryInput.load(from: root)
                let manifest = try historicalManifest(files)
                if [1, 2].contains(manifest.version) &&
                    manifest.version < MigrationRegistry.currentDocumentFormatVersion {
                    try requireNoCanonicalJournal()
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
            if try publicationRecordVersion(bytes) == 2 {
                return try recoverComposedPending(bytes)
            }
            return try recoverHistoricalLegacyPending(decode(bytes))
        }
        if let cleanupRecord {
            cleanup(reviewID: cleanupRecord.reviewID, retentionRef: cleanupRecord.retentionRef,
                    candidateOID: cleanupRecord.candidateOID)
        }
        return result
    }

    private func publishComposed(reviewID: String, confirmedSourceOID: String,
                                 confirmedCandidateOID: String) throws -> MigrationPublicationResult {
        let review: MigrationComposedReviewPackage
        let reviewBytes: Data
        do { (review, reviewBytes) = try reviews.loadComposedWithBytes(reviewID) }
        catch { throw MigrationPublicationError.invalidReview }
        if review.targetFormatVersion < MigrationRegistry.currentDocumentFormatVersion {
            throw MigrationPublicationError.historicalReviewRequiresReprepare
        }
        guard review.targetFormatVersion == MigrationRegistry.currentDocumentFormatVersion,
              review.sourceOID == confirmedSourceOID,
              review.candidateOID == confirmedCandidateOID else { throw MigrationPublicationError.invalidReview }
        let result = try coordinator.withExclusive { () throws -> MigrationPublicationResult in
            try coordinator.requireReady()
            try requireWorktreeRoot()
            guard try reviewDigest(reviews.loadRawBytes(reviewID)) == reviewDigest(reviewBytes) else {
                throw MigrationPublicationError.invalidReview
            }
            try validateComposedSource(review)
            try validateComposedImmutableCandidate(review)
            let sourceIdentity = try identity(review.sourceCanonicalIdentity)
            let candidateIdentity = try identity(review.validation.canonicalSnapshotIdentity)
            let old: StableCanonicalGeneration
            do { old = try generations.requireMatchingStable(validatedIdentity: sourceIdentity) }
            catch CanonicalGenerationError.missing {
                old = try generations.bootstrapVerified(validatedIdentity: sourceIdentity)
            }
            let operationID = UUID()
            var record = ComposedMigrationPublicationRecord(formatVersion: 2, publicationID: UUID(),
                reviewID: reviewID, reviewRecordFormatVersion: 3,
                reviewSHA256: reviewDigest(reviewBytes), sourceRef: review.sourceRef,
                expectedSourceOID: review.sourceOID, candidateOID: review.candidateOID,
                operationID: operationID, phase: .pending)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try coordinator.beginMigrationPublication(encoder.encode(record))
            try hook?(.pending)
            _ = try generations.beginPending(old: old, expectedNewIdentity: candidateIdentity,
                                             operationID: operationID)
            return try publishPending(publicationContext(review, record: record), recovering: false,
                                      expectedTargetVersion: review.targetFormatVersion) { phase in
                record.phase = phase
                try self.save(record)
            }
        }
        cleanup(reviewID: reviewID, retentionRef: review.retentionRef, candidateOID: review.candidateOID)
        return result
    }

    private func validateComposedSource(_ review: MigrationComposedReviewPackage) throws {
        try requireNoCanonicalJournal()
        guard try git("symbolic-ref", "--quiet", "HEAD") == review.sourceRef,
              try git("rev-parse", "HEAD") == review.sourceOID,
              try git("rev-parse", "HEAD^{tree}") == review.sourceTreeOID,
              try GitCanonicalRevisionCalculator().current(at: root).rawValue == review.sourceCanonicalRevision else {
            throw MigrationPublicationError.sourceChanged
        }
        try requireClean()
        let historical = try MigrationRepositoryInput.load(from: root)
        guard CanonicalByteIdentity.compute(files: historical.files).rawValue == review.sourceCanonicalIdentity,
              try historicalRevision(historical) == review.sourceDocumentRevision else {
            throw MigrationPublicationError.sourceChanged
        }
    }

    /// In-memory publication context only. A composed transition persists
    /// format-2 pending bytes, never this legacy-format context.
    private func publicationContext(_ review: MigrationComposedReviewPackage,
                                    record: ComposedMigrationPublicationRecord) -> MigrationPublicationRecord {
        MigrationPublicationRecord(formatVersion: 1, publicationID: record.publicationID,
            reviewID: record.reviewID, sourceRef: review.sourceRef,
            expectedSourceOID: review.sourceOID, sourceTreeOID: review.sourceTreeOID,
            sourceCanonicalRevision: review.sourceCanonicalRevision,
            sourceCanonicalIdentity: review.sourceCanonicalIdentity,
            sourceDocumentRevision: review.sourceDocumentRevision,
            candidateOID: review.candidateOID, candidateTreeOID: review.candidateTreeOID,
            candidateCanonicalIdentity: review.validation.canonicalSnapshotIdentity,
            candidateDocumentID: review.validation.documentID,
            candidateDocumentRevision: review.candidateDocumentRevision,
            retentionRef: review.retentionRef, operationID: record.operationID, phase: record.phase)
    }

    private func recoverComposedPending(_ bytes: Data) throws ->
        (MigrationPublicationResult, MigrationPublicationCleanup?) {
        var record = try decodeComposedRecord(bytes)
        let review: MigrationComposedReviewPackage
        let reviewBytes: Data
        do { (review, reviewBytes) = try reviews.loadComposedWithBytes(record.reviewID) }
        catch { throw MigrationPublicationError.invalidReview }
        guard reviewDigest(reviewBytes) == record.reviewSHA256,
              review.reviewID == record.reviewID,
              review.sourceRef == record.sourceRef,
              review.sourceOID == record.expectedSourceOID,
              review.candidateOID == record.candidateOID else {
            throw MigrationPublicationError.invalidReview
        }
        // Pending fields alone never decide which side of the Git CAS survived.
        // The original commit, full route, and retained final candidate are
        // checked before reading HEAD as old/candidate/unknown.
        try validateComposedImmutableCandidate(review)
        try GitLockGuard.requireAbsent(root: root, sourceRef: review.sourceRef)
        guard try git("symbolic-ref", "--quiet", "HEAD") == review.sourceRef else {
            throw MigrationPublicationError.unknownSourceState
        }
        try coordinator.invalidateClientObservations()
        let context = publicationContext(review, record: record)
        let head = try git("rev-parse", "HEAD")
        if head == review.sourceOID {
            try requireNoCanonicalJournal()
            try requireClean()
            guard try git("rev-parse", "HEAD^{tree}") == review.sourceTreeOID,
                  try rawIdentity() == identity(review.sourceCanonicalIdentity) else {
                throw MigrationPublicationError.unknownSourceState
            }
            let manifest = try historicalManifest(MigrationRepositoryInput.load(from: root))
            _ = try generations.reconcile(validatedIdentity: try identity(review.sourceCanonicalIdentity),
                                          expectedOperationID: record.operationID)
            try coordinator.finishMigrationPublication()
            return (MigrationPublicationResult(sourceRef: review.sourceRef, candidateOID: review.sourceOID,
                documentID: manifest.id, documentRevision: review.sourceDocumentRevision,
                canonicalSnapshotIdentity: review.sourceCanonicalIdentity,
                indexGenerationID: "", recovered: true), nil)
        }
        guard head == review.candidateOID else { throw MigrationPublicationError.unknownSourceState }
        try ensurePendingGeneration(context)
        if review.targetFormatVersion < MigrationRegistry.currentDocumentFormatVersion {
            let result = try finishHistoricalCandidate(context, recovering: true) { phase in
                record.phase = phase
                try self.save(record)
            }
            return (result, MigrationPublicationCleanup(reviewID: review.reviewID,
                retentionRef: review.retentionRef, candidateOID: review.candidateOID))
        }
        let result = try publishPending(context, recovering: true,
                                        expectedTargetVersion: review.targetFormatVersion) { phase in
            record.phase = phase
            try self.save(record)
        }
        return (result, MigrationPublicationCleanup(reviewID: review.reviewID,
            retentionRef: review.retentionRef, candidateOID: review.candidateOID))
    }

    /// A record-1 publication could have crossed its ref CAS in a previous
    /// Current-v2 process. Current Core never reads that v2 candidate after
    /// cutover: exact replay and raw identity checks live at this boundary.
    private func recoverHistoricalLegacyPending(_ record: MigrationPublicationRecord) throws ->
        (MigrationPublicationResult, MigrationPublicationCleanup?) {
        let review: MigrationReviewPackage
        do { review = try reviews.load(record.reviewID) }
        catch { throw MigrationPublicationError.invalidReview }
        guard review.sourceFormatVersion == 1, review.targetFormatVersion == 2,
              review.reviewID == record.reviewID,
              review.sourceRef == record.sourceRef,
              review.sourceOID == record.expectedSourceOID,
              review.sourceTreeOID == record.sourceTreeOID,
              review.sourceCanonicalRevision == record.sourceCanonicalRevision,
              review.sourceCanonicalIdentity == record.sourceCanonicalIdentity,
              review.sourceDocumentRevision == record.sourceDocumentRevision,
              review.candidateOID == record.candidateOID,
              review.candidateTreeOID == record.candidateTreeOID,
              review.validation.canonicalSnapshotIdentity == record.candidateCanonicalIdentity,
              review.validation.documentID == record.candidateDocumentID,
              review.candidateDocumentRevision == record.candidateDocumentRevision,
              review.retentionRef == record.retentionRef else {
            throw MigrationPublicationError.invalidReview
        }
        try validateHistoricalLegacyCandidate(review)
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
            return (MigrationPublicationResult(sourceRef: record.sourceRef,
                candidateOID: record.expectedSourceOID, documentID: record.candidateDocumentID,
                documentRevision: record.sourceDocumentRevision,
                canonicalSnapshotIdentity: record.sourceCanonicalIdentity,
                indexGenerationID: "", recovered: true), nil)
        }
        guard head == record.candidateOID else { throw MigrationPublicationError.unknownSourceState }
        try ensurePendingGeneration(record)
        let result = try finishHistoricalCandidate(record, recovering: true) { phase in
            var updated = record
            updated.phase = phase
            try self.save(updated)
        }
        return (result, MigrationPublicationCleanup(reviewID: record.reviewID,
            retentionRef: record.retentionRef, candidateOID: record.candidateOID))
    }

    private func validateHistoricalLegacyCandidate(_ review: MigrationReviewPackage) throws {
        guard [1, 2].contains(review.recordFormatVersion),
              review.edgePath == ["1->2"], review.validation.currentFormat == 2,
              review.validation.documentRevision == review.candidateDocumentRevision,
              review.indexValidation.sourceCanonicalIdentity == review.validation.canonicalSnapshotIdentity,
              IndexGenerationID(rawValue: review.indexValidation.indexGenerationID) != nil,
              try git("cat-file", "-t", review.sourceOID) == "commit",
              try git("rev-parse", "\(review.sourceOID)^{tree}") == review.sourceTreeOID,
              try git("rev-parse", "--verify", "\(review.retentionRef)^{commit}") == review.candidateOID,
              try git("cat-file", "-t", review.candidateOID) == "commit",
              try git("rev-parse", "\(review.candidateOID)^{tree}") == review.candidateTreeOID,
              try git("rev-list", "--parents", "-n", "1", review.candidateOID) ==
                  "\(review.candidateOID) \(review.sourceOID)",
              try gitPaths(GitCommand.runData(at: root,
                  ["diff", "--name-only", "-z", review.sourceOID, review.candidateOID])) == review.changedPaths,
              try git("diff", "--name-status", review.sourceOID, review.candidateOID) == review.diffNameStatus,
              try git("diff", "--stat", review.sourceOID, review.candidateOID) == review.diffStat else {
            throw MigrationPublicationError.candidateMismatch
        }
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("hamii-legacy-pending-check-\(UUID().uuidString)")
        let originalRoot = container.appendingPathComponent("original")
        let candidateRoot = container.appendingPathComponent("candidate")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        var originalAdded = false
        var candidateAdded = false
        defer {
            if candidateAdded { _ = try? git("worktree", "remove", "--force", candidateRoot.path) }
            if originalAdded { _ = try? git("worktree", "remove", "--force", originalRoot.path) }
            try? FileManager.default.removeItem(at: container)
        }
        _ = try git("worktree", "add", "--detach", originalRoot.path, review.sourceOID)
        originalAdded = true
        _ = try git("worktree", "add", "--detach", candidateRoot.path, review.candidateOID)
        candidateAdded = true
        try requireClean(at: originalRoot)
        try requireClean(at: candidateRoot)
        let original = try MigrationRepositoryInput.load(from: originalRoot)
        guard CanonicalByteIdentity.compute(files: original.files).rawValue == review.sourceCanonicalIdentity,
              try historicalRevision(original) == review.sourceDocumentRevision else {
            throw MigrationPublicationError.candidateMismatch
        }
        let replay = try replaySource(original, review: review)
        let committed = try MigrationRepositoryInput.load(from: candidateRoot)
        guard let candidate = replay.singleEdgeCandidate,
              candidate.classification == review.classification,
              candidate.resolutionDecisions == (review.resolutionAudit?.decisions ?? []),
              candidate.losses == (review.resolutionAudit?.losses ?? []),
              candidate.remainingUnresolved.isEmpty,
              replay.finalFiles.files == committed.files else {
            throw MigrationPublicationError.candidateMismatch
        }
        try validateHistoricalV2Files(committed,
            expectedIdentity: review.validation.canonicalSnapshotIdentity,
            expectedID: review.validation.documentID,
            expectedRevision: review.candidateDocumentRevision)
        guard try GitCanonicalRevisionCalculator().current(at: candidateRoot).rawValue ==
              review.indexValidation.canonicalRevision else {
            throw MigrationPublicationError.candidateMismatch
        }
    }

    /// Reconstructs the reviewed route from the immutable original commit,
    /// even when the published worktree now contains the final candidate.
    /// This runs before a composed pending record may classify HEAD.
    private func validateComposedImmutableCandidate(_ review: MigrationComposedReviewPackage) throws {
        try review.validateShape()
        let route = try MigrationRegistry.route(from: review.sourceFormatVersion,
                                                to: review.targetFormatVersion)
        try MigrationReceiptChain.validate(review.receipts, for: route,
            sourceIdentity: review.sourceCanonicalIdentity,
            finalIdentity: review.validation.canonicalSnapshotIdentity)
        guard review.sourceOID != review.candidateOID,
              try git("cat-file", "-t", review.sourceOID) == "commit",
              try git("rev-parse", "\(review.sourceOID)^{tree}") == review.sourceTreeOID,
              try git("rev-parse", "--verify", "\(review.retentionRef)^{commit}") == review.candidateOID,
              try git("cat-file", "-t", review.candidateOID) == "commit",
              try git("rev-parse", "\(review.candidateOID)^{tree}") == review.candidateTreeOID,
              try git("rev-list", "--parents", "-n", "1", review.candidateOID) ==
                  "\(review.candidateOID) \(review.sourceOID)" else {
            throw MigrationPublicationError.candidateMismatch
        }
        let paths = try gitPaths(GitCommand.runData(at: root,
            ["diff", "--name-only", "-z", review.sourceOID, review.candidateOID]))
        guard paths == review.changedPaths,
              try git("diff", "--name-status", review.sourceOID, review.candidateOID) == review.diffNameStatus,
              try git("diff", "--stat", review.sourceOID, review.candidateOID) == review.diffStat else {
            throw MigrationPublicationError.candidateMismatch
        }

        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("hamii-composed-migration-check-\(UUID().uuidString)")
        let originalRoot = container.appendingPathComponent("original")
        let candidateRoot = container.appendingPathComponent("candidate")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        var originalAdded = false
        var candidateAdded = false
        defer {
            if candidateAdded { _ = try? git("worktree", "remove", "--force", candidateRoot.path) }
            if originalAdded { _ = try? git("worktree", "remove", "--force", originalRoot.path) }
            try? FileManager.default.removeItem(at: container)
        }
        _ = try git("worktree", "add", "--detach", originalRoot.path, review.sourceOID)
        originalAdded = true
        _ = try git("worktree", "add", "--detach", candidateRoot.path, review.candidateOID)
        candidateAdded = true
        try requireClean(at: originalRoot)
        try requireClean(at: candidateRoot)
        let original = try MigrationRepositoryInput.load(from: originalRoot)
        guard CanonicalByteIdentity.compute(files: original.files).rawValue == review.sourceCanonicalIdentity,
              try historicalRevision(original) == review.sourceDocumentRevision else {
            throw MigrationPublicationError.candidateMismatch
        }
        let resolutions = review.edgeResolutionAudits.map {
            MigrationEdgeResolutionInput(edgeID: $0.edgeID, manifest: $0.manifest,
                                         sourceBinding: $0.manifest.sourceBinding)
        }
        let replay = try MigrationRouteReplay.run(original, route: route, edgeResolutions: resolutions)
        let committed = try MigrationRepositoryInput.load(from: candidateRoot)
        guard replay.receipts == review.receipts,
              replay.finalFiles.files == committed.files,
              CanonicalByteIdentity.compute(files: committed.files).rawValue == review.validation.canonicalSnapshotIdentity else {
            throw MigrationPublicationError.candidateMismatch
        }
        for audit in review.edgeResolutionAudits {
            guard let receipt = replay.receipts.first(where: { $0.edgeID == audit.edgeID }),
                  receipt.resolutionDecisions == audit.decisions,
                  receipt.losses == audit.losses else { throw MigrationPublicationError.candidateMismatch }
        }
        if review.targetFormatVersion < MigrationRegistry.currentDocumentFormatVersion {
            try validateHistoricalTarget(review, committed: committed, candidateRoot: candidateRoot)
            return
        }
        let snapshot = try CanonicalRepository(root: candidateRoot).withCoordinatedSnapshot { $0 }
        guard snapshot.document.versions.document == review.targetFormatVersion,
              snapshot.identity.rawValue == review.validation.canonicalSnapshotIdentity,
              snapshot.document.id.rawValue == review.validation.documentID,
              snapshot.document.revision == review.candidateDocumentRevision,
              review.indexValidation.sourceCanonicalIdentity == snapshot.identity.rawValue,
              try GitCanonicalRevisionCalculator().current(at: candidateRoot).rawValue ==
                  review.indexValidation.canonicalRevision,
              IndexGenerationID(rawValue: review.indexValidation.indexGenerationID) != nil else {
            throw MigrationPublicationError.candidateMismatch
        }
        try index.validateCandidate(at: candidateRoot, snapshot: snapshot)
    }

    private func validateHistoricalTarget(_ review: MigrationComposedReviewPackage,
                                          committed: MigrationFileSet, candidateRoot: URL) throws {
        guard review.targetFormatVersion == 2,
              review.indexValidation.sourceCanonicalIdentity == review.validation.canonicalSnapshotIdentity,
              IndexGenerationID(rawValue: review.indexValidation.indexGenerationID) != nil,
              try GitCanonicalRevisionCalculator().current(at: candidateRoot).rawValue ==
                  review.indexValidation.canonicalRevision else {
            throw MigrationPublicationError.candidateMismatch
        }
        try validateHistoricalV2Files(committed,
            expectedIdentity: review.validation.canonicalSnapshotIdentity,
            expectedID: review.validation.documentID,
            expectedRevision: review.candidateDocumentRevision)
    }

    private func validateHistoricalV2Files(_ files: MigrationFileSet,
                                           expectedIdentity: String,
                                           expectedID: String,
                                           expectedRevision: Int) throws {
        let manifest = try historicalManifest(files)
        guard manifest.version == 2, manifest.id == expectedID,
              manifest.revision == expectedRevision,
              CanonicalByteIdentity.compute(files: files.files).rawValue == expectedIdentity else {
            throw MigrationPublicationError.candidateMismatch
        }
        // The next installed edge's preflight is a historical raw-v2 check.
        // Current Core does not gain a v2 decoder for old pending recovery.
        _ = try MigrationRegistry.analyzeEdge(files,
            edge: MigrationEdge(sourceVersion: 2, targetVersion: 3))
    }

    private func replaySource(_ historical: MigrationFileSet,
                              review: MigrationReviewPackage) throws -> MigrationRouteReplayResult {
        let route = try MigrationRegistry.route(from: review.sourceFormatVersion,
                                                to: review.targetFormatVersion)
        guard route.edgePath == review.edgePath else { throw MigrationPublicationError.candidateMismatch }
        let binding = review.resolutionAudit.map { _ in
            MigrationResolutionSourceBinding(sourceOID: review.sourceOID,
                sourceCanonicalIdentity: review.sourceCanonicalIdentity,
                sourceFormatVersion: review.sourceFormatVersion,
                targetFormatVersion: review.targetFormatVersion)
        }
        return try MigrationRouteReplay.run(historical, route: route,
            resolution: review.resolutionAudit?.manifest, sourceBinding: binding)
    }

    private func publishPending(_ initial: MigrationPublicationRecord,
                                recovering: Bool,
                                expectedTargetVersion: Int,
                                saveComposedPhase: (MigrationPublicationPhase) throws -> Void) throws -> MigrationPublicationResult {
        var record = initial
        func persist(_ phase: MigrationPublicationPhase) throws {
            record.phase = phase
            try saveComposedPhase(phase)
        }
        guard try git("rev-parse", "--verify", "\(record.retentionRef)^{commit}") == record.candidateOID,
              try git("rev-parse", "\(record.candidateOID)^{tree}") == record.candidateTreeOID else {
            throw MigrationPublicationError.candidateMismatch
        }
        try GitLockGuard.requireAbsent(root: root, sourceRef: record.sourceRef)
        if !recovering {
            try hook?(.beforeRefCAS)
            _ = try git("update-ref", record.sourceRef, record.candidateOID, record.expectedSourceOID)
            try persist(.refPublished)
            try hook?(.afterRefCAS)
        }
        try hook?(.beforeMaterialization)
        _ = try git("read-tree", "--reset", "-u", record.candidateOID)
        try persist(.worktreeMaterialized)
        try hook?(.materialized)
        try requireClean()
        try hook?(.beforeCanonicalValidation)
        let snapshot = try repository.snapshotDuringMigrationPublication {
            try self.hook?(.duringCanonicalValidation)
        }
        guard snapshot.identity.rawValue == record.candidateCanonicalIdentity,
              snapshot.document.id.rawValue == record.candidateDocumentID,
              snapshot.document.revision == record.candidateDocumentRevision,
              snapshot.document.versions.document == expectedTargetVersion else {
            throw MigrationPublicationError.candidateMismatch
        }
        try persist(.canonicalVerified)
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
        try persist(.indexPublished)
        try hook?(.indexPublished)
        try hook?(.beforeGateRelease)
        try coordinator.finishMigrationPublication()
        try hook?(.gateReleased)
        return MigrationPublicationResult(sourceRef: record.sourceRef, candidateOID: record.candidateOID,
            documentID: snapshot.document.id.rawValue, documentRevision: snapshot.document.revision,
            canonicalSnapshotIdentity: snapshot.identity.rawValue,
            indexGenerationID: built.id.rawValue, recovered: recovering)
    }

    /// Finishes an already published historical v2 candidate left by a
    /// previous binary. It does not make v2 a Current document or publish a v2
    /// Index. A separate reviewed 2→3 migration is required after gate release.
    private func finishHistoricalCandidate(_ initial: MigrationPublicationRecord,
        recovering: Bool,
        savePhase: (MigrationPublicationPhase) throws -> Void) throws -> MigrationPublicationResult {
        var record = initial
        func persist(_ phase: MigrationPublicationPhase) throws {
            record.phase = phase
            try savePhase(phase)
        }
        guard try git("rev-parse", "--verify", "\(record.retentionRef)^{commit}") == record.candidateOID,
              try git("rev-parse", "\(record.candidateOID)^{tree}") == record.candidateTreeOID else {
            throw MigrationPublicationError.candidateMismatch
        }
        try requireNoCanonicalJournal()
        try GitLockGuard.requireAbsent(root: root, sourceRef: record.sourceRef)
        try hook?(.beforeMaterialization)
        _ = try git("read-tree", "--reset", "-u", record.candidateOID)
        try persist(.worktreeMaterialized)
        try hook?(.materialized)
        try requireClean()
        try hook?(.beforeCanonicalValidation)
        let files = try MigrationRepositoryInput.load(from: root)
        try hook?(.duringCanonicalValidation)
        try validateHistoricalV2Files(files, expectedIdentity: record.candidateCanonicalIdentity,
            expectedID: record.candidateDocumentID,
            expectedRevision: record.candidateDocumentRevision)
        guard try git("symbolic-ref", "--quiet", "HEAD") == record.sourceRef,
              try git("rev-parse", "HEAD") == record.candidateOID else {
            throw MigrationPublicationError.unknownSourceState
        }
        try persist(.canonicalVerified)
        try hook?(.canonicalVerified)
        _ = try generations.reconcile(validatedIdentity: try identity(record.candidateCanonicalIdentity),
                                      expectedOperationID: record.operationID)
        try hook?(.beforeGateRelease)
        try coordinator.finishMigrationPublication()
        try hook?(.gateReleased)
        return MigrationPublicationResult(sourceRef: record.sourceRef,
            candidateOID: record.candidateOID,
            documentID: record.candidateDocumentID,
            documentRevision: record.candidateDocumentRevision,
            canonicalSnapshotIdentity: record.candidateCanonicalIdentity,
            indexGenerationID: "", recovered: recovering)
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

    private func publicationRecordVersion(_ bytes: Data) throws -> Int {
        try MigrationReviewUniqueKeys.validate(bytes, allDepths: true)
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let version = object["formatVersion"] as? Int, [1, 2].contains(version) else {
            throw MigrationPublicationError.invalidReview
        }
        return version
    }

    private func decodeComposedRecord(_ bytes: Data) throws -> ComposedMigrationPublicationRecord {
        try MigrationReviewUniqueKeys.validate(bytes, allDepths: true)
        let required: Set<String> = ["formatVersion", "publicationID", "reviewID",
            "reviewRecordFormatVersion", "reviewSHA256", "sourceRef", "expectedSourceOID",
            "candidateOID", "operationID", "phase"]
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(object.keys) == required,
              let record = try? JSONDecoder().decode(ComposedMigrationPublicationRecord.self, from: bytes),
              record.formatVersion == 2, record.reviewRecordFormatVersion == 3,
              UUID(uuidString: record.reviewID)?.uuidString.lowercased() == record.reviewID,
              record.sourceRef.hasPrefix("refs/heads/"),
              record.expectedSourceOID != record.candidateOID,
              record.reviewSHA256.utf8.count == 64,
              record.reviewSHA256.utf8.allSatisfy({
                  ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
              }) else { throw MigrationPublicationError.invalidReview }
        return record
    }

    private func reviewDigest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func save(_ record: ComposedMigrationPublicationRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try coordinator.writeMigrationPublicationRecord(encoder.encode(record))
    }

    private func save(_ record: MigrationPublicationRecord) throws {
        try coordinator.writeMigrationPublicationRecord(JSONEncoder().encode(record))
    }

    private func cleanup(reviewID: String, retentionRef: String, candidateOID: String) {
        _ = try? git("update-ref", "-d", retentionRef, candidateOID)
        if (try? reviews.recordVersion(reviewID)) == 1 {
            try? reviews.remove(reviewID)
        }
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
