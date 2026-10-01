import XCTest
import HamiiCore

final class ScreenSemanticsValidationTests: XCTestCase {
    private func id(_ value: String) -> EntityID { EntityID(value) }

    private func text(_ idValue: String, binding: String = "profile.name") -> Layer {
        var layer = Layer(id: id(idValue), kind: .text, name: idValue, text: "Name")
        layer.textBinding = binding
        return layer
    }

    private func document(root: Layer, components: [ComponentDefinition] = []) -> Document {
        var document = Document(name: "Semantics")
        document.versions.document = 3
        let scope = document.scopes[0].id
        document.components = components
        document.screens = [Screen(id: id("screen_profile"), name: "Profile", scopeID: scope, root: root)]
        return document
    }

    private func output(_ key: String, _ anchor: SemanticOutputAnchor,
                        binding: String = "profile.name") -> SemanticOutput {
        SemanticOutput(key: SemanticOutputKey(key), anchor: anchor, binding: binding)
    }

    private func relation(_ key: String, source: String = "profile.name",
                          visibility: SemanticVisibility = .always,
                          transform: SemanticTransformKey = .identity) -> SemanticRelation {
        SemanticRelation(output: SemanticOutputKey(key), source: SemanticSourceKey(source),
                         visibleWhen: visibility, whenNil: .literal("Guest"), transform: transform)
    }

    private func semantics(outputs: [SemanticOutput], relations: [SemanticRelation],
                           sources: [SemanticSource] = [SemanticSource(key: SemanticSourceKey("profile.name"), valueKind: .text)]) -> ScreenSemantics {
        ScreenSemantics(sources: sources, outputs: outputs, relations: relations)
    }

    private func rules(_ document: Document) -> Set<String> {
        Set(DocumentValidator.validate(document).map(\.rule))
    }

    func testDirectAnchorValidatesBindingAndTypedRelation() {
        var document = document(root: Layer(id: id("screen_root"), kind: .stack, name: "Root",
                                                children: [text("name_label")]))
        document.screens[0].semantics = semantics(
            outputs: [output("profileName", .direct(layerID: id("name_label"), property: .text))],
            relations: [relation("profileName")])
        XCTAssertEqual(DocumentValidator.validate(document), [])

        document.screens[0].semantics!.outputs[0].binding = "wrong.path"
        XCTAssertTrue(rules(document).contains("semantics.binding"))
        document.screens[0].semantics!.outputs[0].binding = "profile.name"
        document.screens[0].semantics!.outputs[0].anchor = .direct(layerID: id("missing"), property: .text)
        XCTAssertTrue(rules(document).contains("semantics.anchor"))
    }

    func testFormatVersionRequiresExplicitSemanticOwnership() {
        var document = document(root: text("name_label"))
        XCTAssertTrue(rules(document).contains("semantics.required"))
        document.screens[0].semantics = ScreenSemantics()
        document.versions.document = 2
        XCTAssertTrue(rules(document).contains("semantics.formatVersion"))
    }

    func testSourceOutputRelationIdentityAndVisibilityFailures() {
        let root = Layer(id: id("screen_root"), kind: .stack, name: "Root", children: [text("name_label")])
        var document = document(root: root)
        let anchored = output("profileName", .direct(layerID: id("name_label"), property: .text))
        document.screens[0].semantics = semantics(outputs: [anchored, anchored], relations: [relation("profileName")],
                                                  sources: [SemanticSource(key: SemanticSourceKey("profile.name"), valueKind: .number),
                                                            SemanticSource(key: SemanticSourceKey("profile.name"), valueKind: .number)])
        var found = rules(document)
        XCTAssertTrue(found.isSuperset(of: ["semantics.duplicateSource", "semantics.duplicateOutput", "semantics.duplicateAnchor", "semantics.relationOutput", "semantics.relationSource"]))

        document.screens[0].semantics = semantics(outputs: [anchored], relations: [relation("profileName", visibility: .booleanEquals(source: SemanticSourceKey("profile.name"), value: true))],
                                                  sources: [SemanticSource(key: SemanticSourceKey("profile.name"), valueKind: .number)])
        found = rules(document)
        XCTAssertTrue(found.isSuperset(of: ["semantics.sourceType", "semantics.visibilityType"]))

        document.screens[0].semantics = semantics(outputs: [anchored], relations: [relation("profileName", source: "absent", visibility: .booleanEquals(source: SemanticSourceKey("missing"), value: true))])
        found = rules(document)
        XCTAssertTrue(found.isSuperset(of: ["semantics.relationSource", "semantics.visibilitySource"]))

        document.screens[0].semantics = semantics(outputs: [anchored], relations: [relation("absent")])
        found = rules(document)
        XCTAssertTrue(found.isSuperset(of: ["semantics.relationCount", "semantics.relationOutput"]))
    }

