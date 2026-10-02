import Foundation
import HamiiCore
import HamiiApplication
import HamiiFormat

// Evidence-only probe. No test-only conflict rule is applied to production data.
let scopeID = EntityID("scope_app")
let definitionID = EntityID("component_panel")
let slotID = EntityID("slot_container")
let insideID = EntityID("inside_text")
let nestedID = EntityID("nested_text")
let outsideID = EntityID("outside_text")
let replacement = Layer(id: EntityID("replacement_text"), kind: .text,
    name: "Replacement", text: "Replacement")

func definition(writes: [String: String] = [:],
                propertyPath: String = "inside_text.text") -> ComponentDefinition {
    let nested = Layer(id: EntityID("nested_container"), kind: .stack,
        name: "Nested", children: [Layer(id: nestedID, kind: .text,
            name: "Nested Text", text: "DefaultNested")])
    let slot = Layer(id: slotID, kind: .stack, name: "Slot",
        children: [Layer(id: insideID, kind: .text, name: "Inside", text: "DefaultInside"), nested])
    let outside = Layer(id: outsideID, kind: .text, name: "Outside", text: "DefaultOutside")
    var value = ComponentDefinition(id: definitionID, name: "Panel", ownerScopeID: scopeID,
        root: Layer(id: EntityID("definition_root"), kind: .stack,
            name: "Root", children: [outside, slot]))
    value.api.properties = [
        ComponentProperty(name: "inside", kind: .text, targetPath: propertyPath),
        ComponentProperty(name: "outside", kind: .text, targetPath: "outside_text.text")
    ]
    value.api.slots = [ComponentSlot(name: "body", targetLayerID: slotID)]
    value.api.overridablePaths = ["inside_text.text", "outside_text.text"]
    value.variants = [ComponentVariant(id: EntityID("variant_active"),
        axis: "tone", value: "active", propertyOverrides: writes)]
    return value
}

func baseInstance() -> ComponentInstance {
    ComponentInstance(definitionID: definitionID, variantSelection: ["tone": "active"])
}

func find(_ id: EntityID, in root: Layer) -> Layer? {
    if root.id == id { return root }
    for child in root.children {
        if let found = find(id, in: child) { return found }
    }
    return nil
}

func rules(_ diagnostics: [Diagnostic]) -> [String] {
    diagnostics.map { "\($0.rule)@\($0.entityID?.rawValue ?? "none")" }.sorted()
}

struct Case {
    let name: String
    let definition: ComponentDefinition
    let instance: ComponentInstance
}

var cases: [Case] = []
do {
    var instance = baseInstance()
    instance.slotContent["body"] = [replacement]
    cases.append(Case(name: "slot_target_container_itself_retained", definition: definition(), instance: instance))
}
do {
    var instance = baseInstance()
    instance.slotContent["body"] = [replacement]
    cases.append(Case(name: "selected_variant_inside_slot_replaced",
        definition: definition(writes: ["inside_text.text": "VariantInside"]), instance: instance))
}
do {
    var instance = baseInstance()
    instance.propertyValues["inside"] = "PropertyInside"
    instance.slotContent["body"] = [replacement]
    cases.append(Case(name: "property_inside_slot_replaced", definition: definition(), instance: instance))
}
do {
    var instance = baseInstance()
    instance.propertyValues["outside"] = "PropertyOutside"
    instance.slotContent["body"] = [replacement]
    cases.append(Case(name: "property_outside_slot_survives", definition: definition(), instance: instance))
}
cases.append(Case(name: "slot_unselected_selected_variant_inside_survives",
    definition: definition(writes: ["inside_text.text": "VariantInside"]),
    instance: baseInstance()))
do {
    var instance = ComponentInstance(definitionID: definitionID)
    instance.slotContent["body"] = [replacement]
    cases.append(Case(name: "variant_unselected_slot_selected_no_write",
        definition: definition(writes: ["inside_text.text": "VariantInside"]), instance: instance))
}
do {
    var instance = baseInstance()
    instance.propertyValues["inside"] = "PropertyInside"
    instance.slotContent["body"] = []
    cases.append(Case(name: "empty_slot_removes_written_descendant", definition: definition(), instance: instance))
}
do {
    var instance = baseInstance()
    instance.slotContent["body"] = [replacement]
    cases.append(Case(name: "nested_descendant_under_slot_replaced",
        definition: definition(writes: ["nested_text.text": "VariantNested"]), instance: instance))
}
do {
    var instance = baseInstance()
    instance.slotContent["body"] = [replacement]
    instance.allowedOverrides["inside_text.text"] = "OverrideInside"
    cases.append(Case(name: "allowed_override_after_slot_missing_path", definition: definition(), instance: instance))
}
do {
    var instance = baseInstance()
    instance.slotContent["body"] = [replacement]
    instance.allowedOverrides["outside_text.text"] = "OverrideOutside"
    cases.append(Case(name: "allowed_override_outside_slot_survives", definition: definition(), instance: instance))
}
do {
    var instance = baseInstance()
    instance.slotContent["body"] = [replacement]
    cases.append(Case(name: "write_to_slot_target_itself_unsupported",
        definition: definition(writes: ["slot_container.text": "Impossible"]), instance: instance))
}

