import XCTest
import HamiiCore

final class ComponentResolverDecisionTests: XCTestCase {
    private let definitionID = EntityID("component_decision")
    private let oldID = EntityID("layer_old_text")
    private let outsideID = EntityID("layer_outside_text")
    private let outerID = EntityID("layer_outer_slot")
    private let innerID = EntityID("layer_inner_slot")
    private let peerID = EntityID("layer_peer_slot")
    private let oldPath = "layer_old_text.text"
    private let outsidePath = "layer_outside_text.text"

    private func fixture() -> ComponentDefinition {
        let old = Layer(id: oldID, kind: .text, name: "Old", text: "Base")
        let inner = Layer(id: innerID, kind: .stack, name: "Inner", children: [old])
        let outer = Layer(id: outerID, kind: .stack, name: "Outer", children: [inner])
        let peer = Layer(id: peerID, kind: .stack, name: "Peer", children: [
            Layer(id: EntityID("layer_peer_text"), kind: .text, name: "Peer text", text: "Peer")
        ])
        let outside = Layer(id: outsideID, kind: .text, name: "Outside", text: "Outside")
        var definition = ComponentDefinition(id: definitionID, name: "Decision",
            ownerScopeID: EntityID("scope_app"),
            root: Layer(id: EntityID("layer_root"), kind: .stack, name: "Root",
                        children: [outer, peer, outside]))
        definition.api = ComponentAPI(properties: [
            ComponentProperty(name: "oldLabel", kind: .text, targetPath: oldPath),
            ComponentProperty(name: "outsideLabel", kind: .text, targetPath: outsidePath)
        ], slots: [
            ComponentSlot(name: "outer", targetLayerID: outerID),
            ComponentSlot(name: "aliasOuter", targetLayerID: outerID),
            ComponentSlot(name: "inner", targetLayerID: innerID),
            ComponentSlot(name: "peer", targetLayerID: peerID)
        ], overridablePaths: [oldPath, outsidePath])
        definition.variants = [
            ComponentVariant(id: EntityID("variant_state_active"), axis: "state", value: "active",
                             propertyOverrides: [oldPath: "Variant"]),
            ComponentVariant(id: EntityID("variant_size_large"), axis: "size", value: "large",
                             propertyOverrides: [oldPath: "Variant"]),
            ComponentVariant(id: EntityID("variant_tone_loud"), axis: "tone", value: "loud",
                             propertyOverrides: [outsidePath: "Loud"])
        ]
        return definition
    }

    private func replacement(_ id: String = "layer_replacement") -> Layer {
        Layer(id: EntityID(id), kind: .text, name: "Replacement", text: "Replacement")
    }

    private func find(_ id: EntityID, in layer: Layer) -> Layer? {
        if layer.id == id { return layer }
        for child in layer.children {
            if let found = find(id, in: child) { return found }
        }
        return nil
    }

    private func assertError(_ expected: ComponentResolutionError,
                             _ instance: ComponentInstance,
                             definition: ComponentDefinition,
                             file: StaticString = #filePath,
                             line: UInt = #line) {
        XCTAssertThrowsError(try ComponentResolver.resolve(instance, definition: definition),
                             file: file, line: line) { error in
            XCTAssertEqual(error as? ComponentResolutionError, expected, file: file, line: line)
        }
    }

    func testSameTargetSlotsRejectWithSortedNamesAndEmptySelection() {
        let definition = fixture()
        var first: [String: [Layer]] = [:]
        first["outer"] = [replacement()]
        first["aliasOuter"] = []
        var reversed: [String: [Layer]] = [:]
        reversed["aliasOuter"] = []
        reversed["outer"] = [replacement()]
        for slots in [first, reversed] {
            assertError(.overlappingSlots(["aliasOuter", "outer"]),
                ComponentInstance(definitionID: definitionID, slotContent: slots), definition: definition)
        }
        assertError(.overlappingSlots(["aliasOuter", "inner", "outer"]),
            ComponentInstance(definitionID: definitionID,
                              slotContent: ["inner": [], "outer": [], "aliasOuter": []]),
            definition: definition)
    }

