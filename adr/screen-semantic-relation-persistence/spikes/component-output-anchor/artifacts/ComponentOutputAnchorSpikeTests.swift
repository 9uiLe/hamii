// Test-only candidate schema and resolver. The runner installs this file temporarily.
import Foundation
import XCTest
import HamiiCore
import HamiiFormat
import HamiiIntegration

private struct OccurrenceFrame: Codable, Hashable {
    var instanceLayerID: EntityID
    var definitionID: EntityID
    // Root-to-instance path in the Screen or the preceding resolved definition.
    var layerPath: [EntityID]
}

private enum OutputAnchor: Codable, Hashable {
    case direct(layerID: EntityID, property: String)
    case component(path: [OccurrenceFrame], layerID: EntityID, property: String)
}

private struct AnchoredOutput: Codable, Equatable {
    var key: SemanticOutputKey
    var anchor: OutputAnchor
    var binding: String
}

private struct AnchoredSemantics: Codable, Equatable {
    var sources: [SemanticSource]
    var outputs: [AnchoredOutput]
    var relations: [SemanticRelation]
}

private enum AnchorFailure: Error { case invalid(String) }

private func paths(to id: EntityID, in root: Layer) -> [[EntityID]] {
    func visit(_ layer: Layer, _ prefix: [EntityID]) -> [[EntityID]] {
        let path = prefix + [layer.id]
        return (layer.id == id ? [path] : []) + layer.children.flatMap { visit($0, path) }
    }
    return visit(root, [])
}

private func layer(at path: [EntityID], in root: Layer) -> Layer? {
    guard path.first == root.id else { return nil }
    var current = root
    for id in path.dropFirst() {
        let matches = current.children.filter { $0.id == id }
        guard matches.count == 1 else { return nil }
        current = matches[0]
    }
    return current
}

private struct ResolvedAnchor {
    var layer: Layer
    var physicalKey: OutputAnchor
}

private func resolve(_ anchor: OutputAnchor, screen: Screen, document: Document) throws -> ResolvedAnchor {
    var current = screen.root
    var raw = screen.root
    var replacedSlotIDs = Set<EntityID>()
    var targetID: EntityID
    var property: String
    switch anchor {
    case .direct(let id, let field):
        targetID = id
        property = field
    case .component(let frames, let id, let field):
        guard !frames.isEmpty else { throw AnchorFailure.invalid("empty occurrence path") }
        targetID = id
        property = field
        for frame in frames {
            let currentPaths = paths(to: frame.instanceLayerID, in: current)
            let rawPaths = paths(to: frame.instanceLayerID, in: raw)
            guard currentPaths == [frame.layerPath], rawPaths == [frame.layerPath],
                  !frame.layerPath.dropLast().contains(where: replacedSlotIDs.contains),
                  let instanceLayer = layer(at: frame.layerPath, in: current),
                  let instance = instanceLayer.component,
                  instance.definitionID == frame.definitionID else {
                throw AnchorFailure.invalid("instance path or definition")
            }
            let matches = document.components.filter { $0.id == frame.definitionID }
            guard matches.count == 1 else { throw AnchorFailure.invalid("definition missing or duplicated") }
            let definition = matches[0]
            current = try ComponentResolver.resolve(instance, definition: definition)
            raw = definition.root
            replacedSlotIDs = Set(definition.api.slots.filter { instance.slotContent[$0.name] != nil }.map(\.targetLayerID))
        }
    }
    guard property == "text" else { throw AnchorFailure.invalid("unsupported property") }
    let currentPaths = paths(to: targetID, in: current)
    let rawPaths = paths(to: targetID, in: raw)
    guard currentPaths.count == 1, rawPaths == currentPaths,
          !currentPaths[0].dropLast().contains(where: replacedSlotIDs.contains),
          let target = layer(at: currentPaths[0], in: current),
          target.kind == .text || target.kind == .button else {
        throw AnchorFailure.invalid("target missing, ambiguous, replaced, or wrong kind")
    }
    return ResolvedAnchor(layer: target, physicalKey: anchor)
}

