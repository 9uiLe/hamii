import HamiiFormat
import HamiiMigrations

/// Replays installed edges over exact captured Canonical bytes. Git observation,
/// candidate publication, and Current-format validation remain with the caller.
struct MigrationRouteReplayResult {
    let finalFiles: MigrationFileSet
    let receipts: [MigrationEdgeReceipt]
    /// Existing review records describe one edge. They are not reinterpreted as
    /// aggregate results when a multi-edge route is installed.
    let singleEdgeCandidate: MigrationCandidate?
}

enum MigrationRouteReplay {
    static func run(_ original: MigrationFileSet, route: MigrationRoute,
                    resolution: MigrationResolutionManifest? = nil,
                    sourceBinding: MigrationResolutionSourceBinding? = nil) throws -> MigrationRouteReplayResult {
        let sourceVersion = try MigrationRegistry.analyze(original, to: route.sourceVersion).sourceVersion
        guard sourceVersion == route.sourceVersion else {
            throw MigrationEdgeFailure.invalidInput("Route source differs from Canonical format marker")
        }
        guard resolution == nil || route.edges.contains(where: { $0.sourceVersion == 1 && $0.targetVersion == 2 }) else {
            throw MigrationResolutionFailure.invalidManifest
        }

        var files = original
        var receipts: [MigrationEdgeReceipt] = []
        var singleEdgeCandidate: MigrationCandidate?
        for edge in route.edges {
            let inputIdentity = CanonicalByteIdentity.compute(files: files.files).rawValue
            let candidate: MigrationCandidate
            switch (edge.sourceVersion, edge.targetVersion) {
            case (1, 2):
                if let resolution {
                    guard let sourceBinding,
                          sourceBinding.sourceCanonicalIdentity == inputIdentity else {
                        throw MigrationResolutionFailure.staleSource
                    }
                    candidate = try MigrationRegistry.transform(files, applying: resolution,
                        actualSourceBinding: sourceBinding)
                } else {
                    candidate = try MigrationRegistry.transform(files, to: edge.targetVersion)
                }
            default:
                throw MigrationEdgeFailure.noPath(source: edge.sourceVersion, target: edge.targetVersion)
            }
            guard candidate.edgePath == [edge.id], candidate.sourceVersion == edge.sourceVersion,
                  candidate.targetVersion == edge.targetVersion,
                  try MigrationRegistry.analyze(candidate.files, to: edge.targetVersion).sourceVersion == edge.targetVersion,
                  let classification = candidate.classification else {
                throw MigrationEdgeFailure.invalidInput("Installed edge result does not match selected route")
            }
            receipts.append(MigrationEdgeReceipt(edge: edge, inputIdentity: inputIdentity,
                outputIdentity: CanonicalByteIdentity.compute(files: candidate.files.files).rawValue,
                classification: classification, resolutionDecisions: candidate.resolutionDecisions,
                losses: candidate.losses))
            files = candidate.files
            if route.edges.count == 1 { singleEdgeCandidate = candidate }
        }
        try MigrationReceiptChain.validate(receipts, for: route,
            sourceIdentity: CanonicalByteIdentity.compute(files: original.files).rawValue,
            finalIdentity: CanonicalByteIdentity.compute(files: files.files).rawValue)
        return MigrationRouteReplayResult(finalFiles: files, receipts: receipts,
                                          singleEdgeCandidate: singleEdgeCandidate)
    }
}
