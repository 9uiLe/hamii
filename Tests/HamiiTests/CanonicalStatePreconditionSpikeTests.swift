import XCTest
import HamiiCore
import HamiiPreviewProtocol

final class CanonicalStatePreconditionSpikeTests: XCTestCase {
    func testRevisionOnlyPreviewGateAcceptsUnknownSameRevisionState() {
        // The gate receives only an integer. Two distinct Canonical observations
        // with revision 3 are indistinguishable to this current protocol.
        let oldObservationRevision = 3
        let differentCurrentObservationRevision = 3
        let patch = PreviewPatch(
            documentID: EntityID("doc"), surfaceID: EntityID("surface"),
            baseRevision: oldObservationRevision, revision: 4,
            boundary: .instantPatch,
            changes: [PreviewChange(layerID: EntityID("layer"), path: "text", value: "Old client")]
        )
        let result = PreviewRevisionGate.accept(patch, after: differentCurrentObservationRevision)
        XCTAssertTrue(result.accepted)
    }
}
