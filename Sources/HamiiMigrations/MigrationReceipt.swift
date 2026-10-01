/// Evidence for one exact edge application. The caller supplies Canonical byte
/// identities from captured input/output file sets; this pure migration module
/// does not acquire a repository snapshot or choose an identity algorithm.
public struct MigrationEdgeReceipt: Codable, Equatable {
    public let sourceVersion: Int
    public let targetVersion: Int
    public let edgeID: String
    public let inputIdentity: String
    public let outputIdentity: String
    public let classification: MigrationClassification
    public let resolutionDecisions: [MigrationResolutionDecision]
    public let losses: [MigrationResolutionLoss]

    public init(edge: MigrationEdge, inputIdentity: String, outputIdentity: String,
                classification: MigrationClassification,
                resolutionDecisions: [MigrationResolutionDecision],
                losses: [MigrationResolutionLoss]) {
        sourceVersion = edge.sourceVersion
        targetVersion = edge.targetVersion
        edgeID = edge.id
        self.inputIdentity = inputIdentity
        self.outputIdentity = outputIdentity
        self.classification = classification
        self.resolutionDecisions = resolutionDecisions
        self.losses = losses
    }
}

/// Checks the route's structural and identity chain. Publication must also
/// recompute each edge from the original source and compare exact final bytes.
public enum MigrationReceiptChain {
    public static func validate(_ receipts: [MigrationEdgeReceipt], for route: MigrationRoute,
                                sourceIdentity: String, finalIdentity: String) throws {
        guard !sourceIdentity.isEmpty, !finalIdentity.isEmpty,
              receipts.count == route.edges.count else {
            throw MigrationEdgeFailure.invalidReceipt("Receipt count or endpoint identity is invalid")
        }
        if route.edges.isEmpty {
            guard sourceIdentity == finalIdentity else {
                throw MigrationEdgeFailure.invalidReceipt("A no-op route cannot change Canonical identity")
            }
            return
        }
        var expectedInput = sourceIdentity
        for (edge, receipt) in zip(route.edges, receipts) {
            guard receipt.sourceVersion == edge.sourceVersion,
                  receipt.targetVersion == edge.targetVersion,
                  receipt.edgeID == edge.id,
                  receipt.inputIdentity == expectedInput,
                  !receipt.outputIdentity.isEmpty else {
                throw MigrationEdgeFailure.invalidReceipt("Edge identity or ordered receipt chain is invalid")
            }
            expectedInput = receipt.outputIdentity
        }
        guard expectedInput == finalIdentity else {
            throw MigrationEdgeFailure.invalidReceipt("Final receipt does not identify the final Canonical bytes")
        }
    }
}
