import Foundation
import XCTest
import HamiiApplication
import HamiiCore

final class SurfaceCapabilityContextTests: XCTestCase {
    private final class Repository: ProjectRepository, ProjectObservationVerifying {
        var document: Document
        var state = ClientPrecondition("state-0")
        var observationCount = 0
        var verificationCount = 0

        init(_ document: Document) { self.document = document }

        func observe() throws -> ProjectObservation {
            observationCount += 1
            return ProjectObservation(document: document, statePrecondition: state)
        }

        func commit(_ document: Document, expected: ProjectObservation) throws -> ProjectObservation {
            guard expected.statePrecondition == state else { throw AuthoringError.staleState }
            self.document = document
            state = ClientPrecondition("state-1")
            return try observe()
        }

        func verifyCurrent(_ expected: ClientPrecondition) throws {
            verificationCount += 1
            guard expected == state else { throw AuthoringError.staleState }
        }
    }

    private func fixture(root: Layer) -> (Document, AppSurface) {
        var document = Document(name: "Surface context")
        let scopeID = document.scopes[0].id
        let screen = Screen(id: EntityID("screen_main"), name: "Main", scopeID: scopeID, root: root)
        let target = Target(id: EntityID("target_main"), platform: .macOS, framework: .swiftUI)
        let surface = AppSurface(id: EntityID("surface_main"), targetID: target.id, device: "Mac", runtime: "macOS 27", buildEnvironment: "macOS SDK", screenID: screen.id, architectureScopeID: scopeID)
        document.screens = [screen]
        document.targets = [target]
        document.pages = [Page(id: EntityID("page_main"), name: "Main", surfaces: [surface])]
        return (document, surface)
    }

    private func declare(_ key: CapabilityKey, _ support: CapabilitySupport, in document: inout Document, targetID: EntityID = EntityID("target_main")) {
        document.capabilityDeclarations.append(CapabilityDeclaration(targetID: targetID, key: key, support: support))
    }

    func testProjectionMatchesAssessmentAndKeepsPreviewReadinessSeparate() throws {
        let root = Layer(id: EntityID("text_name"), name: "Name", payload: .text(TextLayerPayload(binding: "user.name")))
        let (initial, surface) = fixture(root: root)
        var document = initial
        declare(CapabilityKeys.textVisual, .exact, in: &document)
        declare(CapabilityKeys.fixtureBinding, .exact, in: &document)
        let repository = Repository(document)
        let service = ProjectContextService(repository: repository)
        let detail = try service.surfaceCapabilityDetail(surfaceID: surface.id, expectedState: repository.state)
        let assessment = try SurfaceCapabilityAssessmentService.assess(document: document, surfaceID: surface.id)
        XCTAssertEqual(detail.payload.surfaceID, assessment.surfaceID)
        XCTAssertEqual(detail.payload.screenID, assessment.screenID)
        XCTAssertEqual(detail.payload.profile, assessment.lossReport.profile)
        XCTAssertEqual(detail.payload.requirementCount, assessment.lossReport.items.count)
        XCTAssertEqual(detail.payload.capabilityAllowed, assessment.lossReport.allowed)
        XCTAssertEqual(detail.payload.losses.items, assessment.lossReport.items.filter { $0.loss != .none })
        XCTAssertEqual(detail.payload.previewReady, assessment.previewPlan.canPreview)
        XCTAssertEqual(detail.payload.previewDiagnostics.items, assessment.previewPlan.diagnostics)
        XCTAssertTrue(detail.payload.capabilityAllowed)
        XCTAssertFalse(detail.payload.previewReady)
        XCTAssertTrue(detail.payload.previewDiagnostics.items.contains { $0.rule == "preview.fixture" })

        let started = try ProjectContextReadSession.start(repository: repository)
        let sessionDetail = try started.session.surfaceCapabilityDetail(surfaceID: surface.id)
        XCTAssertEqual(sessionDetail, detail)
        XCTAssertEqual(started.initialSummary.observation, detail.observation)
        XCTAssertEqual(repository.observationCount, 2)
        XCTAssertEqual(repository.verificationCount, 1)
    }

