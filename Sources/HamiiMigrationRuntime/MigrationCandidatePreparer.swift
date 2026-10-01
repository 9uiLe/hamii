import Foundation
import HamiiCore
import HamiiFormat
import HamiiIndex
import HamiiMigrations

public enum MigrationPreparationError: Error, CustomStringConvertible {
    case invalidWorktree
    case detachedSource
    case dirtySource
    case alreadyCurrent
    case migrationUnavailable([String])
    case staleSource
    case unexpectedPaths(expected: [String], actual: [String])
    case invalidCandidate(String)

    public var description: String {
        switch self {
        case .invalidWorktree: "Migration source must be a Git worktree root"
        case .detachedSource: "Migration source must have a symbolic branch"
        case .dirtySource: "Migration source must be clean and committed"
        case .alreadyCurrent: "Document is already in the Current Format"
        case .migrationUnavailable(let blockers): "Migration candidate requires resolution: \(blockers.joined(separator: "; "))"
        case .staleSource: "Migration source changed during candidate preparation"
        case .unexpectedPaths(let expected, let actual): "Candidate path mismatch: expected \(expected), found \(actual)"
        case .invalidCandidate(let detail): "Migration candidate validation failed: \(detail)"
        }
    }
}

public struct MigrationValidationResult: Codable {
    public let currentFormat: Int
    public let canonicalSnapshotIdentity: String
    public let documentID: String
    public let documentRevision: Int
}

public struct MigrationIndexValidationResult: Codable {
    public let sourceCanonicalIdentity: String
    public let indexGenerationID: String
    public let canonicalRevision: String
}

public struct MigrationResolutionAudit: Codable {
    public let manifest: MigrationResolutionManifest
    public let decisions: [MigrationResolutionDecision]
    public let losses: [MigrationResolutionLoss]
}

/// Exact OIDs identify the reviewed source and immutable candidate. This is
/// preparation evidence, not authorization to publish either Git ref or Index.
public struct MigrationReviewPackage: Codable {
    public let recordFormatVersion: Int
    public let reviewID: String
    public let sourceRef: String
    public let sourceOID: String
    public let sourceTreeOID: String
    public let sourceCanonicalRevision: String
    public let sourceCanonicalIdentity: String
    public let sourceFormatVersion: Int
    public let targetFormatVersion: Int
    public let sourceDocumentRevision: Int
    public let candidateDocumentRevision: Int
    public let classification: MigrationClassification
    public let edgePath: [String]
    public let candidateOID: String
    public let candidateTreeOID: String
    public let retentionRef: String
    public let changedPaths: [String]
    public let diffNameStatus: String
    public let diffStat: String
    public let validation: MigrationValidationResult
    public let indexValidation: MigrationIndexValidationResult
    public let resolutionAudit: MigrationResolutionAudit?
}

/// CLI/API view of the newly prepared candidate. The persisted record-3 review
/// is the publication authority; this value is only a compatibility projection.
public struct MigrationPreparedReview: Encodable {
    public let recordFormatVersion: Int
    public let reviewID: String
    public let sourceRef: String
    public let sourceOID: String
    public let sourceTreeOID: String
    public let sourceCanonicalRevision: String
    public let sourceCanonicalIdentity: String
    public let sourceFormatVersion: Int
    public let targetFormatVersion: Int
    public let sourceDocumentRevision: Int
    public let candidateDocumentRevision: Int
    public let classification: MigrationClassification
    public let edgePath: [String]
    public let receipts: [MigrationEdgeReceipt]
    public let edgeResolutionAudits: [MigrationPreparedEdgeResolutionAudit]
    public let candidateOID: String
    public let candidateTreeOID: String
    public let retentionRef: String
    public let changedPaths: [String]
    public let diffNameStatus: String
    public let diffStat: String
    public let validation: MigrationValidationResult
    public let indexValidation: MigrationIndexValidationResult
    public let resolutionAudit: MigrationResolutionAudit?