    func testAncestorSlotsRejectRegardlessOfSlotNameOrDictionaryOrder() {
        let definition = fixture()
        var first: [String: [Layer]] = [:]
        first["inner"] = []
        first["outer"] = [replacement()]
        var reversed: [String: [Layer]] = [:]
        reversed["outer"] = [replacement()]
        reversed["inner"] = []
        for slots in [first, reversed] {
            assertError(.overlappingSlots(["inner", "outer"]),
                ComponentInstance(definitionID: definitionID, slotContent: slots), definition: definition)
        }
        var renamed = definition
        renamed.api.slots = [ComponentSlot(name: "aOuter", targetLayerID: outerID),
                             ComponentSlot(name: "zInner", targetLayerID: innerID)]
        assertError(.overlappingSlots(["aOuter", "zInner"]),
            ComponentInstance(definitionID: definitionID,
                              slotContent: ["aOuter": [replacement()], "zInner": []]),
            definition: renamed)
    }

    func testNonoverlappingSlotsResolveAndEmptySlotIsAReplacement() throws {
        let definition = fixture()
        let resolved = try ComponentResolver.resolve(ComponentInstance(definitionID: definitionID,
            slotContent: ["outer": [], "peer": [replacement("layer_new_peer")]]),
            definition: definition)
        XCTAssertEqual(find(outerID, in: resolved)?.children.count, 0)
        XCTAssertEqual(find(peerID, in: resolved)?.children.map(\.id), [EntityID("layer_new_peer")])
        XCTAssertEqual(find(oldID, in: resolved), nil)
    }

    func testSelectedVariantAndPropertyWritesToRemovedChildAreTypedConflicts() {
        let definition = fixture()
        assertError(.slotWriteConflict(path: oldPath, slotName: "outer"),
            ComponentInstance(definitionID: definitionID, variantSelection: ["state": "active"],
                              slotContent: ["outer": [replacement()]]), definition: definition)
        assertError(.slotWriteConflict(path: oldPath, slotName: "outer"),
            ComponentInstance(definitionID: definitionID, propertyValues: ["oldLabel": "Property"],
                              slotContent: ["outer": []]), definition: definition)
        assertError(.slotWriteConflict(path: oldPath, slotName: "inner"),
            ComponentInstance(definitionID: definitionID, propertyValues: ["oldLabel": "Property"],
                              slotContent: ["inner": [replacement()]]), definition: definition)
    }

    func testWriteConflictIsIndependentOfSelectionDictionaryInsertionOrder() {
        let definition = fixture()
        var first: [String: String] = [:]
        first["state"] = "active"
        first["tone"] = "loud"
        var reversed: [String: String] = [:]
        reversed["tone"] = "loud"
        reversed["state"] = "active"
        for selection in [first, reversed] {
            assertError(.slotWriteConflict(path: oldPath, slotName: "outer"),
                ComponentInstance(definitionID: definitionID, variantSelection: selection,
                                  slotContent: ["outer": []]), definition: definition)
        }
    }

    func testSlotTargetTextPathRemainsUnknownPathNotNewWriteConflict() {
        var definition = fixture()
        // Direct invalid-Definition-path control: slot targets are containers
        // and have no writable `.text`; this is not a valid whole Document.
        definition.api.properties.append(ComponentProperty(name: "outerTargetText", kind: .text,
                                                           targetPath: "layer_outer_slot.text"))
        assertError(.unknownPath("layer_outer_slot.text"),
            ComponentInstance(definitionID: definitionID,
                              propertyValues: ["outerTargetText": "Attempt"],
                              slotContent: ["outer": [replacement()]]), definition: definition)
    }

    func testUnselectedVariantAndUnrelatedWriteDoNotConflict() throws {
        let definition = fixture()
        // `tone=loud` writes outsidePath, so this also checks that a dormant
        // variant does not participate in resolution or conflict detection.
        let unselected = try ComponentResolver.resolve(ComponentInstance(definitionID: definitionID,
            slotContent: ["outer": [replacement()]]), definition: definition)
        XCTAssertEqual(find(outsideID, in: unselected)?.text, "Outside")
        let outside = try ComponentResolver.resolve(ComponentInstance(definitionID: definitionID,
            variantSelection: ["tone": "loud"], propertyValues: ["outsideLabel": "Property outside"],
            slotContent: ["outer": [replacement()]]), definition: definition)
        XCTAssertEqual(find(outsideID, in: outside)?.text, "Property outside")
    }