func canonicalBytes(at root: URL) throws -> [String: Data] {
    let normalizedRoot = root.resolvingSymlinksInPath().path
    var result: [String: Data] = [:]
    guard let enumerator = FileManager.default.enumerator(at: root,
        includingPropertiesForKeys: [.isRegularFileKey]) else {
        throw NSError(domain: "SlotProbe", code: 1)
    }
    for case let url as URL in enumerator where url.pathExtension == "json" {
        let path = url.resolvingSymlinksInPath().path
        precondition(path.hasPrefix(normalizedRoot + "/"))
        let relative = String(path.dropFirst(normalizedRoot.count + 1))
        if relative.hasPrefix(".hamii/") { continue }
        result[relative] = try Data(contentsOf: url)
    }
    return result
}

func evaluate(_ item: Case) throws -> [String: Any] {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("hamii-slot-conflict-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = CanonicalRepository(root: root)
    _ = try repository.create(name: "Slot Conflict")
    let old = try repository.observe()
    var candidate = old.document
    candidate.scopes = [ArchitectureScope(id: scopeID, name: "App", parentID: nil)]
    candidate.components = [item.definition]
    let instanceLayer = Layer(id: EntityID("screen_instance"),
        kind: .componentInstance, name: "Panel", component: item.instance)
    candidate.screens = [Screen(id: EntityID("screen_main"), name: "Main", scopeID: scopeID,
        root: Layer(id: EntityID("screen_root"), kind: .stack,
            name: "Root", children: [instanceLayer]))]
    candidate.revision = old.document.revision + 1
    let directRules = rules(DocumentValidator.validate(candidate))
    let beforeBytes = try canonicalBytes(at: root)

    var resolver = "success"
    var resolved: Layer? = nil
    do { resolved = try ComponentResolver.resolve(item.instance, definition: item.definition) }
    catch { resolver = String(describing: error) }
    var commit = "accepted"
    var commitRules: [String] = []
    var reopenedEqual: Bool? = nil
    do {
        _ = try repository.commit(candidate, expected: old)
        reopenedEqual = try CanonicalRepository(root: root).observe().document == candidate
    } catch CanonicalError.invalid(let diagnostics) {
        commit = "rejectedInvalid"
        commitRules = rules(diagnostics)
    } catch {
        commit = "otherError:\(type(of: error))"
    }
    let afterCommitOrRejection = try repository.observe()
    let afterBytes = try canonicalBytes(at: root)
    return [
        "name": item.name,
        "resolver": resolver,
        "resolvedInside": resolved.flatMap { find(insideID, in: $0)?.text } as Any? ?? NSNull(),
        "resolvedNested": resolved.flatMap { find(nestedID, in: $0)?.text } as Any? ?? NSNull(),
        "resolvedOutside": resolved.flatMap { find(outsideID, in: $0)?.text } as Any? ?? NSNull(),
        "resolvedSlotTargetPresent": resolved.map { find(slotID, in: $0) != nil } as Any? ?? NSNull(),
        "resolvedSlotChildren": resolved.flatMap { find(slotID, in: $0)?.children.map { $0.id.rawValue } } as Any? ?? NSNull(),
        "directValidationRules": directRules,
        "canonicalCommit": commit,
        "canonicalCommitRules": commitRules,
        "canonicalByteCountBefore": beforeBytes.values.reduce(0) { $0 + $1.count },
        "canonicalByteCountAfter": afterBytes.values.reduce(0) { $0 + $1.count },
        "canonicalBytesEqualBeforeAfterCommitAttempt": beforeBytes == afterBytes,
        "reopenedEqualsCandidate": reopenedEqual as Any? ?? NSNull(),
        "afterRejectedStillOriginal": commit == "accepted" ? NSNull() :
            (afterCommitOrRejection.document == old.document) as Any
    ]
}
let matrix = try cases.map(evaluate)

func nestedDefinitions(cycle: Bool) -> (ComponentDefinition, ComponentDefinition, Document) {
    let aID = EntityID("component_a"), bID = EntityID("component_b")
    let bRef = Layer(id: EntityID("definition_a_to_b"), kind: .componentInstance,
        name: "B", component: ComponentInstance(definitionID: bID))
    let a = ComponentDefinition(id: aID, name: "A", ownerScopeID: scopeID,
        root: Layer(id: EntityID("definition_a_root"), kind: .stack,
            name: "A root", children: [bRef]))
    var bChildren = [Layer(id: EntityID("definition_b_text"), kind: .text,
        name: "B text", text: "B")]
    if cycle {
        bChildren.append(Layer(id: EntityID("definition_b_to_a"), kind: .componentInstance,
            name: "A", component: ComponentInstance(definitionID: aID)))
    }
    let b = ComponentDefinition(id: bID, name: "B", ownerScopeID: scopeID,
        root: Layer(id: EntityID("definition_b_root"), kind: .stack,
            name: "B root", children: bChildren))
    var document = Document(name: "Nested")
    document.scopes = [ArchitectureScope(id: scopeID, name: "App", parentID: nil)]
    document.components = [a, b]
    document.screens = [Screen(id: EntityID("screen_nested"), name: "Nested", scopeID: scopeID,
        root: Layer(id: EntityID("screen_nested_root"), kind: .stack, name: "Root",
            children: [Layer(id: EntityID("screen_a_instance"), kind: .componentInstance,
                name: "A", component: ComponentInstance(definitionID: aID))]))]
    return (a, b, document)
}
let (acyclicA, _, acyclicDocument) = nestedDefinitions(cycle: false)
let directNested = try ComponentResolver.resolve(ComponentInstance(definitionID: acyclicA.id),
    definition: acyclicA)
let nestedRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("hamii-nested-conflict-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: nestedRoot) }
let nestedRepository = CanonicalRepository(root: nestedRoot)
_ = try nestedRepository.create(name: "Nested")
let nestedOld = try nestedRepository.observe()
var validNested = acyclicDocument
validNested.id = nestedOld.document.id
validNested.revision = nestedOld.document.revision + 1
let acyclicRules = rules(DocumentValidator.validate(validNested))
var acyclicCommit = "accepted"
var acyclicReopen = false
do {
    _ = try nestedRepository.commit(validNested, expected: nestedOld)
    acyclicReopen = try CanonicalRepository(root: nestedRoot).observe().document == validNested
} catch { acyclicCommit = "error:\(type(of: error))" }
let (_, _, cycleModel) = nestedDefinitions(cycle: true)
var cycleCandidate = cycleModel
cycleCandidate.id = validNested.id
cycleCandidate.revision = validNested.revision + 1
let cycleRules = rules(DocumentValidator.validate(cycleCandidate))
var cycleCommit = "accepted"
var cycleCommitRules: [String] = []
let beforeCycleBytes = try canonicalBytes(at: nestedRoot)
do {
    let current = try nestedRepository.observe()
    _ = try nestedRepository.commit(cycleCandidate, expected: current)
} catch CanonicalError.invalid(let diagnostics) {
    cycleCommit = "rejectedInvalid"
    cycleCommitRules = rules(diagnostics)
} catch { cycleCommit = "otherError:\(type(of: error))" }
let postCycleStillAcyclic = try nestedRepository.observe().document == validNested
let afterCycleBytes = try canonicalBytes(at: nestedRoot)

let result: [String: Any] = [
    "slotWriteMatrix": matrix,
    "nested": [
        "acyclicValidationRules": acyclicRules,
        "acyclicCommit": acyclicCommit,
        "acyclicReopenEqualsCandidate": acyclicReopen,
        "directResolverNestedNodeKind": directNested.children.first?.kind.rawValue ?? "none",
        "directResolverNestedDefinitionID": directNested.children.first?.component?.definitionID.rawValue ?? "none",
        "cycleValidationRules": cycleRules,
        "cycleCommit": cycleCommit,
        "cycleCommitRules": cycleCommitRules,
        "afterRejectedCycleStillAcyclic": postCycleStillAcyclic,
        "cycleCanonicalBytesUnchangedAfterRejection": beforeCycleBytes == afterCycleBytes,
        "cycleCanonicalByteCountBefore": beforeCycleBytes.values.reduce(0) { $0 + $1.count },
        "cycleCanonicalByteCountAfter": afterCycleBytes.values.reduce(0) { $0 + $1.count }
    ]
]
let encoded = try JSONSerialization.data(withJSONObject: result,
    options: [.prettyPrinted, .sortedKeys])
print(String(decoding: encoded, as: UTF8.self))
