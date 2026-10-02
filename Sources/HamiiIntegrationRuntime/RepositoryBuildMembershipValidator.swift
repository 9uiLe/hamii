import Foundation
import HamiiIntegration

/// Revalidates a Product receipt and its source declarations before any build
/// membership acquisition. No protected acquisition path exists yet, so this
/// boundary cannot produce selected-build evidence.
enum RepositoryBuildMembershipValidator {
    static func validate(receipt: RepositoryProfileReceipt,
                         hamiiRoot: URL,
                         productRoot: URL,
                         selection: RepositoryBuildSelection) throws -> [RepositoryBuildEvidence] {
        // Keep stale Product and hamii observation failures as receipt failures.
        // A stale receipt must never become an apparently ordinary unavailable
        // build acquisition result.
        let replay = try RepositoryProfileRuntime.verify(receipt: receipt,
                                                         hamiiRoot: hamiiRoot,
                                                         productRoot: productRoot)
        guard let mappings = replay.repositoryMappingEvidence else {
            // Profile v1 has no source locator to which build evidence applies.
            return []
        }
        return mappings.sorted { $0.mappingKey < $1.mappingKey }.map { source in
            let sourceVerified = source.status == .verified &&
                source.scope == "pinnedSourceDeclaration" &&
                !(source.locator?.path ?? "").isEmpty &&
                !(source.sourceBlobOID ?? "").isEmpty
            return RepositoryBuildEvidence(
                mappingKey: source.mappingKey,
                status: .unverifiable,
                reason: sourceVerified ? "protectedBuildAcquisitionUnavailable" : "sourceNotVerified",
                productCommitOID: receipt.productCommitOID,
                sourcePath: sourceVerified ? source.locator?.path : nil,
                sourceBlobOID: sourceVerified ? source.sourceBlobOID : nil,
                requestedSelection: selection)
        }
    }
}
