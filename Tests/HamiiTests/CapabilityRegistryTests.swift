import XCTest
import HamiiCore
import HamiiGeneration

final class CapabilityRegistryTests: XCTestCase {
    func testBuiltInDefinitionsAndAliasesHaveOneMeaning() {
        XCTAssertTrue(CapabilityRegistry.validateDefinitions().isEmpty)
        XCTAssertEqual(CapabilityRegistry.definitions.count, CapabilityRegistry.semanticKeys.count)
        XCTAssertEqual(CapabilityRegistry.legacyAliases.count, CapabilityRegistry.legacyAliasKeys.count)
        XCTAssertTrue(CapabilityRegistry.semanticKeys.isDisjoint(with: CapabilityRegistry.legacyAliasKeys))
        XCTAssertEqual(BasicCapabilityAliases.map, CapabilityRegistry.legacyAliases)
        XCTAssertEqual(CapabilityRegistry.legacyAliases[CapabilityKeys.buttonVisual], CapabilityKeys.legacyButton)
        for key in [CapabilityKeys.buttonEventEmit, CapabilityKeys.fixtureBinding, CapabilityKeys.bindingFallback,
                    CapabilityKeys.remoteAssetFetch, CapabilityKeys.paddingEffect, CapabilityKeys.toolbarEventEmit] {
            XCTAssertNil(CapabilityRegistry.legacyAliases[key], "\(key) must require its own declaration")
        }

        let duplicate = CapabilityRegistry.validateDefinitions([
            .init(CapabilityKeys.textVisual, legacyAlias: CapabilityKeys.legacyText),
            .init(CapabilityKeys.textVisual, legacyAlias: CapabilityKeys.legacyText),
            .init(CapabilityKeys.legacyText)
        ])
        XCTAssertEqual(duplicate, [
            .duplicateSemanticKey(CapabilityKeys.textVisual),
            .duplicateLegacyAlias(CapabilityKeys.legacyText),
            .semanticLegacyCollision(CapabilityKeys.legacyText)
        ])
    }

    func testUnregisteredRequirementIsRetainedAndDiagnosed() {
        let requirement = SemanticRequirement(key: CapabilityKey("test.unregistered"), sourceEntityID: EntityID("layer_unknown"))
        XCTAssertEqual(CapabilityRegistry.validate(requirements: [requirement]), [
            Diagnostic("semantic.capabilityRegistry", "Unregistered built-in semantic capability test.unregistered", entityID: requirement.sourceEntityID)
        ])
    }

    func testCatalogValidationRejectsUnknownLegacyRuntimeAndAliasDrift() {
        let unknown = CapabilityKey("test.unregistered")
        XCTAssertEqual(CapabilityRegistry.validate(catalog: CapabilityCatalog(supportedKeys: [unknown])), [.unknownSupportedKey(unknown)])
        XCTAssertEqual(CapabilityRegistry.validate(catalog: CapabilityCatalog(supportedKeys: [CapabilityKeys.legacyText])),
                       [.legacyKeyAdvertisedAsSupported(CapabilityKeys.legacyText)])
        XCTAssertEqual(CapabilityRegistry.validate(catalog: CapabilityCatalog(
            supportedKeys: [CapabilityKeys.textVisual], runtimeSensitiveKeys: [CapabilityKeys.buttonVisual]
        )), [.runtimeSensitiveKeyNotSupported(CapabilityKeys.buttonVisual)])
        XCTAssertEqual(CapabilityRegistry.validate(catalog: CapabilityCatalog(
            supportedKeys: [CapabilityKeys.buttonVisual], legacyAliases: [CapabilityKeys.buttonVisual: CapabilityKeys.legacyText]
        )), [.invalidAlias(CapabilityKeys.buttonVisual, CapabilityKeys.legacyText)])
        XCTAssertEqual(CapabilityRegistry.validate(catalog: CapabilityCatalog(
            supportedKeys: [CapabilityKeys.textVisual], legacyAliases: [CapabilityKeys.buttonVisual: CapabilityKeys.legacyButton]
        )), [.aliasSourceNotSupported(CapabilityKeys.buttonVisual)])
    }

    func testInapplicableCatalogCannotAdvertiseSupport() {
        let unavailable = "No verified profile"
        XCTAssertEqual(CapabilityRegistry.validate(catalog: CapabilityCatalog(
            supportedKeys: [CapabilityKeys.textVisual], unavailableReason: unavailable
        )), [.inapplicableCatalogAdvertisesSupport])
        XCTAssertTrue(CapabilityRegistry.validate(catalog: CapabilityCatalog(
            supportedKeys: [], unavailableReason: unavailable
        )).isEmpty)
        let target = Target(id: EntityID("target_ios"), platform: .iOS, framework: .swiftUI)
        XCTAssertTrue(CapabilityRegistry.validate(catalog: NativePreviewCapabilityCatalog.catalog(for: CapabilityProfile(target: target))).isEmpty)
    }

    func testUnknownPersistedDeclarationRemainsAllowed() {
        var document = Document(name: "Forward declaration")
        let target = Target(id: EntityID("target_macos"), platform: .macOS, framework: .swiftUI)
        document.targets = [target]
        document.capabilityDeclarations = [CapabilityDeclaration(
            targetID: target.id, key: CapabilityKey("vendor.future.capability"), support: .exact
        )]
        XCTAssertFalse(DocumentValidator.validate(document).contains { $0.rule.hasPrefix("capability.") })
    }

