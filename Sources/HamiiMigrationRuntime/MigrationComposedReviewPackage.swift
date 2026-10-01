import Foundation
import HamiiMigrations

/// One final candidate reviewed across an exact ordered route. Legacy review
/// formats remain separate: their single-edge fields are never reinterpreted.
struct MigrationComposedReviewPackage: Codable {
    let recordFormatVersion: Int
    let reviewID: String
    let sourceRef: String
    let sourceOID: String
    let sourceTreeOID: String
    let sourceCanonicalRevision: String
    let sourceCanonicalIdentity: String
    let sourceFormatVersion: Int
    let targetFormatVersion: Int
    let sourceDocumentRevision: Int
    let candidateDocumentRevision: Int
    let classification: MigrationClassification
    let receipts: [MigrationEdgeReceipt]
    let edgeResolutionAudits: [MigrationComposedEdgeResolutionAudit]
    let candidateOID: String
    let candidateTreeOID: String
    let retentionRef: String
    let changedPaths: [String]
    let diffNameStatus: String
    let diffStat: String
    let validation: MigrationValidationResult
    let indexValidation: MigrationIndexValidationResult

    var edgePath: [String] { receipts.map(\.edgeID) }

    /// These are only review-shape checks. Publisher must replay from the exact
    /// source and compare the committed candidate bytes independently.
    func validateShape() throws {
        guard recordFormatVersion == 3,
              UUID(uuidString: reviewID)?.uuidString.lowercased() == reviewID,
              sourceRef.hasPrefix("refs/heads/"), sourceRef.count > "refs/heads/".count,
              !sourceOID.isEmpty, !sourceTreeOID.isEmpty, !candidateOID.isEmpty,
              !candidateTreeOID.isEmpty, !sourceCanonicalRevision.isEmpty,
              isIdentity(sourceCanonicalIdentity),
              sourceFormatVersion >= 1, targetFormatVersion > sourceFormatVersion,
              sourceDocumentRevision >= 0,
              candidateDocumentRevision == sourceDocumentRevision,
              !receipts.isEmpty,
              retentionRef == "refs/hamii/migration-candidates/\(reviewID)",
              !changedPaths.isEmpty, changedPaths == Array(Set(changedPaths)).sorted(),
              changedPaths.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("/") &&
                  !$0.split(separator: "/").contains("..") }),
              validation.currentFormat == targetFormatVersion,
              validation.documentRevision == candidateDocumentRevision,
              !validation.documentID.isEmpty,
              isIdentity(validation.canonicalSnapshotIdentity),
              indexValidation.sourceCanonicalIdentity == validation.canonicalSnapshotIdentity,
              !indexValidation.indexGenerationID.isEmpty,
              !indexValidation.canonicalRevision.isEmpty else {
            throw MigrationReviewStoreError.invalidRecord
        }
        var expectedVersion = sourceFormatVersion
        var expectedIdentity = sourceCanonicalIdentity
        var receiptIDs = Set<String>()
        for receipt in receipts {
            guard receipt.sourceVersion == expectedVersion,
                  receipt.targetVersion == expectedVersion + 1,
                  receipt.edgeID == "\(expectedVersion)->\(expectedVersion + 1)",
                  receiptIDs.insert(receipt.edgeID).inserted,
                  receipt.inputIdentity == expectedIdentity,
                  isIdentity(receipt.outputIdentity),
                  receipt.classification != .manual else {
                throw MigrationReviewStoreError.invalidRecord
            }
            expectedVersion = receipt.targetVersion
            expectedIdentity = receipt.outputIdentity
        }
        guard expectedVersion == targetFormatVersion,
              expectedIdentity == validation.canonicalSnapshotIdentity,
              classification == aggregateClassification(receipts),
              Set(edgeResolutionAudits.map(\.edgeID)).count == edgeResolutionAudits.count else {
            throw MigrationReviewStoreError.invalidRecord
        }
        let audits = Dictionary(uniqueKeysWithValues: edgeResolutionAudits.map { ($0.edgeID, $0) })
        guard edgeResolutionAudits.map(\.edgeID) == receipts.compactMap({
            audits[$0.edgeID] == nil ? nil : $0.edgeID
        }) else {
            throw MigrationReviewStoreError.invalidRecord
        }
        for receipt in receipts {
            if let audit = audits[receipt.edgeID] {
                guard audit.manifest.formatVersion >= 1,
                      !audit.manifest.sourceOID.isEmpty,
                      (receipt.inputIdentity != sourceCanonicalIdentity || audit.manifest.sourceOID == sourceOID),
                      audit.manifest.sourceCanonicalIdentity == receipt.inputIdentity,
                      audit.manifest.sourceFormatVersion == receipt.sourceVersion,
                      audit.manifest.targetFormatVersion == receipt.targetVersion,
                      audit.manifest.decisions == audit.decisions,
                      audit.decisions == receipt.resolutionDecisions,
                      audit.losses == receipt.losses else {
                    throw MigrationReviewStoreError.invalidRecord
                }
            } else if !receipt.resolutionDecisions.isEmpty {
                throw MigrationReviewStoreError.invalidRecord
            }
        }
        guard audits.keys.allSatisfy(receiptIDs.contains) else {
            throw MigrationReviewStoreError.invalidRecord
        }
    }

    private func aggregateClassification(_ receipts: [MigrationEdgeReceipt]) -> MigrationClassification {
        if receipts.contains(where: { $0.classification == .potentiallyLossy }) { return .potentiallyLossy }
        if receipts.contains(where: { $0.classification == .losslessWithNormalization }) { return .losslessWithNormalization }
        return .lossless
    }

    private func isIdentity(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }
}

struct MigrationComposedEdgeResolutionAudit: Codable {
    let edgeID: String
    let manifest: MigrationResolutionManifest
    let decisions: [MigrationResolutionDecision]
    let losses: [MigrationResolutionLoss]
}