    init(_ review: MigrationComposedReviewPackage) {
        recordFormatVersion = review.recordFormatVersion
        reviewID = review.reviewID
        sourceRef = review.sourceRef
        sourceOID = review.sourceOID
        sourceTreeOID = review.sourceTreeOID
        sourceCanonicalRevision = review.sourceCanonicalRevision
        sourceCanonicalIdentity = review.sourceCanonicalIdentity
        sourceFormatVersion = review.sourceFormatVersion
        targetFormatVersion = review.targetFormatVersion
        sourceDocumentRevision = review.sourceDocumentRevision
        candidateDocumentRevision = review.candidateDocumentRevision
        classification = review.classification
        edgePath = review.edgePath
        receipts = review.receipts
        edgeResolutionAudits = review.edgeResolutionAudits.map(MigrationPreparedEdgeResolutionAudit.init)
        candidateOID = review.candidateOID
        candidateTreeOID = review.candidateTreeOID
        retentionRef = review.retentionRef
        changedPaths = review.changedPaths
        diffNameStatus = review.diffNameStatus
        diffStat = review.diffStat
        validation = review.validation
        indexValidation = review.indexValidation
        resolutionAudit = review.edgeResolutionAudits.first(where: { $0.edgeID == "1->2" }).map {
            MigrationResolutionAudit(manifest: $0.manifest, decisions: $0.decisions, losses: $0.losses)
        }
    }
}

public struct MigrationPreparedEdgeResolutionAudit: Encodable {
    public let edgeID: String
    public let manifest: MigrationResolutionManifest
    public let decisions: [MigrationResolutionDecision]
    public let losses: [MigrationResolutionLoss]

    init(_ audit: MigrationComposedEdgeResolutionAudit) {
        edgeID = audit.edgeID
        manifest = audit.manifest
        decisions = audit.decisions
        losses = audit.losses
    }
}

enum MigrationPreparationStep {
    case afterTransform(URL)
    case beforeCurrentValidation(URL)
    case beforeIndexValidation(URL)
    case beforeRetention(URL)
}

public final class MigrationCandidatePreparer {
    private let hook: ((MigrationPreparationStep) throws -> Void)?
    public init() { hook = nil }
    init(hook: @escaping (MigrationPreparationStep) throws -> Void) { self.hook = hook }

    public func resolutionReport(repository sourceRoot: URL) throws -> MigrationResolutionReport {
        let root = sourceRoot.standardizedFileURL
        return try WorktreeCoordinator(root: root).withReadyExclusive {
            let source = try sourceObservation(at: root, allowResolution: true)
            let files = try MigrationRepositoryInput.load(from: root)
            guard CanonicalByteIdentity.compute(files: files.files) == source.identity else {
                throw MigrationPreparationError.staleSource
            }
            return try MigrationRegistry.resolutionReport(files, sourceBinding: binding(source))
        }
    }

    public func prepare(repository sourceRoot: URL,
                        resolution: MigrationResolutionManifest? = nil) throws -> MigrationPreparedReview {
        MigrationPreparedReview(try prepareCandidate(repository: sourceRoot, resolution: resolution))
    }

    func prepareComposed(repository sourceRoot: URL,
                         resolution: MigrationResolutionManifest? = nil) throws -> MigrationComposedReviewPackage {
        try prepareCandidate(repository: sourceRoot, resolution: resolution)
    }

