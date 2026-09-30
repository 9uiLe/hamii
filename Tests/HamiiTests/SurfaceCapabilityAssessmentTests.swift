import XCTest
import HamiiApplication
import HamiiCore

final class SurfaceCapabilityAssessmentTests: XCTestCase {
    private func project(root: Layer) -> (Document, AppSurface) {
        var document = Document(name: "Assessment")
        let scopeID = document.scopes[0].id
        let screen = Screen(id: EntityID("screen_main"), name: "Main", scopeID: scopeID, root: root)
        let target = Target(id: EntityID("target_macos"), platform: .macOS, framework: .swiftUI)
        let surface = AppSurface(id: EntityID("surface_main"), targetID: target.id, device: "Mac", runtime: "macOS 27", buildEnvironment: "macOS SDK", screenID: screen.id, architectureScopeID: scopeID)
        document.screens = [screen]
        document.targets = [target]
        document.pages = [Page(id: EntityID("page_main"), name: "Screens", surfaces: [surface])]
        return (document, surface)
    }

    private func declaration(_ key: CapabilityKey, _ support: CapabilitySupport, targetID: EntityID = EntityID("target_macos")) -> CapabilityDeclaration {
        CapabilityDeclaration(targetID: targetID, key: key, support: support)
    }

    func testAssessmentMatchesSharedCoreReportAndPlanner() throws {
        let button = Layer(id: EntityID("button_edit"), name: "Edit", payload: .button(ButtonLayerPayload(label: "Edit", emittedEvent: "edit")))
        let (initialDocument, surface) = project(root: button)
        var document = initialDocument
        document.capabilityDeclarations = [
            declaration(CapabilityKeys.legacyButton, .exact),
            declaration(CapabilityKeys.buttonEventEmit, .externalIntegrationRequired)
        ]
        let assessment = try SurfaceCapabilityAssessmentService.assess(document: document, surfaceID: surface.id)
        XCTAssertEqual(assessment.surfaceID, surface.id)
        XCTAssertEqual(assessment.screenID, surface.screenID)
        XCTAssertEqual(assessment.targetID, surface.targetID)
        XCTAssertEqual(assessment.lossReport, NativePreviewCapabilityAnalysis.report(screen: document.screens[0], document: document, surface: surface, target: document.targets[0]))
        let plan = TargetPlanner.plan(surface: surface, document: document)
        XCTAssertEqual(assessment.previewPlan.surfaceID, plan.surfaceID)
        XCTAssertEqual(assessment.previewPlan.targetID, plan.targetID)
        XCTAssertEqual(assessment.previewPlan.screenID, plan.screenID)
        XCTAssertEqual(assessment.previewPlan.diagnostics, plan.diagnostics)
        XCTAssertEqual(assessment.previewPlan.canPreview, plan.canPreview)
        XCTAssertEqual(assessment.lossReport.items.map(\.loss), [.none, .externalIntegration])
        XCTAssertFalse(assessment.previewPlan.canPreview)
    }

    func testMissingDeclarationAndApproximationRemainVisible() throws {
        let root = Layer(id: EntityID("text_hello"), name: "Hello", payload: .text(TextLayerPayload(value: "Hello")))
        let (initialDocument, surface) = project(root: root)
        var document = initialDocument
        let missing = try SurfaceCapabilityAssessmentService.assess(document: document, surfaceID: surface.id)
        XCTAssertEqual(missing.lossReport.items[0].support, .unsupported)
        XCTAssertEqual(missing.lossReport.items[0].loss, .unsupported)
        XCTAssertFalse(missing.lossReport.items[0].allowed)

        document.capabilityDeclarations = [declaration(CapabilityKeys.textVisual, .approximate)]
        let denied = try SurfaceCapabilityAssessmentService.assess(document: document, surfaceID: surface.id)
        XCTAssertEqual(denied.lossReport.items[0].loss, .approvalRequired)
        XCTAssertFalse(denied.lossReport.items[0].allowed)
        let approved = try SurfaceCapabilityAssessmentService.assess(document: document, surfaceID: surface.id, approvedApproximationKeys: [CapabilityKeys.textVisual])
        XCTAssertEqual(approved.lossReport.items[0].loss, .approvedApproximation)
        XCTAssertTrue(approved.lossReport.items[0].allowed)
        XCTAssertEqual(approved.lossReport.items.count, 1)
        XCTAssertEqual(approved.previewPlan.canPreview, TargetPlanner.plan(surface: surface, document: document, approvedApproximationKeys: [CapabilityKeys.textVisual]).canPreview)
    }

