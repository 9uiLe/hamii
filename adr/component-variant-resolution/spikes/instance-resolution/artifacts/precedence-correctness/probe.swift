import Foundation
import HamiiCore

private let definitionID = EntityID("component_primary")
private let nestedDefinitionID = EntityID("component_nested")
private let labelID = EntityID("layer_label")
private let secondaryID = EntityID("layer_secondary")
private let slotID = EntityID("layer_slot")
private let slotTextID = EntityID("layer_slot_text")
private let nestedID = EntityID("layer_nested_instance")

private func fixture() -> ComponentDefinition {
    let label = Layer(id: labelID, kind: .text, name: "Label", text: "Default")
    let secondary = Layer(id: secondaryID, kind: .text, name: "Secondary", text: "Secondary")
    let slotText = Layer(id: slotTextID, kind: .text, name: "Slot text", text: "SlotDefault")
    let slot = Layer(id: slotID, kind: .stack, name: "Slot", children: [slotText])
    let nested = Layer(id: nestedID, kind: .componentInstance, name: "Nested",
                       component: ComponentInstance(definitionID: nestedDefinitionID))
    var definition = ComponentDefinition(id: definitionID, name: "Primary", ownerScopeID: EntityID("scope_app"),
        root: Layer(id: EntityID("layer_root"), kind: .stack, name: "Root",
                    children: [label, secondary, slot, nested]))
    definition.api = ComponentAPI(properties: [
        ComponentProperty(name: "label", kind: .text, targetPath: "layer_label.text"),
        ComponentProperty(name: "slotLabel", kind: .text, targetPath: "layer_slot_text.text")
    ], slots: [ComponentSlot(name: "content", targetLayerID: slotID)],
       overridablePaths: ["layer_label.text", "layer_slot_text.text"])
    definition.variants = [
        ComponentVariant(id: EntityID("variant_large"), axis: "size", value: "large",
                         propertyOverrides: ["layer_label.text": "Large"]),
        ComponentVariant(id: EntityID("variant_loading"), axis: "state", value: "loading",
                         propertyOverrides: ["layer_secondary.text": "Loading"]),
        ComponentVariant(id: EntityID("variant_pressed"), axis: "state", value: "pressed",
                         propertyOverrides: ["layer_label.text": "Pressed"])
    ]
    return definition
}

private func find(_ id: EntityID, in layer: Layer) -> Layer? {
    if layer.id == id { return layer }
    for child in layer.children {
        if let found = find(id, in: child) { return found }
    }
    return nil
}

private func errorCode(_ error: Error) -> String {
    guard let error = error as? ComponentResolutionError else { return "unexpectedError" }
    switch error {
    case .unknownVariant(let axis, let value): return "unknownVariant:\(axis)=\(value)"
    case .conflictingVariants(let path): return "conflictingVariants:\(path)"
    case .forbiddenOverride(let path): return "forbiddenOverride:\(path)"
    case .unknownPath(let path): return "unknownPath:\(path)"
    case .unknownProperty(let name): return "unknownProperty:\(name)"
    case .unknownSlot(let name): return "unknownSlot:\(name)"
    }
}

private func result(_ definition: ComponentDefinition, _ instance: ComponentInstance) -> [String: String] {
    do {
        let resolved = try ComponentResolver.resolve(instance, definition: definition)
        let slotChildren = find(slotID, in: resolved)?.children.map(\.id.rawValue).joined(separator: ",") ?? "missingSlot"
        let nested = find(nestedID, in: resolved)
        return ["status": "resolved", "label": find(labelID, in: resolved)?.text ?? "missing",
                "secondary": find(secondaryID, in: resolved)?.text ?? "missing",
                "slotText": find(slotTextID, in: resolved)?.text ?? "missing",
                "slotChildren": slotChildren,
                "nestedKind": nested?.kind.rawValue ?? "missing",
                "nestedDefinitionID": nested?.component?.definitionID.rawValue ?? "missing",
                "definitionBaseLabel": find(labelID, in: definition.root)?.text ?? "missing"]
    } catch {
        return ["status": "error", "error": errorCode(error)]
    }
}

