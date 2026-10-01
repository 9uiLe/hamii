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

/// Resolution evidence belongs to the exact input of one installed edge, not
/// to the route's original source or a free-form payload shared across edges.
struct MigrationEdgeResolutionInput {
    let edgeID: String
    let manifest: MigrationResolutionManifest
    let sourceBinding: MigrationResolutionSourceBinding
}

enum MigrationRouteReplay {
    static func run(_ original: MigrationFileSet, route: MigrationRoute,
                    resolution: MigrationResolutionManifest? = nil,
                    sourceBinding: MigrationResolutionSourceBinding? = nil) throws -> MigrationRouteReplayResult {
        let edgeResolutions: [MigrationEdgeResolutionInput]
        if let resolution {
            guard let sourceBinding, route.edges.count == 1 else {
                throw MigrationResolutionFailure.invalidManifest
            }
            edgeResolutions = [MigrationEdgeResolutionInput(edgeID: route.edges[0].id,
                manifest: resolution, sourceBinding: sourceBinding)]
        } else {
            guard sourceBinding == nil else { throw MigrationResolutionFailure.invalidManifest }
            edgeResolutions = []
        }
        return try run(original, route: route, edgeResolutions: edgeResolutions)
    }

    static func run(_ original: MigrationFileSet, route: MigrationRoute,
                    edgeResolutions: [MigrationEdgeResolutionInput]) throws -> MigrationRouteReplayResult {
        let sourceVersion = try MigrationRegistry.analyze(original, to: route.sourceVersion).sourceVersion
        guard sourceVersion == route.sourceVersion else {
            throw MigrationEdgeFailure.invalidInput("Route source differs from Canonical format marker")
        }
        let routeEdges = Dictionary(uniqueKeysWithValues: route.edges.map { ($0.id, $0) })
        var resolutions: [String: MigrationEdgeResolutionInput] = [:]
        for input in edgeResolutions {
            guard let edge = routeEdges[input.edgeID],
                  resolutions.updateValue(input, forKey: input.edgeID) == nil,
                  input.manifest.formatVersion == 1,
                  input.manifest.sourceBinding == input.sourceBinding,
                  input.sourceBinding.sourceFormatVersion == edge.sourceVersion,
                  input.sourceBinding.targetFormatVersion == edge.targetVersion else {
                throw MigrationResolutionFailure.invalidManifest
            }
        }

        var files = original
        var receipts: [MigrationEdgeReceipt] = []
        var singleEdgeCandidate: MigrationCandidate?
        for edge in route.edges {
            let inputIdentity = CanonicalByteIdentity.compute(files: files.files).rawValue
            let resolution = resolutions[edge.id]
            let candidate: MigrationCandidate
            switch (edge.sourceVersion, edge.targetVersion) {
            case (1, 2):
                if let resolution {
                    guard resolution.sourceBinding.sourceCanonicalIdentity == inputIdentity else {
                        throw MigrationResolutionFailure.staleSource
                    }
                    candidate = try MigrationRegistry.transform(files, applying: resolution.manifest,
                        actualSourceBinding: resolution.sourceBinding)
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
