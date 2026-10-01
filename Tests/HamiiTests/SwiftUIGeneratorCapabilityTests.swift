import Foundation
import XCTest
import HamiiCore
import HamiiGeneration

final class SwiftUIGeneratorCapabilityTests: XCTestCase {
    private let target = Target(id: EntityID("target_swiftui"), platform: .macOS, framework: .swiftUI)

    private func document(root: Layer) -> Document {
        var document = Document(name: "Generator capability")
        document.targets = [target]
        document.screens = [Screen(id: EntityID("screen_main"), name: "Main", scopeID: document.scopes[0].id, root: root)]
        return document
    }

    private func declare(_ keys: [CapabilityKey], in document: inout Document, support: CapabilitySupport = .exact) {
        document.capabilityDeclarations += keys.map { CapabilityDeclaration(targetID: target.id, key: $0, support: support) }
    }

    private func generate(_ document: Document) throws -> String {
        try SwiftUIGenerator.generate(document: document, screenID: EntityID("screen_main"), targetID: target.id).source
    }

    private func assertUnsupported(_ document: Document, at id: EntityID, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try generate(document), file: file, line: line) { error in
            guard case GenerationError.unsupported(let actual, _) = error else {
                return XCTFail("Expected unsupported, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(actual, id, file: file, line: line)
        }
    }

    func testMissingDeclarationAndSpecificDeclarationPrecedence() throws {
        let root = Layer(id: EntityID("layer_text"), name: "Text", payload: .text(TextLayerPayload(value: "Hello")))
        var project = document(root: root)
        assertUnsupported(project, at: root.id)
        declare([CapabilityKeys.legacyText], in: &project)
        let source = try generate(project)
        XCTAssertTrue(source.contains("Text(\"Hello\")"))

        declare([CapabilityKeys.textVisual], in: &project, support: .unsupported)
        assertUnsupported(project, at: root.id)
        project.capabilityDeclarations.removeLast()
        project.capabilityDeclarations[0].support = .unsupported
        declare([CapabilityKeys.textVisual], in: &project)
        XCTAssertEqual(try generate(project), source)

        let ambiguous = CapabilityEvaluator.evaluate(
            requirements: [SemanticRequirement(key: CapabilityKeys.textVisual, sourceEntityID: root.id)],
            profile: CapabilityProfile(target: target),
            declarations: project.capabilityDeclarations + [CapabilityDeclaration(targetID: target.id, key: CapabilityKeys.textVisual, support: .exact)],
            catalog: SwiftUIGeneratorCapabilityCatalog.catalog
        )
        XCTAssertFalse(ambiguous.allowed)
        XCTAssertEqual(ambiguous.items[0].reason, "Ambiguous capability declarations")
    }

    func testButtonEventNeedsConsumerImplementationEvenWithExactDeclaration() throws {
        let button = Layer(id: EntityID("layer_button"), name: "Button", payload: .button(ButtonLayerPayload(label: "Go", emittedEvent: "go")))
        var project = document(root: button)
        declare([CapabilityKeys.legacyButton, CapabilityKeys.buttonEventEmit], in: &project)
        XCTAssertEqual(DocumentValidator.validate(project), [])
        let report = CapabilityEvaluator.evaluate(
            requirements: SemanticRequirementExtractor.extract(screen: project.screens[0], document: project).requirements,
            profile: CapabilityProfile(target: target), declarations: project.capabilityDeclarations,
            catalog: SwiftUIGeneratorCapabilityCatalog.catalog
        )
        XCTAssertEqual(report.items.map(\.allowed), [true, false])
        assertUnsupported(project, at: button.id)
        project.screens[0].root.emittedEvent = nil
        XCTAssertTrue(try generate(project).contains("Button(\"Go\") { }"))
    }

    func testNestedResolvedComponentRequirementBlocksGeneration() {
        let innerID = EntityID("component_inner")
        let outerID = EntityID("component_outer")
        let innerRoot = Layer(id: EntityID("inner_text"), name: "Text", payload: .text(TextLayerPayload(value: "Fallback", binding: "user.name")))
        let outerRoot = Layer(id: EntityID("outer_child"), name: "Nested", payload: .componentInstance(ComponentInstanceLayerPayload(instance: ComponentInstance(definitionID: innerID))))
        let screenRoot = Layer(id: EntityID("screen_instance"), name: "Outer", payload: .componentInstance(ComponentInstanceLayerPayload(instance: ComponentInstance(definitionID: outerID))))
        var project = document(root: screenRoot)
        let scope = project.scopes[0].id
        project.components = [
            ComponentDefinition(id: innerID, name: "Inner", ownerScopeID: scope, root: innerRoot),
            ComponentDefinition(id: outerID, name: "Outer", ownerScopeID: scope, root: outerRoot)
        ]
        declare([CapabilityKeys.legacyInstance, CapabilityKeys.legacyText, CapabilityKeys.fixtureBinding, CapabilityKeys.bindingFallback], in: &project)
        XCTAssertEqual(DocumentValidator.validate(project), [])
        assertUnsupported(project, at: innerRoot.id)
        project.components[0].root.textBinding = nil
        XCTAssertEqual(try? generate(project), "import SwiftUI\n\nstruct HamiiScreen_screen_main: View {\n    var body: some View {\n        Text(\"Fallback\")\n    }\n}\n")
    }

    func testUnsupportedSemanticsStayBlockedEvenIfDeclaredExact() throws {
        let root = Layer(id: EntityID("layer_root"), name: "Text", payload: .text(TextLayerPayload(value: "Hello")))
        var project = document(root: root)
        declare([CapabilityKeys.legacyText], in: &project)

        var binding = project
        binding.screens[0].root.textBinding = "user.name"
        declare([CapabilityKeys.fixtureBinding, CapabilityKeys.bindingFallback], in: &binding)
        assertUnsupported(binding, at: root.id)

        var native = project
        native.screens[0].root.nativeIntent = "custom"
        declare([CapabilityKeys.nativeIntent], in: &native)
        assertUnsupported(native, at: root.id)

        var override = project
        override.screens[0].root.targetOverrides = ["iOS": "custom"]
        declare([CapabilityKeys.targetOverride], in: &override)
        assertUnsupported(override, at: root.id)

        var navigation = project
        navigation.screens[0].navigation = .system(SystemNavigation(title: "Home"))
        declare([CapabilityKeys.legacySystemNavigation, CapabilityKeys.navigationTitle], in: &navigation)
        assertUnsupported(navigation, at: navigation.screens[0].id)

        var image = document(root: Layer(id: EntityID("layer_image"), name: "Image", payload: .image(ImageLayerPayload(assetID: EntityID("asset_remote")))))
        image.assets = [Asset(id: EntityID("asset_remote"), name: "Remote", ownerScopeID: image.scopes[0].id, mediaType: "image/png", source: .remote(url: "https://example.com/image.png"))]
        declare([CapabilityKeys.legacyImage, CapabilityKeys.remoteAssetFetch], in: &image)
        assertUnsupported(image, at: image.screens[0].root.id)
    }

    func testNonStackSpacingAndInteractionStayBlockedWhilePaddingLowers() throws {
        let root = Layer(id: EntityID("layer_root"), name: "Text", payload: .text(TextLayerPayload(value: "Hello")))
        var project = document(root: root)
        declare([CapabilityKeys.legacyText], in: &project)
        let tokenID = EntityID("token_space")
        project.tokens = [DesignToken(id: tokenID, name: "Spacing", kind: .spacing, ownerScopeID: project.scopes[0].id, value: .literal("12"))]

        var spacing = project
        spacing.screens[0].root.layout.spacingTokenID = tokenID
        declare([CapabilityKeys.spacingToken], in: &spacing)
        XCTAssertTrue(DocumentValidator.validate(spacing).contains { $0.rule == "layout.spacingKind" && $0.entityID == root.id })
        XCTAssertThrowsError(try generate(spacing)) { error in
            guard case GenerationError.invalidDocument = error else { return XCTFail("Expected invalid document, got \(error)") }
        }

        var padding = project
        padding.screens[0].root.effects = [.padding(tokenID: tokenID)]
        declare([CapabilityKeys.paddingEffect], in: &padding)
        XCTAssertEqual(DocumentValidator.validate(padding), [])
        XCTAssertTrue(try generate(padding).contains(".padding(12.0)"))

        var interaction = project
        let interactionID = EntityID("interaction_tap")
        interaction.interactions = [Interaction(id: interactionID, name: "Tap", states: ["idle"], transitions: [])]
        interaction.screens[0].root.interactionID = interactionID
        declare([CapabilityKeys.interactionRuntime], in: &interaction)
        XCTAssertEqual(DocumentValidator.validate(interaction), [])
        assertUnsupported(interaction, at: root.id)
    }

    func testStackSpacingDeclarationsAxisAndNilSource() throws {
        let tokenID = EntityID("space_twelve")
        let child = Layer(id: EntityID("child"), name: "Child", payload: .text(TextLayerPayload(value: "Hello")))
        let root = Layer(id: EntityID("stack"), name: "Stack", payload: .stack, children: [child])
        var project = document(root: root)
        project.tokens = [DesignToken(id: tokenID, name: "Spacing", kind: .spacing,
                                      ownerScopeID: project.scopes[0].id, value: .literal("12"))]
        declare([CapabilityKeys.stackContainer, CapabilityKeys.textVisual], in: &project)
        let sourceWithoutSpacing = try generate(project)
        XCTAssertEqual(sourceWithoutSpacing,
                       "import SwiftUI\n\nstruct HamiiScreen_screen_main: View {\n    var body: some View {\n        VStack {\n            Text(\"Hello\")\n        }\n    }\n}\n")

        project.screens[0].root.layout.spacingTokenID = tokenID
        XCTAssertEqual(DocumentValidator.validate(project), [])
        assertUnsupported(project, at: root.id)
        declare([CapabilityKeys.legacySpacing], in: &project)
        XCTAssertTrue(try generate(project).contains("VStack(spacing: 12.0) {"))

        declare([CapabilityKeys.spacingToken], in: &project, support: .unsupported)
        assertUnsupported(project, at: root.id)
        project.capabilityDeclarations[project.capabilityDeclarations.count - 1].support = .exact
        XCTAssertTrue(try generate(project).contains("VStack(spacing: 12.0) {"))

        project.screens[0].root.layout.axis = .horizontal
        XCTAssertTrue(try generate(project).contains("HStack(spacing: 12.0) {"))
        project.tokens[0].value = .literal("0")
        XCTAssertTrue(try generate(project).contains("HStack(spacing: 0.0) {"))
    }

    func testNestedStackSpacingAndPaddingRemainSeparate() throws {
        let child = Layer(id: EntityID("child_stack"), name: "Child", payload: .stack,
                          children: [Layer(id: EntityID("text"), name: "Text", payload: .text(TextLayerPayload(value: "Hi")))],
                          layout: Layout(axis: .horizontal, spacingTokenID: EntityID("four")))
        let root = Layer(id: EntityID("parent_stack"), name: "Parent", payload: .stack, children: [child],
                         layout: Layout(axis: .vertical, spacingTokenID: EntityID("eight")),
                         effects: [.padding(tokenID: EntityID("twelve"))])
        var project = document(root: root)
        let scope = project.scopes[0].id
        project.tokens = [
            DesignToken(id: EntityID("four"), name: "Four", kind: .spacing, ownerScopeID: scope, value: .literal("4")),
            DesignToken(id: EntityID("eight"), name: "Eight", kind: .spacing, ownerScopeID: scope, value: .literal("8")),
            DesignToken(id: EntityID("twelve"), name: "Twelve", kind: .spacing, ownerScopeID: scope, value: .literal("12"))
        ]
        declare([CapabilityKeys.stackContainer, CapabilityKeys.textVisual, CapabilityKeys.spacingToken, CapabilityKeys.paddingEffect], in: &project)
        XCTAssertEqual(DocumentValidator.validate(project), [])
        let source = try generate(project)
        XCTAssertTrue(source.contains("VStack(spacing: 8.0) {\n            HStack(spacing: 4.0) {"))
        XCTAssertTrue(source.contains("        }\n            .padding(12.0)"))
        XCTAssertEqual(source.components(separatedBy: ".padding(12.0)").count - 1, 1)
    }

    func testComponentStackSpacingResolvesAliasOnce() throws {
        let base = EntityID("base")
        let alias = EntityID("alias")
        let root = Layer(id: EntityID("definition_stack"), name: "Definition", payload: .stack,
                         children: [Layer(id: EntityID("definition_text"), name: "Text", payload: .text(TextLayerPayload(value: "Hi")))],
                         layout: Layout(spacingTokenID: alias))
        let instance = Layer(id: EntityID("instance"), name: "Instance",
                             payload: .componentInstance(ComponentInstanceLayerPayload(instance: ComponentInstance(definitionID: EntityID("card")))))
        var project = document(root: instance)
        let scope = project.scopes[0].id
        project.components = [ComponentDefinition(id: EntityID("card"), name: "Card", ownerScopeID: scope, root: root)]
        project.tokens = [
            DesignToken(id: base, name: "Base", kind: .spacing, ownerScopeID: scope, value: .literal("16")),
            DesignToken(id: alias, name: "Alias", kind: .spacing, ownerScopeID: scope, value: .reference(base))
        ]
        declare([CapabilityKeys.componentInstance, CapabilityKeys.stackContainer, CapabilityKeys.textVisual,
                 CapabilityKeys.spacingToken], in: &project)
        XCTAssertEqual(DocumentValidator.validate(project), [])
        let source = try generate(project)
        XCTAssertEqual(source.components(separatedBy: "VStack(spacing: 16.0)").count - 1, 1)
    }

    func testNonStackSpacingFailsClosedForVisualLayers() {
        let tokenID = EntityID("space")
        let assetID = EntityID("system_asset")
        let payloads: [LayerPayload] = [
            .text(TextLayerPayload(value: "Hello")),
            .button(ButtonLayerPayload(label: "Go")),
            .image(ImageLayerPayload(assetID: assetID)),
            .overlay,
            .scroll
        ]
        for payload in payloads {
            let root = Layer(id: EntityID("root"), name: "Root", payload: payload,
                             layout: Layout(spacingTokenID: tokenID))
            var project = document(root: root)
            let scope = project.scopes[0].id
            project.tokens = [DesignToken(id: tokenID, name: "Spacing", kind: .spacing,
                                          ownerScopeID: scope, value: .literal("4"))]
            project.assets = [Asset(id: assetID, name: "System", ownerScopeID: scope,
                                    mediaType: "image/system", source: .system(name: "star"))]
            declare([CapabilityKeys.spacingToken], in: &project)
            XCTAssertTrue(DocumentValidator.validate(project).contains { $0.rule == "layout.spacingKind" && $0.entityID == root.id })
            XCTAssertThrowsError(try generate(project)) { error in
                guard case GenerationError.invalidDocument = error else { return XCTFail("Expected invalid document, got \(error)") }
            }
        }
    }

    func testInvalidStackSpacingTokenFailsClosed() {
        let tokenID = EntityID("space")
        let root = Layer(id: EntityID("stack"), name: "Stack", payload: .stack,
                         layout: Layout(spacingTokenID: tokenID))
        var project = document(root: root)
        declare([CapabilityKeys.stackContainer, CapabilityKeys.spacingToken], in: &project)
        let scope = project.scopes[0].id
        for value in [TokenValue.literal("-2"), .literal("nan"), .literal("inf"), .reference(EntityID("missing"))] {
            project.tokens = [DesignToken(id: tokenID, name: "Invalid", kind: .spacing, ownerScopeID: scope, value: value)]
            XCTAssertTrue(DocumentValidator.validate(project).contains { $0.rule == "token.layoutValue" })
            XCTAssertThrowsError(try generate(project))
        }
        project.tokens = [DesignToken(id: tokenID, name: "Wrong kind", kind: .color, ownerScopeID: scope, value: .literal("4"))]
        XCTAssertTrue(DocumentValidator.validate(project).contains { $0.rule == "token.layoutValue" })
        XCTAssertThrowsError(try generate(project))
    }

    func testPaddingKeepsStoredOrderAndResolvesAlias() throws {
        let first = EntityID("space_four")
        let second = EntityID("space_twelve")
        let alias = EntityID("space_alias")
        let root = Layer(id: EntityID("layer_text"), name: "Text", payload: .text(TextLayerPayload(value: "Hello")),
                         effects: [.padding(tokenID: alias), .padding(tokenID: second)])
        var project = document(root: root)
        let scope = project.scopes[0].id
        project.tokens = [
            DesignToken(id: first, name: "Four", kind: .spacing, ownerScopeID: scope, value: .literal("4")),
            DesignToken(id: second, name: "Twelve", kind: .spacing, ownerScopeID: scope, value: .literal("12")),
            DesignToken(id: alias, name: "Alias", kind: .spacing, ownerScopeID: scope, value: .reference(first))
        ]
        declare([CapabilityKeys.textVisual, CapabilityKeys.paddingEffect], in: &project)
        XCTAssertEqual(DocumentValidator.validate(project), [])
        let source = try generate(project)
        XCTAssertTrue(source.contains("Text(\"Hello\")\n            .padding(4.0)\n            .padding(12.0)"))

        let decoded = try JSONDecoder().decode(Layer.self, from: JSONEncoder().encode(root))
        project.screens[0].root = decoded
        XCTAssertEqual(try generate(project), source)

        project.screens[0].root.effects.reverse()
        XCTAssertTrue(try generate(project).contains(".padding(12.0)\n            .padding(4.0)"))
    }

    func testPaddingAppliesToComponentRootAndKeepsContainerBoundaries() throws {
        let child = Layer(id: EntityID("child"), name: "Child", payload: .text(TextLayerPayload(value: "Child")),
                          effects: [.padding(tokenID: EntityID("four"))])
        let definitionRoot = Layer(id: EntityID("definition_root"), name: "Stack", payload: .stack, children: [child],
                                   effects: [.padding(tokenID: EntityID("twelve"))])
        let instance = Layer(id: EntityID("instance"), name: "Instance",
                             payload: .componentInstance(ComponentInstanceLayerPayload(instance: ComponentInstance(definitionID: EntityID("card")))))
        var project = document(root: instance)
        let scope = project.scopes[0].id
        project.components = [ComponentDefinition(id: EntityID("card"), name: "Card", ownerScopeID: scope, root: definitionRoot)]
        project.tokens = [
            DesignToken(id: EntityID("four"), name: "Four", kind: .spacing, ownerScopeID: scope, value: .literal("4")),
            DesignToken(id: EntityID("twelve"), name: "Twelve", kind: .spacing, ownerScopeID: scope, value: .literal("12"))
        ]
        declare([CapabilityKeys.componentInstance, CapabilityKeys.stackContainer, CapabilityKeys.textVisual, CapabilityKeys.paddingEffect], in: &project)
        XCTAssertEqual(DocumentValidator.validate(project), [])
        let source = try generate(project)
        XCTAssertEqual(source.components(separatedBy: ".padding(4.0)").count - 1, 1)
        XCTAssertEqual(source.components(separatedBy: ".padding(12.0)").count - 1, 1)
        XCTAssertTrue(source.contains("Text(\"Child\")\n                .padding(4.0)\n        }\n            .padding(12.0)"))
    }

    func testInvalidPaddingTokensFailValidationWithoutFallback() {
        let root = Layer(id: EntityID("layer_text"), name: "Text", payload: .text(TextLayerPayload(value: "Hello")),
                         effects: [.padding(tokenID: EntityID("token"))])
        var project = document(root: root)
        declare([CapabilityKeys.textVisual, CapabilityKeys.paddingEffect], in: &project)
        let scope = project.scopes[0].id
        for value in [TokenValue.literal("-1"), .literal("nan"), .literal("inf"), .reference(EntityID("missing"))] {
            project.tokens = [DesignToken(id: EntityID("token"), name: "Invalid", kind: .spacing, ownerScopeID: scope, value: value)]
            XCTAssertTrue(DocumentValidator.validate(project).contains { $0.rule == "token.layoutValue" })
            XCTAssertThrowsError(try generate(project))
        }
        project.tokens = [DesignToken(id: EntityID("token"), name: "Wrong kind", kind: .color, ownerScopeID: scope, value: .literal("4"))]
        XCTAssertTrue(DocumentValidator.validate(project).contains { $0.rule == "token.layoutValue" })
        XCTAssertThrowsError(try generate(project))
        project.tokens = [DesignToken(id: EntityID("token"), name: "Zero", kind: .spacing, ownerScopeID: scope, value: .literal("0"))]
        XCTAssertTrue((try? generate(project))?.contains(".padding(0.0)") == true)
    }

    func testFrameworkApplicabilityRemainsExplicit() {
        let root = Layer(id: EntityID("layer_root"), name: "Text", payload: .text(TextLayerPayload(value: "Hello")))
        var project = document(root: root)
        declare([CapabilityKeys.legacyText], in: &project)
        project.targets[0].framework = .uiKit
        assertUnsupported(project, at: project.screens[0].id)
        project.targets[0].framework = .swiftUI
        project.targets[0].platform = .android
        assertUnsupported(project, at: project.screens[0].id)
    }

    func testUnspecifiedRuntimeCannotAllowRuntimeSensitiveRequirement() {
        let key = CapabilityKeys.textVisual
        let requirement = SemanticRequirement(key: key, sourceEntityID: EntityID("layer_text"))
        let declaration = CapabilityDeclaration(targetID: target.id, key: key, support: .exact)
        let catalog = CapabilityCatalog(supportedKeys: [key], runtimeSensitiveKeys: [key])
        let unknown = CapabilityEvaluator.evaluate(requirements: [requirement], profile: CapabilityProfile(target: target), declarations: [declaration], catalog: catalog)
        XCTAssertFalse(unknown.allowed)
        let surface = AppSurface(id: EntityID("surface"), targetID: target.id, device: "Mac", runtime: "macOS 27", buildEnvironment: "SDK", screenID: EntityID("screen_main"), architectureScopeID: EntityID("scope"))
        let observed = CapabilityEvaluator.evaluate(requirements: [requirement], profile: CapabilityProfile(target: target, surface: surface), declarations: [declaration], catalog: catalog)
        XCTAssertTrue(observed.allowed)
    }
}