    private func prepareCandidate(repository sourceRoot: URL,
                                  resolution: MigrationResolutionManifest?) throws -> MigrationComposedReviewPackage {
        let sourceRoot = sourceRoot.standardizedFileURL
        let coordinator = WorktreeCoordinator(root: sourceRoot)
        let source = try coordinator.withReadyExclusive {
            try sourceObservation(at: sourceRoot, allowResolution: resolution != nil)
        }
        if let resolution, resolution.sourceBinding != binding(source) {
            throw MigrationResolutionFailure.staleSource
        }
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("hamii-migration-candidate-\(UUID().uuidString)", isDirectory: true)
        let candidateRoot = container.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        var worktreeAdded = false
        defer {
            if worktreeAdded { _ = try? git(sourceRoot, "worktree", "remove", "--force", candidateRoot.path) }
            try? FileManager.default.removeItem(at: container)
        }
        _ = try git(sourceRoot, "worktree", "add", "--detach", candidateRoot.path, source.oid)
        worktreeAdded = true
        guard try git(candidateRoot, "rev-parse", "HEAD") == source.oid else {
            throw MigrationPreparationError.invalidCandidate("Detached candidate base differs from source OID")
        }

        let historical = try MigrationRepositoryInput.load(from: candidateRoot)
        let analysis = try MigrationRegistry.analyze(historical)
        guard CanonicalByteIdentity.compute(files: historical.files) == source.identity else {
            throw MigrationPreparationError.staleSource
        }
        if resolution == nil {
            guard analysis.automaticCandidateEligible, analysis.classification == .losslessWithNormalization else {
                throw MigrationPreparationError.migrationUnavailable(analysis.diagnostics.map(\.blocker))
            }
        }
        let route = try MigrationRegistry.route(from: analysis.sourceVersion)
        if resolution != nil && analysis.sourceVersion != 1 {
            throw MigrationResolutionFailure.invalidManifest
        }
        let edgeResolutions = resolution.map {
            [MigrationEdgeResolutionInput(edgeID: "1->2", manifest: $0, sourceBinding: binding(source))]
        } ?? []
        let replay = try MigrationRouteReplay.run(historical, route: route, edgeResolutions: edgeResolutions)
        guard replay.receipts.count == route.edges.count,
              replay.receipts.allSatisfy({ $0.classification != .manual }) else {
            throw MigrationPreparationError.invalidCandidate("Route replay did not produce reviewed edge receipts")
        }
        let expected = changedPaths(before: historical.files, after: replay.finalFiles.files)
        guard !expected.isEmpty else { throw MigrationPreparationError.invalidCandidate("Migration produced no Canonical changes") }
        for path in expected {
            guard let bytes = replay.finalFiles.files[path] else {
                throw MigrationPreparationError.invalidCandidate("Migration removed Canonical path \(path)")
            }
            try bytes.write(to: candidateRoot.appendingPathComponent(path), options: .atomic)
        }
        try hook?(.afterTransform(candidateRoot))
        try requireActualChanges(expected, at: candidateRoot)
        try hook?(.beforeCurrentValidation(candidateRoot))

        // Actual Current Format parser, semantic validator and asset verifier.
        let candidateRepository = CanonicalRepository(root: candidateRoot)
        let precommit = try candidateRepository.withCoordinatedSnapshot { $0 }
        guard precommit.document.versions.document == MigrationRegistry.currentDocumentFormatVersion,
              precommit.document.revision == source.documentRevision else {
            throw MigrationPreparationError.invalidCandidate("Current Format or DocumentRevision changed unexpectedly")
        }
        try requireActualChanges(expected, at: candidateRoot)
        _ = try git(candidateRoot, ["add", "--"] + expected)
        let staged = try gitPaths(GitCommand.runData(at: candidateRoot, ["diff", "--cached", "--name-only", "-z"]))
        guard staged == expected else { throw MigrationPreparationError.unexpectedPaths(expected: expected, actual: staged) }
        _ = try git(candidateRoot, "-c", "user.name=hamii", "-c", "user.email=hamii@localhost",
                    "-c", "core.hooksPath=/dev/null", "commit", "--no-gpg-sign", "-m",
                    "Migrate hamii document format v\(analysis.sourceVersion) to v\(route.targetVersion)")
        let candidateOID = try git(candidateRoot, "rev-parse", "HEAD")
        let parents = try git(candidateRoot, "rev-list", "--parents", "-n", "1", candidateOID).split(separator: " ").map(String.init)
        guard parents == [candidateOID, source.oid] else { throw MigrationPreparationError.invalidCandidate("Candidate must have the exact source OID as its sole parent") }
        try requireClean(candidateRoot)
        let candidateTreeOID = try git(candidateRoot, "rev-parse", "HEAD^{tree}")
        let committed = try candidateRepository.withCoordinatedSnapshot { $0 }
        guard committed.identity == precommit.identity,
              committed.document.id == precommit.document.id,
              committed.document.revision == precommit.document.revision else {
            throw MigrationPreparationError.invalidCandidate("Committed candidate differs from validated Canonical snapshot")
        }
        let committedDiff = try gitPaths(GitCommand.runData(at: candidateRoot,
            ["diff", "--name-only", "-z", source.oid, candidateOID]))
        guard committedDiff == expected else {
            throw MigrationPreparationError.unexpectedPaths(expected: expected, actual: committedDiff)
        }

        try hook?(.beforeIndexValidation(candidateRoot))
        let calculator = GitCanonicalRevisionCalculator()
        let canonicalRevision = try calculator.current(at: candidateRoot)
        let index = try LocalIndex(projectRoot: candidateRoot, documentID: committed.document.id,
                                   revisionCalculator: calculator, storageRoot: container.appendingPathComponent("indexes"))
        let generation = try index.rebuild(from: committed, canonicalRevision: canonicalRevision)
        guard try index.assertCurrent(documentID: committed.document.id,
                                      revision: committed.document.revision,
                                      expectedSourceIdentity: committed.identity) == generation,
              try calculator.current(at: candidateRoot) == canonicalRevision else {
            throw MigrationPreparationError.invalidCandidate("Fresh candidate Index does not match committed Canonical state")
        }
        try hook?(.beforeRetention(candidateRoot))
        let reviewID = UUID().uuidString.lowercased()
        let retentionRef = "refs/hamii/migration-candidates/\(reviewID)"
        let (nameStatus, stat) = try coordinator.withReadyExclusive { () throws -> (String, String) in
            try requireClean(sourceRoot)
            guard (try? git(sourceRoot, "symbolic-ref", "--quiet", "HEAD")) == source.ref,
                  (try? git(sourceRoot, "rev-parse", "HEAD")) == source.oid,
                  (try? git(sourceRoot, "rev-parse", "HEAD^{tree}")) == source.treeOID,
                  (try? GitCanonicalRevisionCalculator().current(at: sourceRoot)) == source.canonicalRevision else {
                throw MigrationPreparationError.staleSource
            }
            let nameStatus = try git(sourceRoot, "diff", "--name-status", source.oid, candidateOID)
            let stat = try git(sourceRoot, "diff", "--stat", source.oid, candidateOID)
            return (nameStatus, stat)
        }
        let edgeAudits: [MigrationComposedEdgeResolutionAudit]
        if let resolution {
            guard let receipt = replay.receipts.first(where: { $0.edgeID == "1->2" }) else {
                throw MigrationPreparationError.invalidCandidate("Resolved edge has no receipt")
            }
            edgeAudits = [MigrationComposedEdgeResolutionAudit(edgeID: receipt.edgeID,
                manifest: resolution, decisions: receipt.resolutionDecisions, losses: receipt.losses)]
        } else {
            edgeAudits = []
        }
        let validation = MigrationValidationResult(currentFormat: route.targetVersion,
            canonicalSnapshotIdentity: committed.identity.rawValue,
            documentID: committed.document.id.rawValue, documentRevision: committed.document.revision)
        let indexValidation = MigrationIndexValidationResult(
            sourceCanonicalIdentity: generation.sourceCanonicalIdentity.rawValue,
            indexGenerationID: generation.id.rawValue, canonicalRevision: canonicalRevision.rawValue)
        let classification: MigrationClassification = replay.receipts.contains(where: { $0.classification == .potentiallyLossy })
            ? .potentiallyLossy : replay.receipts.contains(where: { $0.classification == .losslessWithNormalization })
            ? .losslessWithNormalization : .lossless
        let review = MigrationComposedReviewPackage(recordFormatVersion: 3, reviewID: reviewID,
            sourceRef: source.ref, sourceOID: source.oid,
            sourceTreeOID: source.treeOID, sourceCanonicalRevision: source.canonicalRevision.rawValue,
            sourceCanonicalIdentity: source.identity.rawValue,
            sourceFormatVersion: analysis.sourceVersion, targetFormatVersion: route.targetVersion,
            sourceDocumentRevision: source.documentRevision,
            candidateDocumentRevision: committed.document.revision,
            classification: classification, receipts: replay.receipts,
            edgeResolutionAudits: edgeAudits,
            candidateOID: candidateOID, candidateTreeOID: candidateTreeOID,
            retentionRef: retentionRef, changedPaths: expected,
            diffNameStatus: nameStatus, diffStat: stat,
            validation: validation, indexValidation: indexValidation)
        try review.validateShape()
        try coordinator.withReadyExclusive {
            try requireClean(sourceRoot)
            guard try git(sourceRoot, "symbolic-ref", "--quiet", "HEAD") == source.ref,
                  try git(sourceRoot, "rev-parse", "HEAD") == source.oid,
                  try GitCanonicalRevisionCalculator().current(at: sourceRoot) == source.canonicalRevision,
                  CanonicalByteIdentity.compute(files: try MigrationRepositoryInput.load(from: sourceRoot).files) == source.identity else {
                throw MigrationPreparationError.staleSource
            }
            _ = try git(sourceRoot, "update-ref", retentionRef, candidateOID, String(repeating: "0", count: source.oid.count))
            do { try MigrationReviewStore(root: sourceRoot).writeComposed(review) }
            catch {
                _ = try? git(sourceRoot, "update-ref", "-d", retentionRef, candidateOID)
                throw error
            }
        }
        return review
    }

