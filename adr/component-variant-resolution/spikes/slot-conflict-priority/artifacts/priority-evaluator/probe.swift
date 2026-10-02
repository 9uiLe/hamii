import Foundation
import HamiiCore

// A test-only candidate for one error-priority boundary. No production type,
// error case, schema, or ComponentResolver implementation is changed.
private let definitionID = EntityID("component_priority")
private let outerID = EntityID("layer_outer_slot")
private let innerID = EntityID("layer_inner_slot")
private let oldID = EntityID("layer_old_text")
private let outsideID = EntityID("layer_outside_text")
private let oldPath = "layer_old_text.text"
private let outsidePath = "layer_outside_text.text"

private func fixture() -> ComponentDefinition {
    let old = Layer(id: oldID, kind: .text, name: "Old", text: "Old")
    let inner = Layer(id: innerID, kind: .stack, name: "Inner", children: [old])
    let outer = Layer(id: outerID, kind: .stack, name: "Outer", children: [inner])
    let outside = Layer(id: outsideID, kind: .text, name: "Outside", text: "Outside")
    var definition = ComponentDefinition(id: definitionID, name: "Priority fixture",
        ownerScopeID: EntityID("scope_app"),
        root: Layer(id: EntityID("layer_root"), kind: .stack, name: "Root",
                    children: [outer, outside]))
    definition.api = ComponentAPI(properties: [
        ComponentProperty(name: "oldLabel", kind: .text, targetPath: oldPath),
        ComponentProperty(name: "outsideLabel", kind: .text, targetPath: outsidePath)
    ], slots: [ComponentSlot(name: "inner", targetLayerID: innerID),
              ComponentSlot(name: "outer", targetLayerID: outerID)],
       overridablePaths: [oldPath])
    definition.variants = [
        ComponentVariant(id: EntityID("variant_state_active"), axis: "state", value: "active",
                         propertyOverrides: [oldPath: "Variant"]),
        ComponentVariant(id: EntityID("variant_state_idle"), axis: "state", value: "idle",
                         propertyOverrides: [oldPath: "Unselected"]),
        ComponentVariant(id: EntityID("variant_size_large"), axis: "size", value: "large",
                         propertyOverrides: [oldPath: "Second selected variant"]),
        ComponentVariant(id: EntityID("variant_tone_loud"), axis: "tone", value: "loud",
                         propertyOverrides: [outsidePath: "Outside variant"])
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

private func validTextPath(_ path: String, in root: Layer) -> Bool {
    let pieces = path.split(separator: ".").map(String.init)
    guard pieces.count == 2, pieces[1] == "text",
          let target = find(EntityID(pieces[0]), in: root) else { return false }
    return target.kind == .text || target.kind == .button
}

private func validSlot(_ name: String, definition: ComponentDefinition) -> Bool {
    guard let slot = definition.api.slots.first(where: { $0.name == name }),
          let target = find(slot.targetLayerID, in: definition.root) else { return false }
    return [.stack, .overlay, .scroll].contains(target.kind)
}

private func selectedVariants(_ instance: ComponentInstance,
                              definition: ComponentDefinition) -> [ComponentVariant]? {
    var variants: [ComponentVariant] = []
    for axis in instance.variantSelection.keys.sorted() {
        let value = instance.variantSelection[axis]!
        guard let variant = definition.variants.first(where: { $0.axis == axis && $0.value == value }) else {
            return nil
        }
        variants.append(variant)
    }
    return variants
}

/// Existing selection/API error categories are checked before the new conflict.
/// This fixed-fixture prototype does not claim complete equivalence of every
/// error-precedence combination in the production resolver.
private func existingValidityError(_ instance: ComponentInstance,
                                   definition: ComponentDefinition) -> String? {
    for axis in instance.variantSelection.keys.sorted() {
        let value = instance.variantSelection[axis]!
        guard let variant = definition.variants.first(where: { $0.axis == axis && $0.value == value }) else {
            return "unknownVariant:\(axis)=\(value)"
        }
        for path in variant.propertyOverrides.keys.sorted() where !validTextPath(path, in: definition.root) {
            return "unknownPath:\(path)"
        }
    }
    for name in instance.propertyValues.keys.sorted() {
        guard let property = definition.api.properties.first(where: { $0.name == name }) else {
            return "unknownProperty:\(name)"
        }
        guard property.kind == .text, validTextPath(property.targetPath, in: definition.root) else {
            return "unknownPath:\(property.targetPath)"
        }
    }
    for name in instance.slotContent.keys.sorted() where !validSlot(name, definition: definition) {
        return "unknownSlot:\(name)"
    }
    for path in instance.allowedOverrides.keys.sorted() where !definition.api.overridablePaths.contains(path) {
        return "forbiddenOverride:\(path)"
    }
    return nil
}

private func selectedVariantPathConflict(_ variants: [ComponentVariant]) -> String? {
    var seen = Set<String>()
    for variant in variants {
        for path in variant.propertyOverrides.keys.sorted() {
            if !seen.insert(path).inserted { return "conflictingVariants:\(path)" }
        }
    }
    return nil
}

private func strictlyContains(_ id: EntityID, below layer: Layer) -> Bool {
    layer.children.contains { child in
        child.id == id || strictlyContains(id, below: child)
    }
}

private func slotNamesDeleting(path: String, instance: ComponentInstance,
                               definition: ComponentDefinition) -> [String] {
    let parts = path.split(separator: ".").map(String.init)
    guard parts.count == 2, parts[1] == "text" else { return [] }
    let targetID = EntityID(parts[0])
    return instance.slotContent.keys.sorted().filter { name in
        guard let slot = definition.api.slots.first(where: { $0.name == name }),
              let target = find(slot.targetLayerID, in: definition.root) else { return false }
        // The slot target itself is excluded: only its old descendants go.
        return strictlyContains(targetID, below: target)
    }
}

private func selectedWritePaths(_ variants: [ComponentVariant],
                                instance: ComponentInstance,
                                definition: ComponentDefinition) -> [String] {
    var paths = Set<String>()
    for variant in variants { paths.formUnion(variant.propertyOverrides.keys) }
    for name in instance.propertyValues.keys {
        if let property = definition.api.properties.first(where: { $0.name == name }) {
            paths.insert(property.targetPath)
        }
    }
    // allowedOverrides are deliberately excluded from the new conflict.
    return paths.sorted()
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

private func current(_ instance: ComponentInstance,
                     definition: ComponentDefinition) -> [String: Any] {
    do {
        let tree = try ComponentResolver.resolve(instance, definition: definition)
        return ["status": "resolved",
                "oldText": find(oldID, in: tree)?.text ?? "missing",
                "outsideText": find(outsideID, in: tree)?.text ?? "missing"]
    } catch { return ["status": "error", "error": errorCode(error)] }
}

private func candidate(_ instance: ComponentInstance,
                       definition: ComponentDefinition) -> [String: Any] {
    if let error = existingValidityError(instance, definition: definition) {
        return ["status": "error", "error": error, "phase": "existingValidity"]
    }
    let variants = selectedVariants(instance, definition: definition)!
    if let error = selectedVariantPathConflict(variants) {
        return ["status": "error", "error": error, "phase": "variantConflict"]
    }
    for path in selectedWritePaths(variants, instance: instance, definition: definition) {
        let slots = slotNamesDeleting(path: path, instance: instance, definition: definition)
        if !slots.isEmpty {
            return ["status": "error", "error": "slotWriteConflict", "path": path,
                    "slotNames": slots, "phase": "selectedWriteConflict"]
        }
    }
    var resolved = current(instance, definition: definition)
    resolved["phase"] = "currentResolver"
    return resolved
}

@main private enum Probe {
    static func main() throws {
        let definition = fixture()
        let replacement = Layer(id: EntityID("layer_new"), kind: .text, name: "New", text: "New")
        var rows: [[String: Any]] = []
        func check(_ name: String, _ instance: ComponentInstance,
                   definition selectedDefinition: ComponentDefinition,
                   error: String? = nil, path: String? = nil,
                   slots: [String]? = nil, oldText: String? = nil,
                   outsideText: String? = nil, phase: String? = nil) {
            let observed = candidate(instance, definition: selectedDefinition)
            let baseline = current(instance, definition: selectedDefinition)
            let passed = (error == nil ? observed["status"] as? String == "resolved" :
                observed["error"] as? String == error) &&
                (path == nil || observed["path"] as? String == path) &&
                (slots == nil || observed["slotNames"] as? [String] == slots) &&
                (oldText == nil || observed["oldText"] as? String == oldText) &&
                (outsideText == nil || observed["outsideText"] as? String == outsideText) &&
                (phase == nil || observed["phase"] as? String == phase)
            var expected: [String: Any] = ["status": error == nil ? "resolved" : "error"]
            if let error { expected["error"] = error }
            if let path { expected["path"] = path }
            if let slots { expected["slotNames"] = slots }
            if let oldText { expected["oldText"] = oldText }
            if let outsideText { expected["outsideText"] = outsideText }
            if let phase { expected["phase"] = phase }
            rows.append(["case": name, "expected": expected, "candidate": observed,
                         "currentResolver": baseline, "passed": passed])
        }
        let active = ["state": "active"]
        check("outer-only-selected-variant", ComponentInstance(definitionID: definitionID,
              variantSelection: active, slotContent: ["outer": [replacement]]),
              definition: definition, error: "slotWriteConflict", path: oldPath,
              slots: ["outer"], phase: "selectedWriteConflict")
        check("inner-only-selected-variant", ComponentInstance(definitionID: definitionID,
              variantSelection: active, slotContent: ["inner": [replacement]]),
              definition: definition, error: "slotWriteConflict", path: oldPath,
              slots: ["inner"])
        check("both-selected-slots", ComponentInstance(definitionID: definitionID,
              variantSelection: active,
              slotContent: ["inner": [replacement], "outer": [replacement]]),
              definition: definition, error: "slotWriteConflict", path: oldPath,
              slots: ["inner", "outer"])
        var reversedInsertion: [String: [Layer]] = [:]
        reversedInsertion["outer"] = [replacement]
        reversedInsertion["inner"] = [replacement]
        check("both-slots-reverse-dictionary-insertion", ComponentInstance(definitionID: definitionID,
              variantSelection: active, slotContent: reversedInsertion),
              definition: definition, error: "slotWriteConflict", path: oldPath,
              slots: ["inner", "outer"])
        var renamed = definition
        renamed.api.slots = [ComponentSlot(name: "zInner", targetLayerID: innerID),
                             ComponentSlot(name: "aOuter", targetLayerID: outerID)]
        check("both-slots-renamed-sorted-set", ComponentInstance(definitionID: definitionID,
              variantSelection: active,
              slotContent: ["zInner": [replacement], "aOuter": [replacement]]),
              definition: renamed, error: "slotWriteConflict", path: oldPath,
              slots: ["aOuter", "zInner"])
        check("empty-outer-slot", ComponentInstance(definitionID: definitionID,
              variantSelection: active, slotContent: ["outer": []]),
              definition: definition, error: "slotWriteConflict", path: oldPath,
              slots: ["outer"])
        check("no-slot", ComponentInstance(definitionID: definitionID, variantSelection: active),
              definition: definition, oldText: "Variant", phase: "currentResolver")
        check("unselected-variant", ComponentInstance(definitionID: definitionID,
              slotContent: ["outer": [replacement]]),
              definition: definition, oldText: "missing", phase: "currentResolver")
        check("outside-selected-variant", ComponentInstance(definitionID: definitionID,
              variantSelection: ["tone": "loud"], slotContent: ["outer": [replacement]]),
              definition: definition, outsideText: "Outside variant", phase: "currentResolver")
        check("property-old-child", ComponentInstance(definitionID: definitionID,
              propertyValues: ["oldLabel": "Property"], slotContent: ["outer": [replacement]]),
              definition: definition, error: "slotWriteConflict", path: oldPath,
              slots: ["outer"])
        check("public-removed-override-preserves-unknown-path",
              ComponentInstance(definitionID: definitionID,
                  slotContent: ["outer": [replacement]], allowedOverrides: [oldPath: "Override"]),
              definition: definition, error: "unknownPath:\(oldPath)", phase: "currentResolver")
        check("forbidden-override-priority", ComponentInstance(definitionID: definitionID,
              variantSelection: active, slotContent: ["outer": [replacement]],
              allowedOverrides: [outsidePath: "Forbidden"]),
              definition: definition, error: "forbiddenOverride:\(outsidePath)",
              phase: "existingValidity")
        check("unknown-variant-priority", ComponentInstance(definitionID: definitionID,
              variantSelection: ["state": "missing"], propertyValues: ["oldLabel": "Property"],
              slotContent: ["outer": [replacement]]),
              definition: definition, error: "unknownVariant:state=missing", phase: "existingValidity")
        check("unknown-property-priority", ComponentInstance(definitionID: definitionID,
              variantSelection: active, propertyValues: ["missing": "Property"],
              slotContent: ["outer": [replacement]]),
              definition: definition, error: "unknownProperty:missing", phase: "existingValidity")
        check("unknown-slot-priority", ComponentInstance(definitionID: definitionID,
              variantSelection: active,
              slotContent: ["outer": [replacement], "missing": []]),
              definition: definition, error: "unknownSlot:missing", phase: "existingValidity")
        check("duplicate-variant-path-priority", ComponentInstance(definitionID: definitionID,
              variantSelection: ["state": "active", "size": "large"],
              slotContent: ["outer": [replacement]]),
              definition: definition, error: "conflictingVariants:\(oldPath)",
              phase: "variantConflict")
        check("mixed-invalidity-priority-divergence", ComponentInstance(definitionID: definitionID,
              variantSelection: ["state": "active", "size": "large"],
              slotContent: ["outer": [replacement]],
              allowedOverrides: [outsidePath: "Forbidden"]),
              definition: definition, error: "forbiddenOverride:\(outsidePath)",
              phase: "existingValidity")
        var badProperty = definition
        badProperty.api.properties.append(ComponentProperty(name: "invalid", kind: .number,
                                                            targetPath: oldPath))
        check("invalid-property-kind-priority", ComponentInstance(definitionID: definitionID,
              variantSelection: active, propertyValues: ["invalid": "1"],
              slotContent: ["outer": [replacement]]),
              definition: badProperty, error: "unknownPath:\(oldPath)", phase: "existingValidity")

        let passed = rows.allSatisfy { ($0["passed"] as? Bool) == true }
        let report: [String: Any] = [
            "sourceCommit": ProcessInfo.processInfo.environment["HAMII_SOURCE_COMMIT"] ?? "unspecified",
            "candidateAlgorithm": ["existing selection/API validity", "selected variant duplicate path",
                                   "selected variant/property silent-discard conflict with sorted full slot-name set",
                                   "current ComponentResolver; allowedOverrides excluded from new conflict"],
            "cases": rows, "caseCount": rows.count, "passed": passed,
            "classification": [
                "Confirmed": "current resolver control outcomes and test-only candidate outcomes for fixed cases",
                "Measured": "one run, 18 cases; no latency measurement",
                "Inferred": "a prior validity/variant-conflict phase may preserve tested errors while rejecting silent discard",
                "Unknown": "complete error-priority equivalence, nested slot runtime ordering, Definition validation, generated/persisted instance behavior, performance"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        if !passed { exit(1) }
    }
}
