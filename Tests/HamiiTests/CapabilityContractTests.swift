import Foundation
import XCTest
import HamiiCore

final class CapabilityContractTests: XCTestCase {
    private func fixture(root: Layer, navigation: NavigationConfiguration? = nil) -> (Document, AppSurface) {
        var document = Document(name: "Capability contract")
        let scope = document.scopes[0].id
        let target = Target(id: EntityID("target_macos"), platform: .macOS, framework: .swiftUI)
        document.targets = [target]
        var screen = Screen(id: EntityID("screen_main"), name: "Main", scopeID: scope, root: root)
        screen.navigation = navigation
        document.screens = [screen]
        let surface = AppSurface(id: EntityID("surface_main"), targetID: target.id, device: "Mac", runtime: "macOS 27", buildEnvironment: "macOS SDK", screenID: screen.id, architectureScopeID: scope)
        return (document, surface)
    }

    private func declare(_ keys: [CapabilityKey], in document: inout Document, support: CapabilitySupport = .exact) {
        let targetID = document.targets[0].id
        document.capabilityDeclarations += keys.map { CapabilityDeclaration(targetID: targetID, key: $0, support: support) }
    }

    func testNativePreviewCatalogAppliesOnlyToVerifiedTargetProfile() {
        let root = Layer(id: EntityID("layer_text"), name: "Text", payload: .text(TextLayerPayload(value: "Hello")))
        let (initial, initialSurface) = fixture(root: root)
        var document = initial
        declare([CapabilityKeys.textVisual], in: &document)
        let macReport = NativePreviewCapabilityAnalysis.report(
            screen: document.screens[0], document: document, surface: initialSurface, target: document.targets[0]
        )
        XCTAssertTrue(macReport.consumerApplicable)
        XCTAssertTrue(macReport.allowed)
        XCTAssertEqual(macReport.items.map(\.loss), [.none])
        XCTAssertTrue(TargetPlanner.plan(surface: initialSurface, document: document).canPreview)
        XCTAssertEqual(NativePreviewCapabilityCatalog.applicableProfiles, [
            CapabilityConsumerProfile(platform: .macOS, framework: .swiftUI)
        ])

        for (platform, framework) in [
            (Platform.iOS, Framework.swiftUI),
            (.macOS, .uiKit),
            (.android, .jetpackCompose),
            (.macOS, .composeMultiplatform)
        ] {
            document.targets[0].platform = platform
            document.targets[0].framework = framework
            var surface = initialSurface
            surface.runtime = "\(platform.rawValue) 27"
            XCTAssertEqual(DocumentValidator.validate(document), [])
            let report = NativePreviewCapabilityAnalysis.report(
                screen: document.screens[0], document: document, surface: surface, target: document.targets[0],
                approvedApproximationKeys: [CapabilityKeys.textVisual]
            )
            XCTAssertFalse(NativePreviewCapabilityCatalog.isApplicable(to: report.profile))
            XCTAssertFalse(report.consumerApplicable)
            XCTAssertFalse(report.allowed)
            XCTAssertEqual(report.items.map(\.support), [.unsupported])
            XCTAssertEqual(report.items.map(\.loss), [.unsupported])
            XCTAssertEqual(report.items[0].reason, NativePreviewCapabilityCatalog.profileUnavailableReason)
            let plan = TargetPlanner.plan(surface: surface, document: document, approvedApproximationKeys: [CapabilityKeys.textVisual])
            XCTAssertFalse(plan.canPreview)
            XCTAssertEqual(plan.diagnostics.filter { $0.rule == "preview.targetProfile" }.count, 1)
            XCTAssertEqual(plan.diagnostics.filter { $0.rule == "capability.unsupported" }.count, 0)
        }

        document.capabilityDeclarations[0].support = .approximate
        let blockedApproximation = NativePreviewCapabilityAnalysis.report(
            screen: document.screens[0], document: document, surface: initialSurface, target: document.targets[0],
            approvedApproximationKeys: [CapabilityKeys.textVisual]
        )
        XCTAssertFalse(blockedApproximation.allowed)
        XCTAssertEqual(blockedApproximation.items.map(\.loss), [.unsupported])

        document.capabilityDeclarations = []
        let missing = NativePreviewCapabilityAnalysis.report(
            screen: document.screens[0], document: document, surface: initialSurface, target: document.targets[0]
        )
        XCTAssertFalse(missing.allowed)
        XCTAssertEqual(missing.items.map(\.loss), [.unsupported])

        // An empty requirement set cannot make an inapplicable consumer current.
        let empty = CapabilityEvaluator.evaluate(
            requirements: [], profile: blockedApproximation.profile,
            declarations: document.capabilityDeclarations,
            catalog: NativePreviewCapabilityCatalog.catalog(for: blockedApproximation.profile)
        )
        XCTAssertFalse(empty.allowed)
    }