    private struct SourceObservation {
        let ref: String
        let oid: String
        let treeOID: String
        let documentRevision: Int
        let canonicalRevision: CanonicalRevision
        let identity: CanonicalSnapshotIdentity
    }

    private func sourceObservation(at root: URL, allowResolution: Bool = false) throws -> SourceObservation {
        guard let topLevel = try? git(root, "rev-parse", "--show-toplevel"),
              URL(fileURLWithPath: topLevel).resolvingSymlinksInPath().standardizedFileURL
                == root.resolvingSymlinksInPath().standardizedFileURL else { throw MigrationPreparationError.invalidWorktree }
        let ref: String
        do { ref = try git(root, "symbolic-ref", "--quiet", "HEAD") }
        catch { throw MigrationPreparationError.detachedSource }
        try requireClean(root)
        let oid = try git(root, "rev-parse", "HEAD")
        let tree = try git(root, "rev-parse", "HEAD^{tree}")
        let canonicalRevision = try GitCanonicalRevisionCalculator().current(at: root)
        let plan = try MigrationPreflight.plan(repository: root)
        if plan.state == "current" { throw MigrationPreparationError.alreadyCurrent }
        guard plan.sourceDocumentFormatVersion == 1 || plan.sourceDocumentFormatVersion == 2,
              (plan.state == "migrationAvailable" && plan.classification == .losslessWithNormalization ||
               allowResolution && plan.sourceDocumentFormatVersion == 1 &&
                   plan.state == "requiresResolution") else {
            throw MigrationPreparationError.migrationUnavailable(plan.blockers)
        }
        let files = try MigrationRepositoryInput.load(from: root)
        let identity = CanonicalByteIdentity.compute(files: files.files)
        let manifest = try JSONSerialization.jsonObject(with: files.files["hamii.json"]!) as? [String: Any]
        guard let revision = manifest?["revision"] as? Int else {
            throw MigrationPreparationError.invalidCandidate("Historical manifest has no DocumentRevision")
        }
        return SourceObservation(ref: ref, oid: oid, treeOID: tree,
                                 documentRevision: revision, canonicalRevision: canonicalRevision,
                                 identity: identity)
    }

