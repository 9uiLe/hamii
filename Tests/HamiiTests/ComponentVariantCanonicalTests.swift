import Foundation
import XCTest
import HamiiCore
import HamiiApplication
import HamiiFormat

/// Whole-Document and persisted-format coverage for component resolution.
/// Resolver error precedence has direct unit tests; these tests check that its
/// result remains authoritative at the validation and Canonical boundaries.
final class ComponentVariantCanonicalTests: XCTestCase {
    private let componentID = EntityID("component_card")
    private let instanceID = EntityID("screen_instance")
    private let oldTextPath = "old_text.text"

    private struct Fixture {
        let root: URL
        let repository: CanonicalRepository
        let observed: ProjectObservation
        let definition: ComponentDefinition
    }

    private func text(_ id: String, _ value: String = "Base") -> Layer {
        Layer(id: EntityID(id), kind: .text, name: id, text: value)
    }

    private func stack(_ id: String, children: [Layer] = []) -> Layer {
        Layer(id: EntityID(id), kind: .stack, name: id, children: children)
    }

    private func definition(owner: EntityID) -> ComponentDefinition {
        let inner = stack("inner_slot", children: [text("old_text")])
        let outer = stack("outer_slot", children: [inner])
        let side = stack("side_slot", children: [text("side_text")])
        var definition = ComponentDefinition(id: componentID, name: "Card", ownerScopeID: owner,
            root: stack("definition_root", children: [outer, side]))
        definition.api = ComponentAPI(
            properties: [ComponentProperty(name: "label", kind: .text, targetPath: oldTextPath)],
            slots: [
                ComponentSlot(name: "a_duplicate", targetLayerID: EntityID("outer_slot")),
                ComponentSlot(name: "z_duplicate", targetLayerID: EntityID("outer_slot")),
                ComponentSlot(name: "a_outer", targetLayerID: EntityID("outer_slot")),
                ComponentSlot(name: "z_outer", targetLayerID: EntityID("outer_slot")),
                ComponentSlot(name: "a_inner", targetLayerID: EntityID("inner_slot")),
                ComponentSlot(name: "z_inner", targetLayerID: EntityID("inner_slot")),
                ComponentSlot(name: "side", targetLayerID: EntityID("side_slot"))
            ],
            overridablePaths: [oldTextPath])
        definition.variants = [
            ComponentVariant(id: EntityID("variant_active"), axis: "state", value: "active",
                propertyOverrides: [oldTextPath: "Active"]),
            ComponentVariant(id: EntityID("variant_small"), axis: "size", value: "small",
                propertyOverrides: [oldTextPath: "Small"])
        ]
        return definition
    }