private func validate(_ semantics: AnchoredSemantics, screen: Screen, document: Document) throws {
    let sourceGroups = Dictionary(grouping: semantics.sources, by: \.key)
    let outputGroups = Dictionary(grouping: semantics.outputs, by: \.key)
    guard sourceGroups.allSatisfy({ !$0.key.rawValue.isEmpty && $0.value.count == 1 }),
          outputGroups.allSatisfy({ !$0.key.rawValue.isEmpty && $0.value.count == 1 }) else {
        throw AnchorFailure.invalid("source or output identity")
    }
    var physical = Set<OutputAnchor>()
    for output in semantics.outputs {
        let resolved = try resolve(output.anchor, screen: screen, document: document)
        guard !output.binding.isEmpty, resolved.layer.textBinding == output.binding,
              physical.insert(resolved.physicalKey).inserted else {
            throw AnchorFailure.invalid("binding or duplicate physical target")
        }
    }
    let relationGroups = Dictionary(grouping: semantics.relations, by: \.output)
    guard semantics.outputs.allSatisfy({ relationGroups[$0.key]?.count == 1 }) else {
        throw AnchorFailure.invalid("output relation count")
    }
    for relation in semantics.relations {
        guard outputGroups[relation.output]?.count == 1,
              relation.dependencies.allSatisfy({ sourceGroups[$0]?.count == 1 }) else {
            throw AnchorFailure.invalid("undeclared relation reference")
        }
        if case .booleanEquals(let key, _) = relation.visibleWhen,
           sourceGroups[key]?.first?.valueKind != .boolean {
            throw AnchorFailure.invalid("visibility source type")
        }
    }
}

private func project(_ semantics: AnchoredSemantics, screenID: EntityID, document: Document) throws -> IntegrationContract {
    guard let screen = document.screens.first(where: { $0.id == screenID }) else {
        throw AnchorFailure.invalid("screen missing")
    }
    try validate(semantics, screen: screen, document: document)
    var contract = try IntegrationContracts.make(screenID: screenID, document: document)
    contract.semanticSources = semantics.sources.sorted { $0.key < $1.key }
    contract.relations = semantics.relations.sorted { $0.output < $1.output }
    return contract
}

final class ComponentOutputAnchorSpikeTests: XCTestCase {
    private let screenID = EntityID("screen_profile")
    private let cardID = EntityID("component_card")
    private let nestedID = EntityID("component_badge")

    private func frame(_ instance: String, _ definition: String, _ path: [String]) -> OccurrenceFrame {
        .init(instanceLayerID: EntityID(instance), definitionID: EntityID(definition), layerPath: path.map(EntityID.init))
    }

    private func output(_ key: String, _ anchor: OutputAnchor, _ binding: String) -> AnchoredOutput {
        .init(key: SemanticOutputKey(key), anchor: anchor, binding: binding)
    }

    private func semantics(_ outputs: [AnchoredOutput]) -> AnchoredSemantics {
        let sources = [SemanticSource(key: .init("source.name"), valueKind: .text)]
        let relations = outputs.map { SemanticRelation(output: $0.key, source: .init("source.name")) }
        return .init(sources: sources, outputs: outputs, relations: relations)
    }

    private func fixture() -> Document {
        var document = Document(name: "Occurrence Anchor")
        let scope = document.scopes[0].id
        let nestedText = Layer(id: EntityID("nested_label"), name: "Nested label",
                               payload: .text(.init(value: "Nested", binding: "profile.nested")))
        let nested = ComponentDefinition(id: nestedID, name: "Badge", ownerScopeID: scope,
                                         root: Layer(id: EntityID("badge_root"), name: "Badge root", payload: .stack, children: [nestedText]))
        let label = Layer(id: EntityID("card_label"), name: "Card label",
                          payload: .text(.init(value: "Default", binding: "profile.name")))
        let slotDefault = Layer(id: EntityID("slot_default"), name: "Default slot",
                                payload: .text(.init(value: "Default slot", binding: "profile.default")))
        let slot = Layer(id: EntityID("card_slot"), name: "Slot", payload: .stack, children: [slotDefault])
        let nestedInstance = Layer(id: EntityID("nested_instance"), name: "Nested instance",
                                   payload: .componentInstance(.init(instance: .init(definitionID: nestedID))))
        var card = ComponentDefinition(id: cardID, name: "ProfileHeader", ownerScopeID: scope,
                                       root: Layer(id: EntityID("card_root"), name: "Card root", payload: .stack,
                                                   children: [label, slot, nestedInstance]))
        card.api.properties = [.init(name: "label", kind: .text, targetPath: "card_label.text")]
        card.api.slots = [.init(name: "trailing", targetLayerID: slot.id)]
        card.variants = [.init(id: EntityID("variant_large"), axis: "size", value: "large",
                               propertyOverrides: ["card_label.text": "Large"])]
        document.components = [card, nested]
        let supplied = Layer(id: EntityID("slot_supplied"), name: "Supplied",
                             payload: .text(.init(value: "Avatar", binding: "profile.avatar")))
        let left = Layer(id: EntityID("instance_left"), name: "Left", payload: .componentInstance(.init(
            instance: .init(definitionID: cardID, variantSelection: ["size": "large"],
                            slotContent: ["trailing": [supplied]]))))
        let right = Layer(id: EntityID("instance_right"), name: "Right", payload: .componentInstance(.init(
            instance: .init(definitionID: cardID))))
        let direct = Layer(id: EntityID("direct_name"), name: "Direct",
                           payload: .text(.init(value: "Direct", binding: "profile.direct")))
        let root = Layer(id: EntityID("screen_root"), name: "Screen root", payload: .stack,
                         children: [direct, left, right])
        document.screens = [.init(id: screenID, name: "Profile", scopeID: scope, root: root)]
        return document
    }