    func testVariantSamePathConflictPrecedesSlotWriteConflictEvenForSameValues() {
        let definition = fixture()
        assertError(.conflictingVariants(oldPath), ComponentInstance(definitionID: definitionID,
            variantSelection: ["size": "large", "state": "active"],
            slotContent: ["outer": [replacement()]]), definition: definition)
    }

    func testVariantSamePathConflictPrecedesSelectedSlotOverlap() {
        let definition = fixture()
        assertError(.conflictingVariants(oldPath), ComponentInstance(definitionID: definitionID,
            variantSelection: ["size": "large", "state": "active"],
            slotContent: ["inner": [], "outer": [replacement()]]), definition: definition)
    }

    func testSelectedSlotOverlapPrecedesPriorWriteConflict() {
        let definition = fixture()
        assertError(.overlappingSlots(["inner", "outer"]), ComponentInstance(definitionID: definitionID,
            propertyValues: ["oldLabel": "Property"],
            slotContent: ["inner": [], "outer": [replacement()]]), definition: definition)
    }

    func testInvalidDefinitionWritePathWaitsForResolutionAfterVariantConflictPhase() {
        var definition = fixture()
        let missingPath = "layer_missing.text"
        definition.variants[0].propertyOverrides = [missingPath: "State"]
        definition.variants[1].propertyOverrides = [missingPath: "Size"]
        assertError(.conflictingVariants(missingPath), ComponentInstance(definitionID: definitionID,
            variantSelection: ["size": "large", "state": "active"],
            slotContent: ["outer": []]), definition: definition)
        assertError(.unknownPath(missingPath), ComponentInstance(definitionID: definitionID,
            variantSelection: ["state": "active"], slotContent: ["outer": []]), definition: definition)
    }

    func testUnknownInstanceAPIKeysPrecedeSelectedSlotOverlap() {
        let definition = fixture()
        let overlapping: [String: [Layer]] = ["inner": [], "outer": []]
        assertError(.unknownVariant("state", "missing"), ComponentInstance(definitionID: definitionID,
            variantSelection: ["state": "missing"], slotContent: overlapping), definition: definition)
        assertError(.unknownProperty("missing"), ComponentInstance(definitionID: definitionID,
            propertyValues: ["missing": "value"], slotContent: overlapping), definition: definition)
        assertError(.unknownSlot("missing"), ComponentInstance(definitionID: definitionID,
            slotContent: ["inner": [], "outer": [], "missing": []]), definition: definition)
    }

    func testForbiddenOverridePrecedesVariantAndSlotConflicts() {
        var definition = fixture()
        definition.api.overridablePaths.removeAll { $0 == outsidePath }
        assertError(.forbiddenOverride(outsidePath), ComponentInstance(definitionID: definitionID,
            variantSelection: ["size": "large", "state": "active"],
            slotContent: ["outer": [replacement()]],
            allowedOverrides: [outsidePath: "Not public"]), definition: definition)
    }

    func testPublicRemovedOverrideKeepsLateUnknownPath() {
        let definition = fixture()
        assertError(.unknownPath(oldPath), ComponentInstance(definitionID: definitionID,
            slotContent: ["outer": [replacement()]],
            allowedOverrides: [oldPath: "Too late"]), definition: definition)
    }

    func testValidVariantPropertyAndOverridePrecedenceKeepsDefinitionTree() throws {
        let definition = fixture()
        let resolved = try ComponentResolver.resolve(ComponentInstance(definitionID: definitionID,
            variantSelection: ["state": "active"], propertyValues: ["oldLabel": "Property"],
            slotContent: ["peer": [replacement()]],
            allowedOverrides: [oldPath: "Override"]), definition: definition)
        XCTAssertEqual(find(oldID, in: resolved)?.text, "Override")
        XCTAssertEqual(find(oldID, in: definition.root)?.text, "Base")
        XCTAssertEqual(find(peerID, in: resolved)?.children.map(\.id), [EntityID("layer_replacement")])
    }
}