    func testApproximationAndExternalIntegrationRemainLosses() throws {
        let root = Layer(id: EntityID("stack_root"), name: "Root", payload: .stack, children: [
            Layer(id: EntityID("text_one"), name: "One", payload: .text(TextLayerPayload(value: "One"))),
            Layer(id: EntityID("text_two"), name: "Two", payload: .text(TextLayerPayload(value: "Two")))
        ])
        let (initial, surface) = fixture(root: root)
        var document = initial
        declare(CapabilityKeys.stackContainer, .exact, in: &document)
        declare(CapabilityKeys.textVisual, .approximate, in: &document)
        let first = try ProjectContextService(repository: Repository(document))
            .surfaceCapabilityDetail(surfaceID: surface.id, expectedState: ClientPrecondition("state-0"))
        XCTAssertEqual(first.payload.losses.totalCount, 2)
        XCTAssertEqual(first.payload.losses.items.map(\.loss), [.approvalRequired, .approvalRequired])
        XCTAssertFalse(first.payload.capabilityAllowed)

        document.capabilityDeclarations.removeAll { $0.key == CapabilityKeys.textVisual }
        declare(CapabilityKeys.textVisual, .externalIntegrationRequired, in: &document)
        let second = try ProjectContextService(repository: Repository(document))
            .surfaceCapabilityDetail(surfaceID: surface.id, expectedState: ClientPrecondition("state-0"))
        XCTAssertEqual(second.payload.losses.items.map(\.loss), [.externalIntegration, .externalIntegration])
        XCTAssertFalse(second.payload.capabilityAllowed)
    }

    func testLossesAndDiagnosticsAreBoundedWithoutHidingCounts() throws {
        let children = (0..<105).map { index in
            Layer(id: EntityID("text_\(index)"), name: "Text \(index)", payload: .text(TextLayerPayload(value: "\(index)")))
        }
        let root = Layer(id: EntityID("stack_root"), name: "Root", payload: .stack, children: children)
        let (document, surface) = fixture(root: root)
        let detail = try ProjectContextService(repository: Repository(document))
            .surfaceCapabilityDetail(surfaceID: surface.id, expectedState: ClientPrecondition("state-0"))
        XCTAssertEqual(detail.payload.requirementCount, 106)
        XCTAssertEqual(detail.payload.losses.totalCount, 106)
        XCTAssertEqual(detail.payload.losses.items.count, 100)
        XCTAssertTrue(detail.payload.losses.truncated)
        XCTAssertGreaterThan(detail.payload.previewDiagnostics.totalCount, 100)
        XCTAssertEqual(detail.payload.previewDiagnostics.items.count, 100)
        XCTAssertTrue(detail.payload.previewDiagnostics.truncated)
    }

    func testExplicitSurfaceAndStaleObservation() throws {
        let root = Layer(id: EntityID("text_main"), name: "Main", payload: .text(TextLayerPayload(value: "Main")))
        let (initial, firstSurface) = fixture(root: root)
        var document = initial
        let otherTarget = Target(id: EntityID("target_other"), platform: .macOS, framework: .swiftUI)
        let otherSurface = AppSurface(id: EntityID("surface_other"), targetID: otherTarget.id, device: "Mac", runtime: "macOS 27", buildEnvironment: "macOS SDK", screenID: firstSurface.screenID, architectureScopeID: firstSurface.architectureScopeID)
        document.targets.append(otherTarget)
        document.pages[0].surfaces.append(otherSurface)
        declare(CapabilityKeys.textVisual, .exact, in: &document)
        declare(CapabilityKeys.textVisual, .unsupported, in: &document, targetID: otherTarget.id)
        let repository = Repository(document)
        let service = ProjectContextService(repository: repository)
        let first = try service.surfaceCapabilityDetail(surfaceID: firstSurface.id, expectedState: repository.state)
        let other = try service.surfaceCapabilityDetail(surfaceID: otherSurface.id, expectedState: repository.state)
        XCTAssertTrue(first.payload.capabilityAllowed)
        XCTAssertFalse(other.payload.capabilityAllowed)
        XCTAssertEqual(other.payload.profile.targetID, otherTarget.id)
        XCTAssertThrowsError(try service.surfaceCapabilityDetail(surfaceID: EntityID("missing"), expectedState: repository.state)) {
            guard case AuthoringError.notFound("missing") = $0 else { return XCTFail("Wrong error: \($0)") }
        }
        let old = repository.state
        let session = try ProjectContextReadSession.start(repository: repository).session
        repository.state = ClientPrecondition("state-1")
        XCTAssertThrowsError(try service.surfaceCapabilityDetail(surfaceID: firstSurface.id, expectedState: old)) {
            guard case AuthoringError.staleState = $0 else { return XCTFail("Wrong error: \($0)") }
        }
        XCTAssertThrowsError(try session.surfaceCapabilityDetail(surfaceID: firstSurface.id)) {
            guard case AuthoringError.staleState = $0 else { return XCTFail("Wrong error: \($0)") }
        }
    }
}