    func testExtractorFindsCurrentIRSemanticsWithoutTargetPolicy() throws {
        let tokenID = EntityID("token_space")
        let assetID = EntityID("asset_symbol")
        let componentID = EntityID("component_label")
        let root = Layer(id: EntityID("layer_root"), name: "Root", payload: .stack, children: [
            Layer(id: EntityID("layer_text"), name: "Greeting", payload: .text(TextLayerPayload(value: "Guest", binding: "user.name"))),
            Layer(id: EntityID("layer_button"), name: "Edit", payload: .button(ButtonLayerPayload(label: "Edit", emittedEvent: "edit"))),
            Layer(id: EntityID("layer_image"), name: "Avatar", payload: .image(ImageLayerPayload(assetID: assetID))),
            Layer(id: EntityID("layer_instance"), name: "Badge", payload: .componentInstance(ComponentInstanceLayerPayload(instance: ComponentInstance(definitionID: componentID))))
        ], layout: Layout(axis: .vertical, spacingTokenID: tokenID), effects: [.padding(tokenID: tokenID)])
        let navigation = NavigationConfiguration.system(SystemNavigation(title: "Profile", toolbarItems: [SystemToolbarItem(id: EntityID("toolbar_edit"), title: "Edit", emittedEvent: "edit")]))
        var (document, surface) = fixture(root: root, navigation: navigation)
        let scope = document.scopes[0].id
        document.tokens = [DesignToken(id: tokenID, name: "spacing", kind: .spacing, ownerScopeID: scope, value: .literal("12"))]
        document.assets = [Asset(id: assetID, name: "person", ownerScopeID: scope, mediaType: "image/system", source: .system(name: "person"))]
        document.components = [ComponentDefinition(id: componentID, name: "Badge", ownerScopeID: scope, root: Layer(id: EntityID("component_text"), name: "Text", payload: .text(TextLayerPayload(value: "VIP"))))]
        XCTAssertEqual(DocumentValidator.validate(document), [])
        let extracted = SemanticRequirementExtractor.extract(screen: document.screens[0], document: document)
        XCTAssertEqual(extracted.diagnostics, [])
        XCTAssertEqual(extracted.requirements.map(\.key), [
            CapabilityKeys.stackContainer, CapabilityKeys.spacingToken, CapabilityKeys.paddingEffect,
            CapabilityKeys.textVisual, CapabilityKeys.fixtureBinding, CapabilityKeys.bindingFallback,
            CapabilityKeys.buttonVisual, CapabilityKeys.buttonEventEmit, CapabilityKeys.imageVisual, CapabilityKeys.systemAssetMapping,
            CapabilityKeys.componentInstance, CapabilityKeys.textVisual,
            CapabilityKeys.systemNavigation, CapabilityKeys.navigationTitle, CapabilityKeys.systemToolbar, CapabilityKeys.toolbarEventEmit
        ])
        XCTAssertEqual(extracted.requirements.first(where: { $0.key == CapabilityKeys.toolbarEventEmit })?.sourceEntityID, EntityID("toolbar_edit"))
        XCTAssertEqual(extracted.requirements.first(where: { $0.key == CapabilityKeys.systemAssetMapping })?.sourceEntityID, EntityID("layer_image"))
        XCTAssertEqual(CapabilityProfile(target: document.targets[0], surface: surface).runtime, "macOS 27")
        declare([
            CapabilityKeys.legacyStack, CapabilityKeys.legacyText, CapabilityKeys.legacyButton,
            CapabilityKeys.legacyImage, CapabilityKeys.legacyInstance, CapabilityKeys.legacySpacing, CapabilityKeys.paddingEffect,
            CapabilityKeys.buttonEventEmit, CapabilityKeys.fixtureBinding, CapabilityKeys.bindingFallback,
            CapabilityKeys.systemAssetMapping, CapabilityKeys.legacySystemNavigation,
            CapabilityKeys.navigationTitle, CapabilityKeys.systemToolbar, CapabilityKeys.toolbarEventEmit
        ], in: &document)
        XCTAssertTrue(TargetPlanner.plan(surface: surface, document: document).canPreview)
        surface.runtime = "macOS 26"
        XCTAssertEqual(SemanticRequirementExtractor.extract(screen: document.screens[0], document: document).requirements, extracted.requirements)
    }