    func testFixtureReadinessIsIndependentOfCapabilityAllowance() throws {
        let root = Layer(id: EntityID("text_name"), name: "Name", payload: .text(TextLayerPayload(binding: "user.name")))
        let (initialDocument, surface) = project(root: root)
        var document = initialDocument
        document.capabilityDeclarations = [
            declaration(CapabilityKeys.textVisual, .exact),
            declaration(CapabilityKeys.fixtureBinding, .exact)
        ]
        let assessment = try SurfaceCapabilityAssessmentService.assess(document: document, surfaceID: surface.id)
        XCTAssertTrue(assessment.lossReport.allowed)
        XCTAssertFalse(assessment.previewPlan.canPreview)
        XCTAssertTrue(assessment.previewPlan.diagnostics.contains { $0.rule == "preview.fixture" })
    }

    func testExplicitSurfaceIdentityAndMissingReferences() throws {
        let root = Layer(id: EntityID("text_hello"), name: "Hello", payload: .text(TextLayerPayload(value: "Hello")))
        let (initialDocument, first) = project(root: root)
        var document = initialDocument
        let secondTarget = Target(id: EntityID("target_second"), platform: .macOS, framework: .swiftUI)
        let second = AppSurface(id: EntityID("surface_second"), targetID: secondTarget.id, device: "Mac", runtime: "macOS 27", buildEnvironment: "macOS SDK", screenID: first.screenID, architectureScopeID: first.architectureScopeID)
        document.targets.append(secondTarget)
        document.pages[0].surfaces.append(second)
        document.capabilityDeclarations = [
            declaration(CapabilityKeys.legacyText, .exact),
            declaration(CapabilityKeys.textVisual, .unsupported, targetID: secondTarget.id)
        ]
        let firstAssessment = try SurfaceCapabilityAssessmentService.assess(document: document, surfaceID: first.id)
        let secondAssessment = try SurfaceCapabilityAssessmentService.assess(document: document, surfaceID: second.id)
        XCTAssertTrue(firstAssessment.lossReport.allowed)
        XCTAssertFalse(secondAssessment.lossReport.allowed)
        XCTAssertEqual(firstAssessment.lossReport.profile.targetID, first.targetID)
        XCTAssertEqual(secondAssessment.lossReport.profile.targetID, second.targetID)

        XCTAssertThrowsError(try SurfaceCapabilityAssessmentService.assess(document: document, surfaceID: EntityID("missing"))) {
            XCTAssertEqual($0 as? SurfaceCapabilityAssessmentError, .surfaceNotFound(EntityID("missing")))
        }
        document.pages[0].surfaces[0].screenID = EntityID("missing_screen")
        XCTAssertThrowsError(try SurfaceCapabilityAssessmentService.assess(document: document, surfaceID: first.id)) {
            XCTAssertEqual($0 as? SurfaceCapabilityAssessmentError, .screenNotFound(EntityID("missing_screen")))
        }
        document.pages[0].surfaces[0].screenID = first.screenID
        document.pages[0].surfaces[0].targetID = EntityID("missing_target")
        XCTAssertThrowsError(try SurfaceCapabilityAssessmentService.assess(document: document, surfaceID: first.id)) {
            XCTAssertEqual($0 as? SurfaceCapabilityAssessmentError, .targetNotFound(EntityID("missing_target")))
        }
    }
}