    func testEmptyKeysBindingsAndDuplicateRelationsAreRejected() {
        var document = document(root: text("name_label"))
        document.screens[0].semantics = semantics(
            outputs: [output("", .direct(layerID: id("name_label"), property: .text), binding: " ")],
            relations: [relation(""), relation("")],
            sources: [SemanticSource(key: SemanticSourceKey(" "), valueKind: .text)])
        let found = rules(document)
        XCTAssertTrue(found.isSuperset(of: ["semantics.sourceKey", "semantics.outputKey", "semantics.binding", "semantics.relationCount"]), "\(found)")
    }

    func testDistinctOutputKeysCannotSharePhysicalAnchor() {
        var document = document(root: text("name_label"))
        let anchor: SemanticOutputAnchor = .direct(layerID: id("name_label"), property: .text)
        document.screens[0].semantics = semantics(outputs: [output("primaryName", anchor), output("secondaryName", anchor)],
                                                  relations: [relation("primaryName"), relation("secondaryName")])
        let found = rules(document)
        XCTAssertTrue(found.contains("semantics.duplicateAnchor"), "\(found)")
        XCTAssertFalse(found.contains("semantics.duplicateOutput"))
    }

    func testComponentDefinitionPathTargetAndVariantBinding() {
        var document = document(root: Layer(id: id("screen_root"), kind: .stack, name: "Screen"))
        var definition = ComponentDefinition(
            id: id("card_definition"), name: "Card", ownerScopeID: document.scopes[0].id,
            root: Layer(id: id("definition_root"), kind: .stack, name: "Card", children: [text("name_label")]))
        definition.variants = [ComponentVariant(id: id("variant_large"), axis: "size", value: "large",
                                                propertyOverrides: ["name_label.text": "Large name"])]
        document.components = [definition]
        document.screens[0].root.children = [Layer(id: id("card_instance"), kind: .componentInstance, name: "Card",
                                                   component: ComponentInstance(definitionID: definition.id,
                                                                                variantSelection: ["size": "large"]))]
        let frame = SemanticOccurrenceFrame(instanceLayerID: id("card_instance"), expectedDefinitionID: definition.id,
                                            layerPath: [id("screen_root"), id("card_instance")])
        let correct: SemanticOutputAnchor = .component(path: [frame], layerID: id("name_label"), property: .text)
        document.screens[0].semantics = semantics(outputs: [output("profileName", correct)],
                                                  relations: [relation("profileName")])
        XCTAssertEqual(DocumentValidator.validate(document), [], "Variant changes the text value, not its binding")

        document.screens[0].semantics!.outputs[0].binding = "other.binding"
        XCTAssertTrue(rules(document).contains("semantics.binding"))
        document.screens[0].semantics!.outputs[0].binding = "profile.name"
        document.screens[0].semantics!.outputs[0].anchor = .component(
            path: [SemanticOccurrenceFrame(instanceLayerID: frame.instanceLayerID,
                                           expectedDefinitionID: id("wrong_definition"), layerPath: frame.layerPath)],
            layerID: id("name_label"), property: .text)
        XCTAssertTrue(rules(document).contains("semantics.anchor"))
        document.screens[0].semantics!.outputs[0].anchor = .component(
            path: [SemanticOccurrenceFrame(instanceLayerID: frame.instanceLayerID,
                                           expectedDefinitionID: definition.id,
                                           layerPath: [id("screen_root"), id("missing_path")])],
            layerID: id("name_label"), property: .text)
        XCTAssertTrue(rules(document).contains("semantics.anchor"))
        document.screens[0].semantics!.outputs[0].anchor = .component(
            path: [frame], layerID: id("missing_target"), property: .text)
        XCTAssertTrue(rules(document).contains("semantics.anchor"))
    }