    func testEvaluatorFailsClosedAndRetainsApprovedApproximationLoss() throws {
        let (document, surface) = fixture(root: Layer(id: EntityID("layer_root"), name: "Root", payload: .stack))
        let profile = CapabilityProfile(target: document.targets[0], surface: surface)
        let id = EntityID("layer_root")
        let keys: [CapabilityKey] = [CapabilityKeys.stackContainer, CapabilityKeys.buttonVisual, CapabilityKeys.buttonEventEmit, CapabilityKeys.textVisual, CapabilityKeys.overlayVisual, CapabilityKeys.remoteAssetFetch]
        let requirements = keys.map { SemanticRequirement(key: $0, sourceEntityID: id) }
        let declarations = [
            CapabilityDeclaration(targetID: profile.targetID, key: CapabilityKeys.legacyStack, support: .portable),
            CapabilityDeclaration(targetID: profile.targetID, key: CapabilityKeys.legacyButton, support: .exact),
            CapabilityDeclaration(targetID: profile.targetID, key: CapabilityKeys.buttonEventEmit, support: .externalIntegrationRequired),
            CapabilityDeclaration(targetID: profile.targetID, key: CapabilityKeys.legacyOverlay, support: .approximate),
            CapabilityDeclaration(targetID: profile.targetID, key: CapabilityKeys.remoteAssetFetch, support: .exact)
        ]
        let catalog = NativePreviewCapabilityCatalog.catalog
        let denied = CapabilityEvaluator.evaluate(requirements: requirements, profile: profile, declarations: declarations, catalog: catalog)
        XCTAssertFalse(denied.allowed)
        XCTAssertEqual(denied.items.map(\.support), [.portable, .exact, .externalIntegrationRequired, .unsupported, .approximate, .unsupported])
        XCTAssertEqual(denied.items.map(\.loss), [.none, .none, .externalIntegration, .unsupported, .approvalRequired, .unsupported])
        XCTAssertEqual(denied.items.map(\.requirement.sourceEntityID), Array(repeating: id, count: keys.count))
        let approved = CapabilityEvaluator.evaluate(requirements: requirements, profile: profile, declarations: declarations, approvedApproximationKeys: [CapabilityKeys.legacyOverlay], catalog: catalog)
        XCTAssertEqual(approved.items[4].support, .approximate)
        XCTAssertTrue(approved.items[4].allowed)
        XCTAssertEqual(approved.items[4].loss, .approvedApproximation)
        XCTAssertFalse(approved.allowed)
        let targetSpecific = CapabilityEvaluator.evaluate(requirements: [SemanticRequirement(key: CapabilityKeys.systemAssetMapping, sourceEntityID: id)], profile: profile, declarations: [CapabilityDeclaration(targetID: profile.targetID, key: CapabilityKeys.systemAssetMapping, support: .targetSpecific)], catalog: catalog)
        XCTAssertTrue(targetSpecific.allowed)
        let encoded = try JSONEncoder().encode(approved)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["allowed"] as? Bool, false)
        XCTAssertEqual(try JSONDecoder().decode(CapabilityLossReport.self, from: encoded), approved)
        let ambiguous = CapabilityEvaluator.evaluate(requirements: [SemanticRequirement(key: CapabilityKeys.buttonEventEmit, sourceEntityID: id)], profile: profile, declarations: [
            CapabilityDeclaration(targetID: profile.targetID, key: CapabilityKeys.buttonEventEmit, support: .exact),
            CapabilityDeclaration(targetID: profile.targetID, key: CapabilityKeys.buttonEventEmit, support: .unsupported)
        ], catalog: catalog)
        XCTAssertEqual(ambiguous.items[0].support, .unsupported)
        XCTAssertFalse(ambiguous.allowed)
    }

    func testPlannerRequiresIndependentButtonEventAndRejectsRemoteEvenIfDeclaredExact() {
        let button = Layer(id: EntityID("layer_button"), name: "Edit", payload: .button(ButtonLayerPayload(label: "Edit", emittedEvent: "edit")))
        var (document, surface) = fixture(root: button)
        declare([CapabilityKeys.legacyButton], in: &document)
        let first = TargetPlanner.plan(surface: surface, document: document)
        XCTAssertFalse(first.canPreview)
        XCTAssertTrue(first.diagnostics.contains { $0.rule == "capability.unsupported" && $0.entityID == button.id })
        let report = NativePreviewCapabilityAnalysis.report(screen: document.screens[0], document: document, surface: surface, target: document.targets[0])
        XCTAssertEqual(report.items.map(\.allowed), [true, false])
        declare([CapabilityKeys.buttonEventEmit], in: &document)
        XCTAssertTrue(TargetPlanner.plan(surface: surface, document: document).canPreview)

        let assetID = EntityID("asset_remote")
        document.assets = [Asset(id: assetID, name: "Remote", ownerScopeID: document.scopes[0].id, mediaType: "image/png", source: .remote(url: "https://example.com/image.png"))]
        document.screens[0].root = Layer(id: EntityID("layer_image"), name: "Image", payload: .image(ImageLayerPayload(assetID: assetID)))
        declare([CapabilityKeys.legacyImage, CapabilityKeys.remoteAssetFetch], in: &document)
        let remotePlan = TargetPlanner.plan(surface: surface, document: document)
        XCTAssertFalse(remotePlan.canPreview)
        XCTAssertTrue(remotePlan.diagnostics.contains { $0.rule == "preview.asset" })
        document.assets[0].source = .system(name: "person")
        let unmappedSystem = TargetPlanner.plan(surface: surface, document: document)
        XCTAssertFalse(unmappedSystem.canPreview)
        XCTAssertTrue(unmappedSystem.diagnostics.contains { $0.rule == "capability.unsupported" })
        declare([CapabilityKeys.systemAssetMapping], in: &document)
        XCTAssertTrue(TargetPlanner.plan(surface: surface, document: document).canPreview)
        surface.runtime = "macOS 26"
        XCTAssertTrue(TargetPlanner.plan(surface: surface, document: document).canPreview)
    }

    func testNavigationTitleAndToolbarDoNotInheritContainerDeclaration() {
        let navigation = NavigationConfiguration.system(SystemNavigation(title: "Home", toolbarItems: [SystemToolbarItem(id: EntityID("toolbar_edit"), title: "Edit", emittedEvent: "edit")]))
        var (document, surface) = fixture(root: Layer(id: EntityID("layer_root"), name: "Root", payload: .stack), navigation: navigation)
        declare([CapabilityKeys.legacyStack, CapabilityKeys.legacySystemNavigation], in: &document)
        let first = TargetPlanner.plan(surface: surface, document: document)
        XCTAssertFalse(first.canPreview)
        let report = NativePreviewCapabilityAnalysis.report(screen: document.screens[0], document: document, surface: surface, target: document.targets[0])
        XCTAssertEqual(report.items.map(\.allowed), [true, true, false, false, false])
        declare([CapabilityKeys.navigationTitle, CapabilityKeys.systemToolbar, CapabilityKeys.toolbarEventEmit], in: &document)
        XCTAssertTrue(TargetPlanner.plan(surface: surface, document: document).canPreview)
        surface.runtime = "macOS 26"
        XCTAssertTrue(TargetPlanner.plan(surface: surface, document: document).canPreview)
    }

    func testUnsupportedNativeIntentCannotBeEnabledByDeclaration() {
        var root = Layer(id: EntityID("layer_root"), name: "Root", payload: .text(TextLayerPayload(value: "Hello")))
        root.nativeIntent = "customEffect"
        var (document, surface) = fixture(root: root)
        declare([CapabilityKeys.legacyText, CapabilityKeys.nativeIntent], in: &document)
        let plan = TargetPlanner.plan(surface: surface, document: document)
        XCTAssertFalse(plan.canPreview)
        XCTAssertTrue(plan.diagnostics.contains { $0.rule == "preview.nativeSemantics" })
        let report = NativePreviewCapabilityAnalysis.report(screen: document.screens[0], document: document, surface: surface, target: document.targets[0])
        XCTAssertEqual(report.items.last?.support, .unsupported)
        surface.runtime = "macOS 26"
        XCTAssertFalse(TargetPlanner.plan(surface: surface, document: document).canPreview)
    }

    func testScrollAndOverlayUseTheirBasicDeclarations() {
        let text = Layer(id: EntityID("layer_text"), name: "Text", payload: .text(TextLayerPayload(value: "Hello")))
        let overlay = Layer(id: EntityID("layer_overlay"), name: "Overlay", payload: .overlay, children: [text])
        let root = Layer(id: EntityID("layer_scroll"), name: "Scroll", payload: .scroll, children: [overlay])
        var (document, surface) = fixture(root: root)
        declare([CapabilityKeys.legacyScroll, CapabilityKeys.legacyOverlay, CapabilityKeys.legacyText], in: &document)
        XCTAssertTrue(TargetPlanner.plan(surface: surface, document: document).canPreview)
        surface.runtime = "macOS 26"
        XCTAssertTrue(TargetPlanner.plan(surface: surface, document: document).canPreview)
    }

    func testPreviewFixtureAvailabilityRemainsContextSpecific() throws {
        let root = Layer(id: EntityID("layer_text"), name: "Name", payload: .text(TextLayerPayload(binding: "user.name")))
        var (document, surface) = fixture(root: root)
        declare([CapabilityKeys.legacyText, CapabilityKeys.fixtureBinding], in: &document)
        let extraction = SemanticRequirementExtractor.extract(screen: document.screens[0], document: document)
        XCTAssertFalse(extraction.diagnostics.contains { $0.rule == "preview.fixture" })
        XCTAssertEqual(extraction.bindings.map(\.path), ["user.name"])
        XCTAssertTrue(TargetPlanner.plan(surface: surface, document: document).diagnostics.contains { $0.rule == "preview.fixture" })

        let fixtureJSON = #"{"id":{"rawValue":"fixture_user"},"name":"User","values":{"user.name":"Alice"},"assetBindings":{}}"#
        let fixture = try JSONDecoder().decode(PreviewFixture.self, from: Data(fixtureJSON.utf8))
        document.fixtures = [fixture]
        surface.fixtureID = fixture.id
        XCTAssertFalse(TargetPlanner.plan(surface: surface, document: document).diagnostics.contains { $0.rule == "preview.fixture" })

        document.screens[0].root.text = "Guest"
        surface.fixtureID = nil
        XCTAssertFalse(TargetPlanner.plan(surface: surface, document: document).diagnostics.contains { $0.rule == "preview.fixture" })
    }

    func testTargetPlanJSONShapeRemainsUnchanged() throws {
        let (document, surface) = fixture(root: Layer(id: EntityID("layer_root"), name: "Root", payload: .text(TextLayerPayload(value: "Hello"))))
        let plan = TargetPlanner.plan(surface: surface, document: document)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["surfaceID", "targetID", "screenID", "diagnostics"])
    }
}