@main private enum Probe {
    static func main() throws {
        let definition = fixture()
        let base = ComponentInstance(definitionID: definitionID)
        var rows: [[String: Any]] = []
        func check(_ name: String, _ definition: ComponentDefinition, _ instance: ComponentInstance,
                   expected: [String: String]) {
            let observed = result(definition, instance)
            let matched = expected.allSatisfy { observed[$0.key] == $0.value }
            rows.append(["case": name, "expected": expected, "observed": observed, "passed": matched])
        }

        check("base-reference-and-nested-nonrecursive", definition, base,
              expected: ["status": "resolved", "label": "Default", "definitionBaseLabel": "Default",
                         "nestedKind": "componentInstance", "nestedDefinitionID": nestedDefinitionID.rawValue])
        check("single-axis", definition,
              ComponentInstance(definitionID: definitionID, variantSelection: ["size": "large"]),
              expected: ["status": "resolved", "label": "Large", "secondary": "Secondary"])
        check("two-axes-disjoint-paths", definition,
              ComponentInstance(definitionID: definitionID,
                                variantSelection: ["state": "loading", "size": "large"]),
              expected: ["status": "resolved", "label": "Large", "secondary": "Loading"])
        var selectionSizeFirst: [String: String] = [:]
        selectionSizeFirst["size"] = "large"
        selectionSizeFirst["state"] = "loading"
        var selectionStateFirst: [String: String] = [:]
        selectionStateFirst["state"] = "loading"
        selectionStateFirst["size"] = "large"
        var definitionReordered = definition
        definitionReordered.variants.reverse()
        let sizeFirst = ComponentInstance(definitionID: definitionID,
                                          variantSelection: selectionSizeFirst)
        let stateFirst = ComponentInstance(definitionID: definitionID,
                                           variantSelection: selectionStateFirst)
        let treeSizeFirst = try? ComponentResolver.resolve(sizeFirst, definition: definition)
        let treeStateFirst = try? ComponentResolver.resolve(stateFirst, definition: definitionReordered)
        let equalTrees = treeSizeFirst != nil && treeSizeFirst == treeStateFirst
        rows.append(["case": "disjoint-axes-order-independence",
                     "expected": ["resolvedTreeEqual": true],
                     "observed": ["resolvedTreeEqual": equalTrees,
                                  "selectionInsertionOrderA": ["size", "state"],
                                  "selectionInsertionOrderB": ["state", "size"],
                                  "definitionVariantOrderA": definition.variants.map(\.id.rawValue),
                                  "definitionVariantOrderB": definitionReordered.variants.map(\.id.rawValue),
                                  "treeA": result(definition, sizeFirst),
                                  "treeB": result(definitionReordered, stateFirst)],
                     "passed": equalTrees])
        check("two-axes-same-path-conflict", definition,
              ComponentInstance(definitionID: definitionID,
                                variantSelection: ["state": "pressed", "size": "large"]),
              expected: ["status": "error", "error": "conflictingVariants:layer_label.text"])
        var sameValue = definition
        sameValue.variants[2].propertyOverrides["layer_label.text"] = "Large"
        check("two-axes-same-path-same-value-conflict", sameValue,
              ComponentInstance(definitionID: definitionID,
                                variantSelection: ["state": "pressed", "size": "large"]),
              expected: ["status": "error", "error": "conflictingVariants:layer_label.text"])
        check("variant-then-property", definition,
              ComponentInstance(definitionID: definitionID, variantSelection: ["size": "large"],
                                propertyValues: ["label": "Property"]),
              expected: ["status": "resolved", "label": "Property", "definitionBaseLabel": "Default"])
        check("property-then-allowed-override", definition,
              ComponentInstance(definitionID: definitionID, variantSelection: ["size": "large"],
                                propertyValues: ["label": "Property"],
                                allowedOverrides: ["layer_label.text": "Override"]),
              expected: ["status": "resolved", "label": "Override"])

        let replacement = Layer(id: EntityID("layer_replacement"), kind: .text,
                                name: "Replacement", text: "Slot replacement")
        check("property-then-slot-replacement-drops-property-target", definition,
              ComponentInstance(definitionID: definitionID,
                                propertyValues: ["slotLabel": "Property slot"],
                                slotContent: ["content": [replacement]]),
              expected: ["status": "resolved", "slotText": "missing",
                         "slotChildren": "layer_replacement"])
        var variantOnSlotChild = definition
        variantOnSlotChild.variants.append(ComponentVariant(id: EntityID("variant_slot_alternate"),
            axis: "slotState", value: "alternate",
            propertyOverrides: ["layer_slot_text.text": "Variant slot"] ))
        check("variant-then-slot-replacement-drops-variant-target", variantOnSlotChild,
              ComponentInstance(definitionID: definitionID,
                                variantSelection: ["slotState": "alternate"],
                                slotContent: ["content": [replacement]]),
              expected: ["status": "resolved", "slotText": "missing",
                         "slotChildren": "layer_replacement"])
        check("slot-replacement-then-override-loses-path", definition,
              ComponentInstance(definitionID: definitionID,
                                slotContent: ["content": [replacement]],
                                allowedOverrides: ["layer_slot_text.text": "Override slot"]),
              expected: ["status": "error", "error": "unknownPath:layer_slot_text.text"])

        check("unknown-variant", definition,
              ComponentInstance(definitionID: definitionID, variantSelection: ["size": "huge"]),
              expected: ["status": "error", "error": "unknownVariant:size=huge"])
        check("unknown-property", definition,
              ComponentInstance(definitionID: definitionID, propertyValues: ["unknown": "x"]),
              expected: ["status": "error", "error": "unknownProperty:unknown"])
        check("unknown-slot", definition,
              ComponentInstance(definitionID: definitionID, slotContent: ["unknown": [replacement]]),
              expected: ["status": "error", "error": "unknownSlot:unknown"])
        check("forbidden-override", definition,
              ComponentInstance(definitionID: definitionID,
                                allowedOverrides: ["layer_secondary.text": "x"]),
              expected: ["status": "error", "error": "forbiddenOverride:layer_secondary.text"])
        var badPath = definition
        badPath.api.properties.append(ComponentProperty(name: "bad", kind: .text,
                                                       targetPath: "layer_missing.text"))
        check("unknown-path", badPath,
              ComponentInstance(definitionID: definitionID, propertyValues: ["bad": "x"]),
              expected: ["status": "error", "error": "unknownPath:layer_missing.text"])

        let passed = rows.allSatisfy { ($0["passed"] as? Bool) == true }
        let report: [String: Any] = [
            "sourceCommit": ProcessInfo.processInfo.environment["HAMII_SOURCE_COMMIT"] ?? "unspecified",
            "fixture": "one fixed ComponentDefinition with two text properties, a replaceable slot, three sparse variants, and one nested instance reference",
            "cases": rows,
            "caseCount": rows.count,
            "passed": passed,
            "classification": [
                "Confirmed": "direct ComponentResolver behavior for fixed fixture and listed cases",
                "Measured": "one run, 16 cases, no latency benchmark",
                "Unknown": "DocumentValidator acceptance, cross-definition expansion, cache invalidation, 1k-instance scaling, and target generation"
            ]
        ]
        let bytes = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
        FileHandle.standardOutput.write(bytes)
        FileHandle.standardOutput.write(Data("\n".utf8))
        if !passed { exit(1) }
    }
}
