import Foundation
import HamiiCore
import HamiiApplication
import HamiiFormat

// Evidence-only probe. The conflict gate below is test-only and is not wired
// into ProjectService or any persisted schema.
let scopeID = EntityID("scope_app")
let definitionID = EntityID("component_nested_slots")
let outerID = EntityID("outer_slot")
let innerID = EntityID("inner_slot")
let oldTextID = EntityID("old_text")

struct MatrixCase {
    let name: String
    let innerName: String
    let outerName: String
    let innerChildren: [Layer]
    let outerChildren: [Layer]
    let selectedVariant: Bool
}

let innerReplacement = Layer(id: EntityID("inner_replacement"),
    kind: .text, name: "Inner replacement", text: "Inner replacement")
let outerReplacement = Layer(id: EntityID("outer_replacement"),
    kind: .text, name: "Outer replacement", text: "Outer replacement")
let cases: [MatrixCase] = [
    MatrixCase(name: "inner_then_outer_nonempty", innerName: "a_inner", outerName: "z_outer",
        innerChildren: [innerReplacement], outerChildren: [outerReplacement], selectedVariant: true),
    MatrixCase(name: "outer_then_inner_nonempty", innerName: "z_inner", outerName: "a_outer",
        innerChildren: [innerReplacement], outerChildren: [outerReplacement], selectedVariant: true),
    MatrixCase(name: "inner_empty_outer_nonempty", innerName: "a_inner", outerName: "z_outer",
        innerChildren: [], outerChildren: [outerReplacement], selectedVariant: true),
    MatrixCase(name: "inner_nonempty_outer_empty", innerName: "a_inner", outerName: "z_outer",
        innerChildren: [innerReplacement], outerChildren: [], selectedVariant: true),
    MatrixCase(name: "variant_unselected_both_slots_selected", innerName: "a_inner", outerName: "z_outer",
        innerChildren: [innerReplacement], outerChildren: [outerReplacement], selectedVariant: false)
]

func fixture(_ item: MatrixCase, from initial: Document) -> (Document, ComponentDefinition, ComponentInstance) {
    let oldText = Layer(id: oldTextID, kind: .text, name: "Old", text: "Base")
    let inner = Layer(id: innerID, kind: .stack, name: "Inner", children: [oldText])
    let outer = Layer(id: outerID, kind: .stack, name: "Outer", children: [inner])
    var definition = ComponentDefinition(id: definitionID, name: "Nested slots",
        ownerScopeID: scopeID, root: Layer(id: EntityID("definition_root"),
            kind: .stack, name: "Root", children: [outer]))
    definition.api.slots = [
        ComponentSlot(name: item.innerName, targetLayerID: innerID),
        ComponentSlot(name: item.outerName, targetLayerID: outerID)
    ]
    definition.variants = [ComponentVariant(id: EntityID("variant_active"),
        axis: "tone", value: "active", propertyOverrides: ["old_text.text": "Variant write"])]
    let instance = ComponentInstance(definitionID: definitionID,
        variantSelection: item.selectedVariant ? ["tone": "active"] : [:],
        slotContent: [item.innerName: item.innerChildren, item.outerName: item.outerChildren])
    let instanceLayer = Layer(id: EntityID("screen_instance"), kind: .componentInstance,
        name: "Nested slots", component: instance)
    var document = initial
    document.scopes = [ArchitectureScope(id: scopeID, name: "App", parentID: nil)]
    document.components = [definition]
    document.screens = [Screen(id: EntityID("screen_main"), name: "Main",
        scopeID: scopeID, root: Layer(id: EntityID("screen_root"), kind: .stack,
            name: "Root", children: [instanceLayer]))]
    document.revision = initial.revision + 1
    return (document, definition, instance)
}

func find(_ id: EntityID, in root: Layer) -> Layer? {
    if root.id == id { return root }
    for child in root.children {
        if let found = find(id, in: child) { return found }
    }
    return nil
}

func contains(_ id: EntityID, in root: Layer) -> Bool {
    find(id, in: root) != nil
}

// Prototype only: find selected Variant writes into descendants of selected
// slot targets in the *Definition* tree. This does not authorize mutations.
func testOnlyConflictSlots(_ instance: ComponentInstance,
                           definition: ComponentDefinition) -> [String] {
    let writtenIDs = Set(instance.variantSelection.compactMap { axis, value in
        definition.variants.first { $0.axis == axis && $0.value == value }
    }.flatMap { variant in
        variant.propertyOverrides.keys.compactMap { path -> EntityID? in
            let parts = path.split(separator: ".")
            return parts.count == 2 && parts[1] == "text" ? EntityID(String(parts[0])) : nil
        }
    })
    return instance.slotContent.keys.sorted().filter { name in
        guard let slot = definition.api.slots.first(where: { $0.name == name }),
              let target = find(slot.targetLayerID, in: definition.root) else { return false }
        return writtenIDs.contains { contains($0, in: target) }
    }
}