    func testProductionConsumerCatalogsConformToRegistry() {
        XCTAssertTrue(CapabilityRegistry.validate(catalog: NativePreviewCapabilityCatalog.catalog).isEmpty)
        XCTAssertTrue(CapabilityRegistry.validate(catalog: SwiftUIGeneratorCapabilityCatalog.catalog).isEmpty)
        XCTAssertEqual(NativePreviewCapabilityCatalog.catalog.supportedKeys, NativePreviewCapabilityCatalog.supportedKeys)
        XCTAssertEqual(SwiftUIGeneratorCapabilityCatalog.catalog.supportedKeys, SwiftUIGeneratorCapabilityCatalog.supportedKeys)
        XCTAssertEqual(NativePreviewCapabilityCatalog.catalog.legacyAliases,
                       CapabilityRegistry.aliases(for: NativePreviewCapabilityCatalog.supportedKeys))
        XCTAssertEqual(SwiftUIGeneratorCapabilityCatalog.catalog.legacyAliases,
                       CapabilityRegistry.aliases(for: SwiftUIGeneratorCapabilityCatalog.supportedKeys))

        for platform in [Platform.iOS, .macOS, .android] {
            for framework in [Framework.swiftUI, .uiKit, .jetpackCompose, .composeMultiplatform] {
                let target = Target(id: EntityID("target_test"), platform: platform, framework: framework)
                let catalog = NativePreviewCapabilityCatalog.catalog(for: CapabilityProfile(target: target))
                XCTAssertTrue(CapabilityRegistry.validate(catalog: catalog).isEmpty, "\(platform)/\(framework)")
                if platform != .macOS || framework != .swiftUI {
                    XCTAssertNotNil(catalog.unavailableReason)
                    XCTAssertTrue(catalog.supportedKeys.isEmpty)
                    XCTAssertTrue(catalog.legacyAliases.isEmpty)
                }
            }
        }
    }

    func testCurrentProductionCatalogsMakeNoRuntimeVersionSupportClaims() {
        XCTAssertTrue(NativePreviewCapabilityCatalog.catalog.runtimeSensitiveKeys.isEmpty)
        XCTAssertTrue(SwiftUIGeneratorCapabilityCatalog.catalog.runtimeSensitiveKeys.isEmpty)
    }

    func testCurrentExtractorCorpusEmitsExactlyRegisteredBuiltInSemantics() {
        var document = Document(name: "Capability corpus")
        let scope = document.scopes[0].id
        let tokenID = EntityID("token_spacing")
        let componentID = EntityID("component_badge")
        let assetSources: [AssetSource] = [
            .system(name: "person"), .repository(path: "assets/avatar.png"),
            .remote(url: "https://example.com/avatar.png"), .runtime(binding: "user.avatar"),
            .generated(path: "generated/avatar.png", provenance: "test")
        ]
        document.assets = assetSources.enumerated().map { index, source in
            Asset(id: EntityID("asset_\(index)"), name: "Asset \(index)", ownerScopeID: scope, mediaType: "image/png", source: source)
        }
        document.components = [ComponentDefinition(
            id: componentID, name: "Badge", ownerScopeID: scope,
            root: Layer(id: EntityID("component_text"), name: "Label", payload: .text(TextLayerPayload(value: "Badge")))
        )]
        var children: [Layer] = [
            Layer(id: EntityID("layer_overlay"), name: "Overlay", payload: .overlay),
            Layer(id: EntityID("layer_scroll"), name: "Scroll", payload: .scroll),
            Layer(id: EntityID("layer_text"), name: "Name", payload: .text(TextLayerPayload(value: "Guest", binding: "user.name"))),
            Layer(id: EntityID("layer_button"), name: "Edit", payload: .button(ButtonLayerPayload(label: "Edit", emittedEvent: "edit"))),
            Layer(id: EntityID("layer_instance"), name: "Badge", payload: .componentInstance(
                ComponentInstanceLayerPayload(instance: ComponentInstance(definitionID: componentID))))
        ]
        children += document.assets.enumerated().map { index, asset in
            Layer(id: EntityID("layer_image_\(index)"), name: "Image", payload: .image(ImageLayerPayload(assetID: asset.id)))
        }
        var root = Layer(id: EntityID("layer_root"), name: "Root", payload: .stack, children: children,
                         layout: Layout(axis: .vertical, spacingTokenID: tokenID), effects: [.padding(tokenID: tokenID)])
        root.interactionID = EntityID("interaction_tap")
        root.nativeIntent = "system"
        root.targetOverrides = ["macOS": "custom"]
        var systemScreen = Screen(id: EntityID("screen_system"), name: "System", scopeID: scope, root: root)
        systemScreen.navigation = .system(SystemNavigation(title: "Title", toolbarItems: [
            SystemToolbarItem(id: EntityID("toolbar_edit"), title: "Edit", emittedEvent: "edit")
        ]))
        var customScreen = Screen(id: EntityID("screen_custom"), name: "Custom", scopeID: scope,
                                  root: Layer(id: EntityID("layer_custom_root"), name: "Root", payload: .stack))
        customScreen.navigation = .custom(layerID: customScreen.root.id)
        document.screens = [systemScreen, customScreen]

        let extractions = document.screens.map { SemanticRequirementExtractor.extract(screen: $0, document: document) }
        XCTAssertTrue(extractions.flatMap(\.diagnostics).isEmpty)
        let emitted = Set(extractions.flatMap { $0.requirements.map(\.key) })
        XCTAssertEqual(emitted, CapabilityRegistry.semanticKeys)
        XCTAssertTrue(CapabilityRegistry.validate(requirements: extractions.flatMap(\.requirements)).isEmpty)
    }
}
