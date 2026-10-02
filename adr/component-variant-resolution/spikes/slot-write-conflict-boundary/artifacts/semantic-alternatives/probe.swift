import Foundation
import HamiiCore

// Test-only semantic alternatives. None of these helpers are production API.
private let definitionID = EntityID("component_slot_probe")
private let outerID = EntityID("layer_outer_slot")
private let innerID = EntityID("layer_inner_slot")
private let oldID = EntityID("layer_old_text")
private let outsideID = EntityID("layer_outside_text")
private let oldPath = "layer_old_text.text"
private let outerPath = "layer_outer_slot.text"
private let outsidePath = "layer_outside_text.text"

private struct Write: Comparable {
    let source: String
    let path: String
    let slotName: String
    static func < (lhs: Write, rhs: Write) -> Bool {
        (lhs.source, lhs.path, lhs.slotName) < (rhs.source, rhs.path, rhs.slotName)
    }
    var label: String { "\(source):\(path)@\(slotName)" }
}

private func fixture() -> ComponentDefinition {
    let old = Layer(id: oldID, kind: .text, name: "Old", text: "Old")
    let inner = Layer(id: innerID, kind: .stack, name: "Inner", children: [old])
    let outer = Layer(id: outerID, kind: .stack, name: "Outer", children: [inner])
    let outside = Layer(id: outsideID, kind: .text, name: "Outside", text: "Outside")
    var definition = ComponentDefinition(id: definitionID, name: "Slot probe",
        ownerScopeID: EntityID("scope_app"),
        root: Layer(id: EntityID("layer_root"), kind: .stack, name: "Root",
                    children: [outer, outside]))
    definition.api = ComponentAPI(properties: [
        ComponentProperty(name: "oldLabel", kind: .text, targetPath: oldPath),
        ComponentProperty(name: "outsideLabel", kind: .text, targetPath: outsidePath),
        // Unsupported control: slot targets are containers and cannot take a
        // `.text` write in the current ComponentResolver.
        ComponentProperty(name: "slotTargetText", kind: .text, targetPath: outerPath)
    ], slots: [ComponentSlot(name: "outer", targetLayerID: outerID),
              ComponentSlot(name: "inner", targetLayerID: innerID)],
       overridablePaths: [oldPath, outsidePath, outerPath])
    definition.variants = [
        ComponentVariant(id: EntityID("variant_old"), axis: "state", value: "old",
                         propertyOverrides: [oldPath: "Variant"]),
        ComponentVariant(id: EntityID("variant_unselected"), axis: "state", value: "unselected",
                         propertyOverrides: [oldPath: "Unselected"]),
        ComponentVariant(id: EntityID("variant_outside"), axis: "tone", value: "outside",
                         propertyOverrides: [outsidePath: "Variant outside"])
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

/// Distance zero means the target itself. Conflict membership requires > 0.
private func distance(from layer: Layer, to id: EntityID, depth: Int = 0) -> Int? {
    if layer.id == id { return depth }
    for child in layer.children {
        if let found = distance(from: child, to: id, depth: depth + 1) { return found }
    }
    return nil
}

private func selectedSlot(for path: String, instance: ComponentInstance,
                          definition: ComponentDefinition) -> String? {
    let pieces = path.split(separator: ".").map(String.init)
    guard pieces.count == 2, pieces[1] == "text" else { return nil }
    let targetID = EntityID(pieces[0])
    let matches = instance.slotContent.keys.sorted().compactMap { name -> (String, Int)? in
        guard let slot = definition.api.slots.first(where: { $0.name == name }),
              let target = find(slot.targetLayerID, in: definition.root),
              let depth = distance(from: target, to: targetID), depth > 0 else { return nil }
        return (name, depth)
    }
    // Prototype tie break only. Nested ownership semantics remain undecided.
    return matches.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }.first?.0
}

private func overwrittenWrites(_ instance: ComponentInstance,
                                definition: ComponentDefinition) -> [Write] {
    var writes: [Write] = []
    for axis in instance.variantSelection.keys.sorted() {
        let value = instance.variantSelection[axis]!
        guard let variant = definition.variants.first(where: { $0.axis == axis && $0.value == value }) else {
            continue // Preserve the current unknownVariant error in the resolver.
        }
        for path in variant.propertyOverrides.keys.sorted() {
            if let slot = selectedSlot(for: path, instance: instance, definition: definition) {
                writes.append(Write(source: "variant:\(axis)=\(value)", path: path, slotName: slot))
            }
        }
    }
    for name in instance.propertyValues.keys.sorted() {
        guard let property = definition.api.properties.first(where: { $0.name == name }) else { continue }
        if let slot = selectedSlot(for: property.targetPath, instance: instance, definition: definition) {
            writes.append(Write(source: "property:\(name)", path: property.targetPath, slotName: slot))
        }
    }
    for path in instance.allowedOverrides.keys.sorted() {
        if let slot = selectedSlot(for: path, instance: instance, definition: definition) {
            writes.append(Write(source: "override", path: path, slotName: slot))
        }
    }
    return writes.sorted()
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

private func summary(_ tree: Layer) -> [String: Any] {
    ["status": "resolved",
     "oldText": find(oldID, in: tree)?.text ?? "missing",
     "outsideText": find(outsideID, in: tree)?.text ?? "missing",
     "outerChildren": find(outerID, in: tree)?.children.map(\.id.rawValue) ?? [],
     "innerChildren": find(innerID, in: tree)?.children.map(\.id.rawValue) ?? []]
}

private func resolve(_ instance: ComponentInstance, definition: ComponentDefinition) -> [String: Any] {
    do { return summary(try ComponentResolver.resolve(instance, definition: definition)) }
    catch { return ["status": "error", "error": errorCode(error)] }
}

private func evaluate(_ strategy: String, _ instance: ComponentInstance,
                      definition: ComponentDefinition) -> [String: Any] {
    let writes = overwrittenWrites(instance, definition: definition)
    if strategy == "sequential" {
        var result = resolve(instance, definition: definition)
        result["overlapCandidates"] = writes.map(\.label)
        return result
    }
    if strategy == "conflictReject" {
        if let first = writes.first {
            return ["status": "error", "error": "slotWriteConflict(\(first.path),\(first.slotName))",
                    "conflicts": writes.map(\.label)]
        }
        return resolve(instance, definition: definition)
    }
    if strategy == "slotWins" {
        var pruned = instance
        var prunedDefinition = definition
        for index in prunedDefinition.variants.indices {
            let variant = prunedDefinition.variants[index]
            guard pruned.variantSelection[variant.axis] == variant.value else { continue }
            prunedDefinition.variants[index].propertyOverrides = variant.propertyOverrides.filter {
                selectedSlot(for: $0.key, instance: instance, definition: definition) == nil
            }
        }
        pruned.propertyValues = instance.propertyValues.filter { name, _ in
            guard let property = definition.api.properties.first(where: { $0.name == name }) else { return true }
            return selectedSlot(for: property.targetPath, instance: instance, definition: definition) == nil
        }
        pruned.allowedOverrides = instance.allowedOverrides.filter {
            selectedSlot(for: $0.key, instance: instance, definition: definition) == nil
        }
        var result = resolve(pruned, definition: prunedDefinition)
        result["explicitlySuppressedWrites"] = writes.map(\.label)
        return result
    }
    return ["status": "error", "error": "unknownStrategy"]
}

@main private enum Probe {
    static func main() throws {
        let definition = fixture()
        let replacement = Layer(id: EntityID("layer_new"), kind: .text, name: "New", text: "New")
        let strategies = ["sequential", "slotWins", "conflictReject"]
        var rows: [[String: Any]] = []
        func check(_ name: String, _ instance: ComponentInstance,
                   expected: [String: [String: String]]) {
            let observed = Dictionary(uniqueKeysWithValues: strategies.map {
                ($0, evaluate($0, instance, definition: definition))
            })
            let passed = strategies.allSatisfy { strategy in
                expected[strategy]?.allSatisfy { key, value in
                    observed[strategy]?[key] as? String == value
                } == true
            }
            rows.append(["case": name, "expected": expected, "observed": observed, "passed": passed])
        }
        func expectations(_ sequential: [String: String], _ wins: [String: String],
                          _ reject: [String: String]) -> [String: [String: String]] {
            ["sequential": sequential, "slotWins": wins, "conflictReject": reject]
        }
        let oldConflict = ["status": "error", "error": "slotWriteConflict(\(oldPath),outer)"]
        let innerConflict = ["status": "error", "error": "slotWriteConflict(\(oldPath),inner)"]

        check("clean-slot-replacement", ComponentInstance(definitionID: definitionID,
              slotContent: ["outer": [replacement]]), expected: expectations(
                ["status": "resolved", "oldText": "missing"],
                ["status": "resolved", "oldText": "missing"],
                ["status": "resolved", "oldText": "missing"]))
        check("slot-target-text-write-unsupported", ComponentInstance(definitionID: definitionID,
              propertyValues: ["slotTargetText": "Attempt"], slotContent: ["outer": [replacement]]),
              expected: expectations(
                ["status": "error", "error": "unknownPath:\(outerPath)"],
                ["status": "error", "error": "unknownPath:\(outerPath)"],
                ["status": "error", "error": "unknownPath:\(outerPath)"]))
        check("selected-variant-old-child-nonempty-slot", ComponentInstance(definitionID: definitionID,
              variantSelection: ["state": "old"], slotContent: ["outer": [replacement]]),
              expected: expectations(
                ["status": "resolved", "oldText": "missing"],
                ["status": "resolved", "oldText": "missing"], oldConflict))
        check("selected-variant-old-child-empty-slot", ComponentInstance(definitionID: definitionID,
              variantSelection: ["state": "old"], slotContent: ["outer": []]),
              expected: expectations(
                ["status": "resolved", "oldText": "missing"],
                ["status": "resolved", "oldText": "missing"], oldConflict))
        check("property-old-child-empty-slot", ComponentInstance(definitionID: definitionID,
              propertyValues: ["oldLabel": "Property"], slotContent: ["outer": []]),
              expected: expectations(
                ["status": "resolved", "oldText": "missing"],
                ["status": "resolved", "oldText": "missing"], oldConflict))
        check("override-old-child-nonempty-slot", ComponentInstance(definitionID: definitionID,
              slotContent: ["outer": [replacement]], allowedOverrides: [oldPath: "Override"]),
              expected: expectations(
                ["status": "error", "error": "unknownPath:\(oldPath)"],
                ["status": "resolved", "oldText": "missing"], oldConflict))
        check("unrelated-property-write", ComponentInstance(definitionID: definitionID,
              propertyValues: ["outsideLabel": "Changed"], slotContent: ["outer": [replacement]]),
              expected: expectations(
                ["status": "resolved", "outsideText": "Changed"],
                ["status": "resolved", "outsideText": "Changed"],
                ["status": "resolved", "outsideText": "Changed"]))
        check("unselected-variant-write", ComponentInstance(definitionID: definitionID,
              variantSelection: ["tone": "outside"], slotContent: ["outer": [replacement]]),
              expected: expectations(
                ["status": "resolved", "outsideText": "Variant outside"],
                ["status": "resolved", "outsideText": "Variant outside"],
                ["status": "resolved", "outsideText": "Variant outside"]))
        check("nested-inner-slot-property", ComponentInstance(definitionID: definitionID,
              propertyValues: ["oldLabel": "Property"], slotContent: ["inner": [replacement]]),
              expected: expectations(
                ["status": "resolved", "oldText": "missing"],
                ["status": "resolved", "oldText": "missing"], innerConflict))
        check("nested-outer-slot-property", ComponentInstance(definitionID: definitionID,
              propertyValues: ["oldLabel": "Property"], slotContent: ["outer": [replacement]]),
              expected: expectations(
                ["status": "resolved", "oldText": "missing"],
                ["status": "resolved", "oldText": "missing"], oldConflict))
        check("nested-both-slots-property", ComponentInstance(definitionID: definitionID,
              propertyValues: ["oldLabel": "Property"],
              slotContent: ["inner": [replacement], "outer": [replacement]]),
              expected: expectations(
                ["status": "resolved", "oldText": "missing"],
                ["status": "resolved", "oldText": "missing"], innerConflict))

        // Negative control: a preflight that runs before public API checks can
        // mask forbiddenOverride. Neither prototype is production-safe as is.
        var restricted = definition
        restricted.api.overridablePaths.removeAll { $0 == oldPath }
        let forbidden = ComponentInstance(definitionID: definitionID,
            slotContent: ["outer": [replacement]], allowedOverrides: [oldPath: "Forbidden"])
        let forbiddenObserved = Dictionary(uniqueKeysWithValues: strategies.map {
            ($0, evaluate($0, forbidden, definition: restricted))
        })
        let forbiddenPassed = (forbiddenObserved["sequential"]?["error"] as? String) ==
                "forbiddenOverride:\(oldPath)" &&
            (forbiddenObserved["slotWins"]?["status"] as? String) == "resolved" &&
            (forbiddenObserved["conflictReject"]?["error"] as? String) ==
                "slotWriteConflict(\(oldPath),outer)"
        rows.append(["case": "forbidden-override-error-precedence-negative-control",
                     "expected": ["sequential": "forbiddenOverride", "slotWins": "unsafe suppression",
                                  "conflictReject": "slotWriteConflict masks forbiddenOverride"],
                     "observed": forbiddenObserved, "passed": forbiddenPassed])

        var duplicateVariantPath = definition
        duplicateVariantPath.variants.append(ComponentVariant(id: EntityID("variant_tone_old"),
            axis: "tone", value: "old", propertyOverrides: [oldPath: "Another variant"] ))
        let duplicateSelected = ComponentInstance(definitionID: definitionID,
            variantSelection: ["state": "old", "tone": "old"],
            slotContent: ["outer": [replacement]])
        let duplicateObserved = Dictionary(uniqueKeysWithValues: strategies.map {
            ($0, evaluate($0, duplicateSelected, definition: duplicateVariantPath))
        })
        let duplicatePassed = (duplicateObserved["sequential"]?["error"] as? String) ==
                "conflictingVariants:\(oldPath)" &&
            (duplicateObserved["slotWins"]?["status"] as? String) == "resolved" &&
            (duplicateObserved["conflictReject"]?["error"] as? String) ==
                "slotWriteConflict(\(oldPath),outer)"
        rows.append(["case": "duplicate-selected-variant-error-precedence-negative-control",
                     "expected": ["sequential": "conflictingVariants", "slotWins": "unsafe suppression",
                                  "conflictReject": "slotWriteConflict masks conflictingVariants"],
                     "observed": duplicateObserved, "passed": duplicatePassed])

        let outer = find(outerID, in: definition.root)!
        let inner = find(innerID, in: definition.root)!
        let relations: [String: Any] = [
            "outerTargetToSelfDistance": distance(from: outer, to: outerID) ?? -1,
            "outerTargetToInnerDistance": distance(from: outer, to: innerID) ?? -1,
            "outerTargetToOldChildDistance": distance(from: outer, to: oldID) ?? -1,
            "innerTargetToOldChildDistance": distance(from: inner, to: oldID) ?? -1,
            "outerTargetToOutsideDistance": distance(from: outer, to: outsideID) ?? -1,
            "exactTargetExcluded": selectedSlot(for: outerPath,
                instance: ComponentInstance(definitionID: definitionID, slotContent: ["outer": []]),
                definition: definition) == nil
        ]
        let relationsPassed = distance(from: outer, to: outerID) == 0 &&
            distance(from: outer, to: innerID) == 1 &&
            distance(from: outer, to: oldID) == 2 &&
            distance(from: inner, to: oldID) == 1 &&
            distance(from: outer, to: outsideID) == nil &&
            (relations["exactTargetExcluded"] as? Bool) == true
        let passed = rows.allSatisfy { ($0["passed"] as? Bool) == true } && relationsPassed
        let report: [String: Any] = [
            "sourceCommit": ProcessInfo.processInfo.environment["HAMII_SOURCE_COMMIT"] ?? "unspecified",
            "fixture": "nested inner/outer slots with an old text child and outside sibling; no production error enum changes",
            "strategies": ["sequential=current ComponentResolver", "slotWins=test-only drop overwritten writes before current resolver",
                           "conflictReject=test-only typed slotWriteConflict(path,slotName) before current resolver"],
            "cases": rows, "caseCount": rows.count, "relations": relations,
            "relationsPassed": relationsPassed, "passed": passed,
            "classification": [
                "Confirmed": "current sequential resolver outcomes for fixed cases",
                "Measured": "one run, 13 matrix cases plus structural relation controls; no latency benchmark",
                "Inferred": "slot-wins and conflict-reject can avoid silent loss, but naïve preflight masks existing errors",
                "Unknown": "valid future write to slot target container, nested-slot tie policy, validator/API integration, persistence, cache, and performance"
            ]
        ]
        let bytes = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
        FileHandle.standardOutput.write(bytes)
        FileHandle.standardOutput.write(Data("\n".utf8))
        if !passed { exit(1) }
    }
}