func canonicalBytes(at root: URL) throws -> [String: Data] {
    let normalizedRoot = root.resolvingSymlinksInPath().path
    guard let enumerator = FileManager.default.enumerator(at: root,
        includingPropertiesForKeys: [.isRegularFileKey]) else {
        throw NSError(domain: "SlotApplicationProbe", code: 1)
    }
    var result: [String: Data] = [:]
    for case let url as URL in enumerator where url.pathExtension == "json" {
        let path = url.resolvingSymlinksInPath().path
        precondition(path.hasPrefix(normalizedRoot + "/"))
        let relative = String(path.dropFirst(normalizedRoot.count + 1))
        if relative.hasPrefix(".hamii/") { continue }
        result[relative] = try Data(contentsOf: url)
    }
    return result
}

func typedRules(_ diagnostics: [Diagnostic]) -> [String] {
    diagnostics.map { "\($0.rule)@\($0.entityID?.rawValue ?? "none")" }.sorted()
}

func evaluate(_ item: MatrixCase) throws -> [String: Any] {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("hamii-slot-application-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = CanonicalRepository(root: root)
    _ = try repository.create(name: "Slot application")
    let initial = try repository.observe()
    let (candidate, definition, instance) = fixture(item, from: initial.document)
    let directRules = typedRules(DocumentValidator.validate(candidate))
    var resolver = "success"
    var resolved: Layer? = nil
    do { resolved = try ComponentResolver.resolve(instance, definition: definition) }
    catch { resolver = String(describing: error) }
    let prototypeConflictSlots = testOnlyConflictSlots(instance, definition: definition)
    let beforeCommitBytes = try canonicalBytes(at: root)
    var canonicalCommit = "accepted"
    var commitRules: [String] = []
    var reopenedEqual: Bool? = nil
    do {
        _ = try repository.commit(candidate, expected: initial)
        reopenedEqual = try CanonicalRepository(root: root).observe().document == candidate
    } catch CanonicalError.invalid(let diagnostics) {
        canonicalCommit = "rejectedInvalid"
        commitRules = typedRules(diagnostics)
    } catch { canonicalCommit = "otherError:\(type(of: error))" }
    let afterCommitBytes = try canonicalBytes(at: root)

    var application: [String: Any] = [:]
    if canonicalCommit == "accepted" {
        let service = ProjectService(repository: repository)
        let beforeGate = try service.observe()
        let bytesBeforeGate = try canonicalBytes(at: root)
        // Hypothetical gate: reject before calling ProjectService.mutate.
        let gateRejected = !prototypeConflictSlots.isEmpty
        let afterGate = try service.observe()
        let bytesAfterGate = try canonicalBytes(at: root)
        let gateUnchanged = bytesBeforeGate == bytesAfterGate &&
            beforeGate.document.revision == afterGate.document.revision &&
            beforeGate.statePrecondition == afterGate.statePrecondition

        // Separate production observation: the current service has no slot
        // edit intent. This is an unrelated supported createPage mutation.
        var productionResult = "accepted"
        var productionRevision: Int? = nil
        do {
            let result = try service.mutate(.createPage(name: "Unrelated"),
                expectedState: beforeGate.statePrecondition, author: .human)
            productionRevision = result.revision
        } catch { productionResult = "error:\(type(of: error))" }
        let afterService = try service.observe()
        application = [
            "testOnlyGateWouldRejectBeforeServiceCall": gateRejected,
            "testOnlyGateLeavesCanonicalBytesRevisionAndPreconditionUnchanged": gateUnchanged,
            "testOnlyGateCanonicalBytesEqual": bytesBeforeGate == bytesAfterGate,
            "testOnlyGateRevisionEqual": beforeGate.document.revision == afterGate.document.revision,
            "testOnlyGatePreconditionEqual": beforeGate.statePrecondition == afterGate.statePrecondition,
            "currentServiceUnrelatedCreatePage": productionResult,
            "currentServiceResultRevision": productionRevision as Any? ?? NSNull(),
            "currentServiceRevisionAdvancedByOne": afterService.document.revision == beforeGate.document.revision + 1,
            "currentServicePreconditionChanged": afterService.statePrecondition != beforeGate.statePrecondition,
            "currentServiceCanonicalBytesChanged": (try canonicalBytes(at: root)) != bytesBeforeGate
        ]
    }
    return [
        "name": item.name,
        "slotProcessingOrder": instance.slotContent.keys.sorted(),
        "variantSelected": item.selectedVariant,
        "testOnlyConflictSlots": prototypeConflictSlots,
        "resolver": resolver,
        "resolvedOldText": resolved.flatMap { find(oldTextID, in: $0)?.text } as Any? ?? NSNull(),
        "resolvedOuterChildren": resolved.flatMap { find(outerID, in: $0)?.children.map { $0.id.rawValue } } as Any? ?? NSNull(),
        "directValidationRules": directRules,
        "canonicalCommit": canonicalCommit,
        "canonicalCommitRules": commitRules,
        "reopenedEqualsCandidate": reopenedEqual as Any? ?? NSNull(),
        "canonicalBytesEqualBeforeAfterCommitAttempt": beforeCommitBytes == afterCommitBytes,
        "application": application
    ]
}

let result: [String: Any] = ["cases": try cases.map(evaluate)]
let encoded = try JSONSerialization.data(withJSONObject: result,
    options: [.prettyPrinted, .sortedKeys])
print(String(decoding: encoded, as: UTF8.self))