    private var left: OutputAnchor {
        .component(path: [frame("instance_left", "component_card", ["screen_root", "instance_left"])],
                   layerID: EntityID("card_label"), property: "text")
    }
    private var right: OutputAnchor {
        .component(path: [frame("instance_right", "component_card", ["screen_root", "instance_right"])],
                   layerID: EntityID("card_label"), property: "text")
    }
    private var nested: OutputAnchor {
        .component(path: [frame("instance_left", "component_card", ["screen_root", "instance_left"]),
                          frame("nested_instance", "component_badge", ["card_root", "nested_instance"])],
                   layerID: EntityID("nested_label"), property: "text")
    }

    func testResolvedOccurrencesVariantSlotAndProjection() throws {
        let document = fixture()
        let screen = try XCTUnwrap(document.screens.first)
        let leftTarget = try resolve(left, screen: screen, document: document)
        let rightTarget = try resolve(right, screen: screen, document: document)
        XCTAssertEqual(leftTarget.layer.text, "Large")
        XCTAssertEqual(rightTarget.layer.text, "Default")
        XCTAssertEqual(leftTarget.layer.textBinding, "profile.name")
        XCTAssertEqual(rightTarget.layer.textBinding, "profile.name")
        XCTAssertNotEqual(leftTarget.physicalKey, rightTarget.physicalKey)
        XCTAssertEqual(try resolve(nested, screen: screen, document: document).layer.textBinding, "profile.nested")
        let outputs = [output("left", left, "profile.name"), output("right", right, "profile.name"),
                       output("nested", nested, "profile.nested"),
                       output("direct", .direct(layerID: EntityID("direct_name"), property: "text"), "profile.direct")]
        let contract = try project(semantics(outputs), screenID: screenID, document: document)
        XCTAssertEqual(contract.semanticSources?.map(\.key.rawValue), ["source.name"])
        XCTAssertEqual(contract.relations?.map(\.output.rawValue), ["direct", "left", "nested", "right"])
        XCTAssertEqual(contract.inputs, ["profile.avatar", "profile.default", "profile.direct", "profile.name", "profile.nested"])
    }

