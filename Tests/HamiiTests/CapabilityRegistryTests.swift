import XCTest
import HamiiCore

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
}
