import XCTest
import HamiiCore
import HamiiPreviewProtocol

final class CanonicalStatePreconditionSpikeTests: XCTestCase {
    func testPreviewGateRejectsUnknownSameRevisionState() {
        let oldObservationRevision = 3
        let differentCurrentObservationRevision = 3
        let oldState = ClientPrecondition("old")
        let currentState = ClientPrecondition("current")
        let patch = PreviewPatch(
            documentID: EntityID("doc"), surfaceID: EntityID("surface"),
            baseRevision: oldObservationRevision, revision: 4,
            baseState: oldState, newState: ClientPrecondition("next"),
            boundary: .instantPatch,
            changes: [PreviewChange(layerID: EntityID("layer"), path: "text", value: "Old client")]
        )
        let result = PreviewRevisionGate.accept(patch, after: differentCurrentObservationRevision, state: currentState)
        XCTAssertFalse(result.accepted)
        XCTAssertEqual(result.diagnostics.first?.rule, "preview.state")
    }
}