    private func withFixture(_ body: (Fixture) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("component-canonical-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CanonicalRepository(root: root)
        _ = try repository.create(name: "Component boundary")
        let created = try repository.observe()
        var base = created.document
        let definition = definition(owner: base.scopes[0].id)
        base.components = [definition]
        let instance = ComponentInstance(definitionID: definition.id)
        base.screens = [Screen(id: EntityID("screen_card"), name: "Card", scopeID: base.scopes[0].id,
            root: stack("screen_root", children: [Layer(id: instanceID, kind: .componentInstance,
                name: "Card instance", component: instance)]))]
        base.revision += 1
        let observed = try repository.commit(base, expected: created)
        XCTAssertEqual(DocumentValidator.validate(observed.document), [])
        try body(Fixture(root: root, repository: repository, observed: observed, definition: definition))
    }

    private func candidate(_ fixture: Fixture, instance: ComponentInstance) -> Document {
        var document = fixture.observed.document
        document.screens[0].root.children[0].component = instance
        document.revision += 1
        return document
    }

    /// Compare the actual current-format files, not a re-encoded Document.
    private func canonicalJSON(at root: URL) throws -> [String: Data] {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return [:]
        }
        let prefix = root.resolvingSymlinksInPath().path + "/"
        var files: [String: Data] = [:]
        for case let url as URL in enumerator {
            let path = url.resolvingSymlinksInPath().path
            guard url.pathExtension == "json", path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(prefix.count))
            guard !relative.hasPrefix(".hamii/"), !relative.hasPrefix(".git/") else { continue }
            files[relative] = try Data(contentsOf: url)
        }
        return files
    }

    private func assertRejected(_ fixture: Fixture, _ document: Document,
                                rule: String = "component.resolution", file: StaticString = #filePath,
                                line: UInt = #line) throws {
        let diagnostics = DocumentValidator.validate(document)
        XCTAssertTrue(diagnostics.contains { $0.rule == rule }, "\(diagnostics)", file: file, line: line)
        let before = try canonicalJSON(at: fixture.root)
        XCTAssertFalse(before.isEmpty, file: file, line: line)
        XCTAssertThrowsError(try fixture.repository.commit(document, expected: fixture.observed), file: file, line: line) { error in
            guard case CanonicalError.invalid(let savedDiagnostics) = error else {
                return XCTFail("Unexpected rejection: \(error)", file: file, line: line)
            }
            XCTAssertTrue(savedDiagnostics.contains { $0.rule == rule }, "\(savedDiagnostics)", file: file, line: line)
        }
        XCTAssertEqual(try canonicalJSON(at: fixture.root), before,
            "Tracked Canonical JSON paths and bytes must remain unchanged", file: file, line: line)
        let reopened = try CanonicalRepository(root: fixture.root).observe()
        XCTAssertEqual(reopened.document.revision, fixture.observed.document.revision, file: file, line: line)
        XCTAssertEqual(reopened.document, fixture.observed.document, file: file, line: line)
    }

    private func assertSparseReopen(_ fixture: Fixture, _ document: Document,
                                    instance: ComponentInstance, file: StaticString = #filePath,
                                    line: UInt = #line) throws {
        XCTAssertEqual(DocumentValidator.validate(document), [], file: file, line: line)
        let saved = try fixture.repository.commit(document, expected: fixture.observed)
        let reopened = try CanonicalRepository(root: fixture.root).observe()
        XCTAssertEqual(reopened.document, saved.document, file: file, line: line)
        let storedLayer = try XCTUnwrap(reopened.document.screens.first?.root.children.first, file: file, line: line)
        XCTAssertEqual(storedLayer.component, instance, file: file, line: line)
        XCTAssertTrue(storedLayer.children.isEmpty, "Resolved Definition descendants must not be copied into the instance", file: file, line: line)
        XCTAssertEqual(reopened.document.components.first?.root, fixture.definition.root, file: file, line: line)
    }

    func testSameTargetSelectedSlotsRejectAndPreserveCanonicalBytes() throws {
        try withFixture { fixture in
            let instance = ComponentInstance(definitionID: componentID,
                slotContent: ["a_duplicate": [], "z_duplicate": [text("replacement_duplicate")]])
            try assertRejected(fixture, candidate(fixture, instance: instance))
            XCTAssertThrowsError(try ComponentResolver.resolve(instance, definition: fixture.definition)) { error in
                XCTAssertEqual(error as? ComponentResolutionError,
                    .overlappingSlots(["a_duplicate", "z_duplicate"]))
            }
        }
    }

    func testAncestorSelectedSlotsRejectInBothNameOrders() throws {
        for names in [("a_outer", "z_inner"), ("z_outer", "a_inner")] {
            try withFixture { fixture in
                let instance = ComponentInstance(definitionID: componentID,
                    slotContent: [names.0: [], names.1: [text("replacement_ancestor")]])
                try assertRejected(fixture, candidate(fixture, instance: instance))
                XCTAssertThrowsError(try ComponentResolver.resolve(instance, definition: fixture.definition)) { error in
                    XCTAssertEqual(error as? ComponentResolutionError,
                        .overlappingSlots([names.0, names.1].sorted()))
                }
            }
        }
    }

    func testSelectedVariantAndPropertyWritesRemovedBySlotReject() throws {
        try withFixture { fixture in
            let instance = ComponentInstance(definitionID: componentID,
                variantSelection: ["state": "active"], slotContent: ["a_outer": []])
            try assertRejected(fixture, candidate(fixture, instance: instance))
            XCTAssertThrowsError(try ComponentResolver.resolve(instance, definition: fixture.definition)) { error in
                XCTAssertEqual(error as? ComponentResolutionError,
                    .slotWriteConflict(path: oldTextPath, slotName: "a_outer"))
            }
        }
        try withFixture { fixture in
            let instance = ComponentInstance(definitionID: componentID,
                propertyValues: ["label": "New"], slotContent: ["a_outer": []])
            try assertRejected(fixture, candidate(fixture, instance: instance))
            XCTAssertThrowsError(try ComponentResolver.resolve(instance, definition: fixture.definition)) { error in
                XCTAssertEqual(error as? ComponentResolutionError,
                    .slotWriteConflict(path: oldTextPath, slotName: "a_outer"))
            }
        }
    }

    func testNonoverlapSlotsSaveAndReopenAsSparseInstance() throws {
        try withFixture { fixture in
            let instance = ComponentInstance(definitionID: componentID,
                slotContent: ["a_inner": [text("replacement_inner")], "side": []])
            try assertSparseReopen(fixture, candidate(fixture, instance: instance), instance: instance)
        }
    }

    func testSuccessfulVariantPropertyOverrideAndUnrelatedSlotRemainSparseAfterReopen() throws {
        try withFixture { fixture in
            let instance = ComponentInstance(definitionID: componentID,
                variantSelection: ["state": "active"], propertyValues: ["label": "Property"],
                slotContent: ["side": [text("replacement_side")]],
                allowedOverrides: [oldTextPath: "Public override"])
            let resolved = try ComponentResolver.resolve(instance, definition: fixture.definition)
            XCTAssertEqual(resolved.children[0].children[0].children[0].text, "Public override")
            try assertSparseReopen(fixture, candidate(fixture, instance: instance), instance: instance)
        }
    }

    func testRemovedPublicOverrideIsLateUnknownPathAndForbiddenOverrideHasPriority() throws {
        try withFixture { fixture in
            let instance = ComponentInstance(definitionID: componentID,
                slotContent: ["a_outer": []], allowedOverrides: [oldTextPath: "Override"])
            XCTAssertThrowsError(try ComponentResolver.resolve(instance, definition: fixture.definition)) { error in
                XCTAssertEqual(error as? ComponentResolutionError, .unknownPath(oldTextPath))
            }
            try assertRejected(fixture, candidate(fixture, instance: instance))
        }
        try withFixture { fixture in
            let instance = ComponentInstance(definitionID: componentID,
                variantSelection: ["state": "active", "size": "small"],
                allowedOverrides: ["side_text.text": "Forbidden"])
            XCTAssertThrowsError(try ComponentResolver.resolve(instance, definition: fixture.definition)) { error in
                XCTAssertEqual(error as? ComponentResolutionError, .forbiddenOverride("side_text.text"))
            }
            try assertRejected(fixture, candidate(fixture, instance: instance))
        }
    }

    func testNestedDefinitionSavesReferenceAndCycleRejectsWithoutCanonicalChanges() throws {
        try withFixture { fixture in
            let scope = fixture.observed.document.scopes[0].id
            let nestedID = EntityID("component_nested")
            let nestedInstance = ComponentInstance(definitionID: nestedID)
            let nestedLayer = Layer(id: EntityID("nested_ref"), kind: .componentInstance,
                name: "Nested reference", component: nestedInstance)
            let outer = ComponentDefinition(id: EntityID("component_outer_nested"), name: "Outer",
                ownerScopeID: scope, root: stack("outer_nested_root", children: [nestedLayer]))
            let inner = ComponentDefinition(id: nestedID, name: "Inner", ownerScopeID: scope,
                root: stack("inner_nested_root", children: [text("inner_nested_text")]))
            let screenInstance = ComponentInstance(definitionID: outer.id)
            var valid = fixture.observed.document
            valid.components += [outer, inner]
            valid.screens[0].root.children[0].component = screenInstance
            valid.revision += 1
            let direct = try ComponentResolver.resolve(screenInstance, definition: outer)
            XCTAssertEqual(direct.children.first?.component?.definitionID, nestedID)
            XCTAssertTrue(direct.children.first?.children.isEmpty == true,
                "Direct resolution must preserve the nested Definition reference")
            XCTAssertEqual(DocumentValidator.validate(valid), [])
            let saved = try fixture.repository.commit(valid, expected: fixture.observed)
            let reopened = try CanonicalRepository(root: fixture.root).observe()
            XCTAssertEqual(reopened.document.revision, saved.document.revision)
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: reopened.document.components.map { ($0.id, $0) }),
                Dictionary(uniqueKeysWithValues: saved.document.components.map { ($0.id, $0) }))
            XCTAssertEqual(reopened.document.screens[0].root.children[0].component, screenInstance)
            XCTAssertTrue(reopened.document.screens[0].root.children[0].children.isEmpty)

            var cycle = reopened.document
            let backReference = Layer(id: EntityID("back_ref"), kind: .componentInstance,
                name: "Back reference", component: ComponentInstance(definitionID: outer.id))
            let nestedIndex = try XCTUnwrap(cycle.components.firstIndex { $0.id == nestedID })
            cycle.components[nestedIndex].root.children = [backReference]
            cycle.revision += 1
            let cycleBase = try fixture.repository.observe()
            let cycleFixture = Fixture(root: fixture.root, repository: fixture.repository,
                observed: cycleBase, definition: fixture.definition)
            try assertRejected(cycleFixture, cycle, rule: "component.cycle")
        }
    }
}