    func testRepeatedNestedComponentOccurrencesAndStalePath() {
        let scope = Document(name: "Scope").scopes[0].id
        // The actual owner scope is set below to the document's root scope.
        let nestedRoot = Layer(id: id("nested_root"), kind: .stack, name: "Nested",
                               children: [text("definition_label")])
        var nested = ComponentDefinition(id: id("nested_definition"), name: "Nested", ownerScopeID: scope, root: nestedRoot)
        let parentRoot = Layer(id: id("parent_root"), kind: .stack, name: "Parent", children: [
            Layer(id: id("nested_instance"), kind: .componentInstance, name: "Nested",
                  component: ComponentInstance(definitionID: nested.id))
        ])
        var parent = ComponentDefinition(id: id("parent_definition"), name: "Parent", ownerScopeID: scope, root: parentRoot)
        let screenRoot = Layer(id: id("screen_root"), kind: .stack, name: "Screen", children: [
            Layer(id: id("left_instance"), kind: .componentInstance, name: "Left", component: ComponentInstance(definitionID: parent.id)),
            Layer(id: id("right_instance"), kind: .componentInstance, name: "Right", component: ComponentInstance(definitionID: parent.id))
        ])
        var document = document(root: screenRoot)
        nested.ownerScopeID = document.scopes[0].id
        parent.ownerScopeID = document.scopes[0].id
        document.components = [nested, parent]
        func anchor(_ instance: String) -> SemanticOutputAnchor {
            .component(path: [
                SemanticOccurrenceFrame(instanceLayerID: id(instance), expectedDefinitionID: parent.id,
                                        layerPath: [id("screen_root"), id(instance)]),
                SemanticOccurrenceFrame(instanceLayerID: id("nested_instance"), expectedDefinitionID: nested.id,
                                        layerPath: [id("parent_root"), id("nested_instance")])
            ], layerID: id("definition_label"), property: .text)
        }
        document.screens[0].semantics = semantics(outputs: [output("leftName", anchor("left_instance")),
                                                           output("rightName", anchor("right_instance"))],
                                                  relations: [relation("leftName"), relation("rightName")])
        XCTAssertEqual(DocumentValidator.validate(document), [])

        document.screens[0].semantics!.outputs[1].anchor = .component(path: [
            SemanticOccurrenceFrame(instanceLayerID: id("right_instance"), expectedDefinitionID: parent.id,
                                    layerPath: [id("screen_root"), id("left_instance")])
        ], layerID: id("definition_label"), property: .text)
        XCTAssertTrue(rules(document).contains("semantics.anchor"))
    }

    func testSlotInjectedSameLayerIDCannotImpersonateDefinitionOutput() {
        var document = document(root: Layer(id: id("screen_root"), kind: .stack, name: "Screen"))
        let definitionRoot = Layer(id: id("definition_root"), kind: .stack, name: "Definition", children: [
            Layer(id: id("slot_container"), kind: .stack, name: "Slot", children: [text("definition_label")])
        ])
        var definition = ComponentDefinition(id: id("component_card"), name: "Card",
                                             ownerScopeID: document.scopes[0].id, root: definitionRoot)
        definition.api.slots = [ComponentSlot(name: "content", targetLayerID: id("slot_container"))]
        document.components = [definition]
        document.screens[0].root.children = [Layer(id: id("card_instance"), kind: .componentInstance,
                                                   name: "Card", component: ComponentInstance(definitionID: definition.id))]
        let anchor: SemanticOutputAnchor = .component(
            path: [SemanticOccurrenceFrame(instanceLayerID: id("card_instance"), expectedDefinitionID: definition.id,
                                           layerPath: [id("screen_root"), id("card_instance")])],
            layerID: id("definition_label"), property: .text)
        document.screens[0].semantics = semantics(outputs: [output("profileName", anchor)],
                                                  relations: [relation("profileName")])
        XCTAssertEqual(DocumentValidator.validate(document), [])

        document.screens[0].root.children[0].component!.slotContent["content"] = [text("definition_label")]
        XCTAssertTrue(rules(document).contains("semantics.anchor"))
    }

    func testSlotInjectedComponentAtReplacedTargetCannotImpersonateOccurrenceFrame() {
        var document = document(root: Layer(id: id("screen_root"), kind: .stack, name: "Screen"))
        let child = ComponentDefinition(id: id("child_definition"), name: "Child",
                                        ownerScopeID: document.scopes[0].id,
                                        root: Layer(id: id("child_root"), kind: .stack, name: "Child",
                                                    children: [text("child_label")]))
        let rawSlot = Layer(id: id("slot_target"), kind: .stack, name: "Slot")
        var parent = ComponentDefinition(id: id("parent_definition"), name: "Parent",
                                         ownerScopeID: document.scopes[0].id,
                                         root: Layer(id: id("parent_root"), kind: .stack, name: "Parent",
                                                     children: [rawSlot]))
        parent.api.slots = [ComponentSlot(name: "content", targetLayerID: id("slot_target"))]
        document.components = [parent, child]
        document.screens[0].root.children = [Layer(id: id("parent_instance"), kind: .componentInstance,
                                                   name: "Parent", component: ComponentInstance(
                                                    definitionID: parent.id, slotContent: ["content": [
                                                        Layer(id: id("slot_target"), kind: .componentInstance,
                                                              name: "Injected", component: ComponentInstance(definitionID: child.id))
                                                    ]] ))]
        let anchor: SemanticOutputAnchor = .component(path: [
            SemanticOccurrenceFrame(instanceLayerID: id("parent_instance"), expectedDefinitionID: parent.id,
                                    layerPath: [id("screen_root"), id("parent_instance")]),
            SemanticOccurrenceFrame(instanceLayerID: id("slot_target"), expectedDefinitionID: child.id,
                                    layerPath: [id("parent_root"), id("slot_target")])
        ], layerID: id("child_label"), property: .text)
        document.screens[0].semantics = semantics(outputs: [output("profileName", anchor)],
                                                  relations: [relation("profileName")])
        XCTAssertTrue(rules(document).contains("semantics.anchor"))
    }
}