    func testInvalidPathsBindingsAndPhysicalDuplicatesFailClosed() throws {
        let document = fixture()
        let screen = try XCTUnwrap(document.screens.first)
        let invalid: [AnchoredOutput] = [
            output("bare", .direct(layerID: EntityID("card_label"), property: "text"), "profile.name"),
            output("empty", .component(path: [], layerID: EntityID("card_label"), property: "text"), "profile.name"),
            output("missingInstance", .component(path: [frame("missing", "component_card", ["screen_root", "missing"])], layerID: EntityID("card_label"), property: "text"), "profile.name"),
            output("wrongOrder", .component(path: [frame("instance_left", "component_card", ["instance_left", "screen_root"])], layerID: EntityID("card_label"), property: "text"), "profile.name"),
            output("wrongDefinition", .component(path: [frame("instance_left", "component_badge", ["screen_root", "instance_left"])], layerID: EntityID("card_label"), property: "text"), "profile.name"),
            output("missingTarget", .component(path: [frame("instance_left", "component_card", ["screen_root", "instance_left"])], layerID: EntityID("missing"), property: "text"), "profile.name"),
            output("wrongProperty", .component(path: [frame("instance_left", "component_card", ["screen_root", "instance_left"])], layerID: EntityID("card_label"), property: "image"), "profile.name"),
            output("wrongKind", .component(path: [frame("instance_left", "component_card", ["screen_root", "instance_left"])], layerID: EntityID("card_slot"), property: "text"), "profile.name"),
            output("wrongBinding", left, "profile.other"),
            output("slotInjected", .component(path: [frame("instance_left", "component_card", ["screen_root", "instance_left"])], layerID: EntityID("slot_supplied"), property: "text"), "profile.avatar"),
            output("slotRemoved", .component(path: [frame("instance_left", "component_card", ["screen_root", "instance_left"])], layerID: EntityID("slot_default"), property: "text"), "profile.default"),
            output("nestedOrder", .component(path: [frame("instance_left", "component_card", ["screen_root", "instance_left"]), frame("nested_instance", "component_badge", ["nested_instance", "card_root"])], layerID: EntityID("nested_label"), property: "text"), "profile.nested")
        ]
        for candidate in invalid {
            XCTAssertThrowsError(try validate(semantics([candidate]), screen: screen, document: document), candidate.key.rawValue)
        }
        XCTAssertThrowsError(try validate(semantics([output("a", left, "profile.name"), output("b", left, "profile.name")]), screen: screen, document: document))
        XCTAssertThrowsError(try validate(semantics([output("same", left, "profile.name"), output("same", right, "profile.name")]), screen: screen, document: document))
    }

    func testVariantAndSlotChangesAreCheckedAgainstResolvedTree() throws {
        var document = fixture()
        let screen = try XCTUnwrap(document.screens.first)
        let original = try resolve(left, screen: screen, document: document)
        XCTAssertEqual(original.layer.text, "Large")
        document.screens[0].root.children[1].component?.variantSelection["size"] = "unknown"
        XCTAssertThrowsError(try resolve(left, screen: document.screens[0], document: document))
        document = fixture()
        document.screens[0].root.children[1].component?.slotContent["trailing"] = []
        let slotAnchor = OutputAnchor.component(path: [frame("instance_left", "component_card", ["screen_root", "instance_left"])], layerID: EntityID("slot_supplied"), property: "text")
        XCTAssertThrowsError(try resolve(slotAnchor, screen: document.screens[0], document: document))
        XCTAssertEqual(try resolve(left, screen: document.screens[0], document: document).layer.textBinding, "profile.name")
        document = fixture()
        let defaultSlotAnchor = OutputAnchor.component(
            path: [frame("instance_right", "component_card", ["screen_root", "instance_right"])],
            layerID: EntityID("slot_default"), property: "text")
        XCTAssertEqual(try resolve(defaultSlotAnchor, screen: document.screens[0], document: document).layer.textBinding, "profile.default")
        document.screens[0].root.children[2].component?.slotContent["trailing"] = []
        XCTAssertThrowsError(try resolve(defaultSlotAnchor, screen: document.screens[0], document: document))
    }

    func testCodableAndCandidateByteIdentity() throws {
        let document = fixture()
        let values = semantics([output("left", left, "profile.name"), output("nested", nested, "profile.nested"),
                                output("direct", .direct(layerID: EntityID("direct_name"), property: "text"), "profile.direct")])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let original = try encoder.encode(values)
        let decoded = try JSONDecoder().decode(AnchoredSemantics.self, from: original)
        XCTAssertEqual(values, decoded)
        XCTAssertEqual(original, try encoder.encode(decoded))
        var changed = values
        changed.outputs[0].anchor = right
        let changedBytes = try encoder.encode(changed)
        XCTAssertNotEqual(original, changedBytes)
        let screenBytes = try encoder.encode(document.screens[0])
        XCTAssertNotEqual(CanonicalByteIdentity.compute(files: ["screens/\(screenID.rawValue).json": screenBytes, "candidate-semantics.json": original]),
                          CanonicalByteIdentity.compute(files: ["screens/\(screenID.rawValue).json": screenBytes, "candidate-semantics.json": changedBytes]))
    }
}