    private func binding(_ source: SourceObservation) -> MigrationResolutionSourceBinding {
        MigrationResolutionSourceBinding(sourceOID: source.oid,
            sourceCanonicalIdentity: source.identity.rawValue)
    }

    private func requireClean(_ root: URL) throws {
        guard try git(root, "status", "--porcelain=v1", "--untracked-files=all").isEmpty else {
            throw MigrationPreparationError.dirtySource
        }
    }

    private func requireActualChanges(_ expected: [String], at root: URL) throws {
        let changed = try gitPaths(GitCommand.runData(at: root, ["diff", "--name-only", "-z", "HEAD"]))
        let untracked = try gitPaths(GitCommand.runData(at: root, ["ls-files", "--others", "--exclude-standard", "-z"]))
        let actual = Array(Set(changed + untracked)).sorted()
        guard actual == expected else { throw MigrationPreparationError.unexpectedPaths(expected: expected, actual: actual) }
    }

    private func changedPaths(before: [String: Data], after: [String: Data]) -> [String] {
        Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.sorted()
    }

    private func gitPaths(_ bytes: Data) throws -> [String] {
        try bytes.split(separator: 0).map { part in
            guard let path = String(data: Data(part), encoding: .utf8) else {
                throw MigrationPreparationError.invalidCandidate("Git path is not UTF-8")
            }
            return path
        }.sorted()
    }

    private func git(_ root: URL, _ args: String...) throws -> String { try GitCommand.run(at: root, args) }
    private func git(_ root: URL, _ args: [String]) throws -> String { try GitCommand.run(at: root, args) }
}
