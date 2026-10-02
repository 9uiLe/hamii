import Darwin
import Foundation
import XCTest
import HamiiCore
import HamiiApplication
import HamiiFormat

final class ComponentPropertyAuthoringTests: XCTestCase {
    private let componentID = EntityID("component_property_card")
    private let screenID = EntityID("screen_property_primary")
    private let otherScreenID = EntityID("screen_property_secondary")
    private let plainID = EntityID("instance_property_plain")
    private let variantID = EntityID("instance_property_variant")
    private let slotID = EntityID("instance_property_slot")
    private let ordinaryID = EntityID("ordinary_property_text")
    private let oddName = "quote\"back\\slash"

    private struct Fixture {
        let root: URL
        let repository: CanonicalRepository
        let observed: ProjectObservation
        let definition: ComponentDefinition
    }

    private struct CLIResult {
        let status: Int32
        let stdout: String
        let stderr: String
        var json: [String: Any]? {
            guard let data = stdout.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    private func definition(owner: EntityID) -> ComponentDefinition {
        let label = Layer(id: EntityID("property_label_text"), kind: .text, name: "Label", text: "Base")
        let slot = Layer(id: EntityID("property_content_slot"), kind: .stack,
            name: "Content", children: [label])
        let root = Layer(id: EntityID("property_definition_root"), kind: .stack,
            name: "Card", children: [slot])
        var result = ComponentDefinition(id: componentID, name: "Property Card", ownerScopeID: owner, root: root)
        let path = "property_label_text.text"
        result.api.properties = ["label", "", "a.b", oddName, "-", "--json", "--state"].map {
            ComponentProperty(name: $0, kind: .text, targetPath: path)
        }
        result.api.slots = [ComponentSlot(name: "content", targetLayerID: slot.id)]
        result.variants = [ComponentVariant(id: EntityID("property_variant_active"),
            axis: "state", value: "active", propertyOverrides: [path: "Variant"])]
        return result
    }

    private func instance(_ id: EntityID, selection: [String: String] = [:],
                          slots: [String: [Layer]] = [:]) -> Layer {
        Layer(id: id, kind: .componentInstance, name: id.rawValue,
            component: ComponentInstance(definitionID: componentID,
                variantSelection: selection, slotContent: slots))
    }

    private func withFixture(_ body: (Fixture) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("component-property-authoring-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CanonicalRepository(root: root)
        _ = try repository.create(name: "Property authoring")
        let created = try repository.observe()
        var document = created.document
        let component = definition(owner: document.scopes[0].id)
        document.components = [component]
        document.screens = [
            Screen(id: screenID, name: "Primary", scopeID: document.scopes[0].id,
                root: Layer(id: EntityID("property_primary_root"), kind: .stack, name: "Root",
                    children: [
                        instance(plainID),
                        instance(variantID, selection: ["state": "active"]),
                        instance(slotID, slots: ["content": []]),
                        Layer(id: ordinaryID, kind: .text, name: "Ordinary", text: "ordinary")
                    ])),
            Screen(id: otherScreenID, name: "Secondary", scopeID: document.scopes[0].id,
                root: Layer(id: EntityID("property_secondary_root"), kind: .stack, name: "Root"))
        ]
        document.revision += 1
        XCTAssertEqual(DocumentValidator.validate(document), [])
        let observed = try repository.commit(document, expected: created)
        try body(Fixture(root: root, repository: repository, observed: observed, definition: component))
    }

    private func canonicalJSON(_ root: URL) throws -> [String: Data] {
        let manager = FileManager.default
        guard let entries = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return [:]
        }
        let prefix = root.resolvingSymlinksInPath().path + "/"
        var result: [String: Data] = [:]
        for case let entry as URL in entries {
            let path = entry.resolvingSymlinksInPath().path
            guard entry.pathExtension == "json", path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(prefix.count))
            guard !relative.hasPrefix(".hamii/"), !relative.hasPrefix(".git/") else { continue }
            result[relative] = try Data(contentsOf: entry)
        }
        return result
    }

    private func assertUnchanged(_ fixture: Fixture, before: [String: Data], revision: Int,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(before.isEmpty, file: file, line: line)
        XCTAssertEqual(try canonicalJSON(fixture.root), before, file: file, line: line)
        XCTAssertEqual(try CanonicalRepository(root: fixture.root).observe().document.revision,
            revision, file: file, line: line)
    }

    private func selected(_ document: Document, layerID: EntityID) throws -> ComponentInstance {
        let screen = try XCTUnwrap(document.screens.first { $0.id == screenID })
        return try XCTUnwrap(screen.root.children.first { $0.id == layerID }?.component)
    }

    private func text(_ id: EntityID, in root: Layer) -> String? {
        if root.id == id { return root.text }
        for child in root.children { if let found = text(id, in: child) { return found } }
        return nil
    }

    private func mutate(_ service: ProjectService, _ intent: AuthoringIntent,
                        state: ClientPrecondition, author: Author) throws -> MutationResult {
        try service.mutate(intent, expectedState: state, author: author,
            agent: author == .agent ? AgentHarness(profileName: "property-test") : nil)
    }

    private func assertValidation(_ rule: String, _ operation: () throws -> Void,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard case AuthoringError.validation(let diagnostics) = error else {
                return XCTFail("Expected validation, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(diagnostics.contains { $0.rule == rule }, "\(diagnostics)", file: file, line: line)
        }
    }

    func testHumanAndAgentSetUnsetPropertyPrecedenceAndSparseReopen() throws {
        for author in [Author.human, .agent] {
            try withFixture { fixture in
                let service = ProjectService(repository: fixture.repository)
                let initial = try service.observe()
                let set = try mutate(service, .setComponentProperty(screenID: screenID,
                    layerID: variantID, name: "label", value: "Property"),
                    state: initial.statePrecondition, author: author)
                XCTAssertEqual(set.revision, initial.document.revision + 1)
                XCTAssertEqual(set.patches, [SemanticPatch(entityID: variantID,
                    path: "component.propertyValues[\"label\"]", oldValue: nil, newValue: "Property")])
                let reopened = try CanonicalRepository(root: fixture.root).observe()
                let stored = try selected(reopened.document, layerID: variantID)
                XCTAssertEqual(stored.propertyValues, ["label": "Property"])
                XCTAssertEqual(stored.variantSelection, ["state": "active"])
                XCTAssertEqual(stored.definitionID, componentID)
                XCTAssertTrue(reopened.document.screens[0].root.children[1].children.isEmpty)
                XCTAssertEqual(reopened.document.components[0].root, fixture.definition.root)
                let resolved = try ComponentResolver.resolve(stored, definition: fixture.definition)
                XCTAssertEqual(text(EntityID("property_label_text"), in: resolved), "Property",
                    "Instance property must take precedence over the selected Variant")

                let beforeNoop = try canonicalJSON(fixture.root)
                let same = try mutate(service, .setComponentProperty(screenID: screenID,
                    layerID: variantID, name: "label", value: "Property"),
                    state: try XCTUnwrap(set.statePrecondition), author: author)
                XCTAssertEqual(same.revision, set.revision)
                XCTAssertEqual(same.patches, [])
                XCTAssertEqual(same.statePrecondition, set.statePrecondition)
                try assertUnchanged(fixture, before: beforeNoop, revision: set.revision)

                let unset = try mutate(service, .unsetComponentProperty(screenID: screenID,
                    layerID: variantID, name: "label"),
                    state: try XCTUnwrap(same.statePrecondition), author: author)
                XCTAssertEqual(unset.revision, set.revision + 1)
                XCTAssertEqual(unset.patches, [SemanticPatch(entityID: variantID,
                    path: "component.propertyValues[\"label\"]", oldValue: "Property", newValue: nil)])
                let afterUnset = try CanonicalRepository(root: fixture.root).observe()
                let reverted = try selected(afterUnset.document, layerID: variantID)
                XCTAssertTrue(reverted.propertyValues.isEmpty)
                XCTAssertEqual(text(EntityID("property_label_text"),
                    in: try ComponentResolver.resolve(reverted, definition: fixture.definition)), "Variant")
            }
        }
    }

    func testKnownUnsetNoopAndRejectedPropertyEditsLeaveCanonicalUnchanged() throws {
        try withFixture { fixture in
            let service = ProjectService(repository: fixture.repository)
            let initial = try service.observe()
            let before = try canonicalJSON(fixture.root)
            let unset = try mutate(service, .unsetComponentProperty(screenID: screenID,
                layerID: plainID, name: "label"), state: initial.statePrecondition, author: .human)
            XCTAssertEqual(unset.revision, initial.document.revision)
            XCTAssertEqual(unset.patches, [])
            XCTAssertEqual(unset.statePrecondition, initial.statePrecondition)
            try assertUnchanged(fixture, before: before, revision: initial.document.revision)

            for intent in [
                AuthoringIntent.setComponentProperty(screenID: screenID, layerID: plainID,
                    name: "unknown", value: "text"),
                .unsetComponentProperty(screenID: screenID, layerID: plainID, name: "unknown")
            ] {
                assertValidation("component.property") {
                    _ = try mutate(service, intent, state: initial.statePrecondition, author: .agent)
                }
                try assertUnchanged(fixture, before: before, revision: initial.document.revision)
            }
            assertValidation("component.resolution") {
                _ = try mutate(service, .setComponentProperty(screenID: screenID,
                    layerID: slotID, name: "label", value: "removed by slot"),
                    state: initial.statePrecondition, author: .human)
            }
            try assertUnchanged(fixture, before: before, revision: initial.document.revision)

            assertValidation("component.instanceRequired") {
                _ = try mutate(service, .setComponentProperty(screenID: screenID,
                    layerID: ordinaryID, name: "label", value: "wrong kind"),
                    state: initial.statePrecondition, author: .human)
            }
            try assertUnchanged(fixture, before: before, revision: initial.document.revision)
            XCTAssertThrowsError(try mutate(service, .setComponentProperty(screenID: otherScreenID,
                layerID: plainID, name: "label", value: "wrong screen"),
                state: initial.statePrecondition, author: .human)) { error in
                guard case AuthoringError.notFound = error else { return XCTFail("\(error)") }
            }
            try assertUnchanged(fixture, before: before, revision: initial.document.revision)

            _ = try mutate(service, .setComponentProperty(screenID: screenID,
                layerID: plainID, name: "label", value: "Committed"),
                state: initial.statePrecondition, author: .human)
            let afterSuccess = try canonicalJSON(fixture.root)
            let revision = try service.observe().document.revision
            XCTAssertThrowsError(try mutate(service, .unsetComponentProperty(screenID: screenID,
                layerID: plainID, name: "label"), state: initial.statePrecondition, author: .agent)) { error in
                guard case AuthoringError.staleState = error else { return XCTFail("\(error)") }
            }
            try assertUnchanged(fixture, before: afterSuccess, revision: revision)
        }
    }

    func testArbitraryPropertyNamesAndLiteralValuesUseUnambiguousPatchPaths() throws {
        for (name, value) in [
            ("", ""), ("label", ""), ("a.b", "dots"),
            (oddName, "quote\"value\\tail"), ("-", "-"),
            ("--json", "--json"), ("--state", "--state")
        ] {
            try withFixture { fixture in
                let service = ProjectService(repository: fixture.repository)
                let initial = try service.observe()
                let set = try mutate(service, .setComponentProperty(screenID: screenID,
                    layerID: plainID, name: name, value: value),
                    state: initial.statePrecondition, author: .human)
                let quoted = String(decoding: try JSONEncoder().encode(name), as: UTF8.self)
                XCTAssertEqual(set.patches, [SemanticPatch(entityID: plainID,
                    path: "component.propertyValues[\(quoted)]", oldValue: nil, newValue: value)])
                let reopened = try CanonicalRepository(root: fixture.root).observe()
                XCTAssertEqual(try selected(reopened.document, layerID: plainID).propertyValues, [name: value])
                XCTAssertTrue(reopened.document.screens[0].root.children[0].children.isEmpty)
            }
        }
    }

    private func cli(_ fixture: Fixture, arguments: [String], json: Bool = true) throws -> CLIResult {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let binary = root.appendingPathComponent(".build/debug/hamii")
        XCTAssertTrue(FileManager.default.fileExists(atPath: binary.path), "Build hamii before CLI tests")
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--project", fixture.root.path] + (json ? ["--json"] : []) + arguments
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning && Date() < deadline { usleep(10_000) }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            XCTFail("hamii CLI timed out: \(arguments)")
        }
        process.waitUntilExit()
        return CLIResult(status: process.terminationStatus,
            stdout: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    private func propertyCLI(_ fixture: Fixture, _ action: String, layer: EntityID,
                             name: String, value: String? = nil,
                             state: ClientPrecondition) throws -> CLIResult {
        var args = ["component", "property", action, screenID.rawValue, layer.rawValue,
            name, "--state", state.rawValue]
        if let value { args.insert(value, at: 6) }
        return try cli(fixture, arguments: args)
    }

    func testCLIJSONSuccessValidationConflictNoopAndSparseReopen() throws {
        try withFixture { fixture in
            let state = fixture.observed.statePrecondition
            let before = try canonicalJSON(fixture.root)
            for (layer, name, value) in [(plainID, "unknown", "bad"),
                                         (slotID, "label", "removed")] {
                let failed = try propertyCLI(fixture, "set", layer: layer,
                    name: name, value: value, state: state)
                XCTAssertEqual(failed.status, 5, failed.stdout + failed.stderr)
                XCTAssertEqual(failed.json?["ok"] as? Bool, false)
                XCTAssertEqual(failed.json?["category"] as? String, "validation")
                try assertUnchanged(fixture, before: before, revision: fixture.observed.document.revision)
            }
            let success = try propertyCLI(fixture, "set", layer: plainID,
                name: "label", value: "CLI text", state: state)
            XCTAssertEqual(success.status, 0, success.stdout + success.stderr)
            XCTAssertEqual(success.json?["ok"] as? Bool, true)
            let mutation = try XCTUnwrap(success.json?["mutation"] as? [String: Any])
            XCTAssertEqual(mutation["revision"] as? Int, fixture.observed.document.revision + 1)
            XCTAssertEqual((mutation["patches"] as? [[String: Any]])?.first?["path"] as? String,
                "component.propertyValues[\"label\"]")
            let current = ClientPrecondition(try XCTUnwrap(
                (mutation["statePrecondition"] as? [String: Any])?["rawValue"] as? String))
            let afterSuccess = try canonicalJSON(fixture.root)
            let same = try propertyCLI(fixture, "set", layer: plainID,
                name: "label", value: "CLI text", state: current)
            XCTAssertEqual(same.status, 0, same.stdout + same.stderr)
            let sameMutation = try XCTUnwrap(same.json?["mutation"] as? [String: Any])
            XCTAssertEqual(sameMutation["revision"] as? Int, mutation["revision"] as? Int)
            XCTAssertEqual((sameMutation["patches"] as? [Any])?.count, 0)
            XCTAssertEqual((sameMutation["statePrecondition"] as? [String: Any])?["rawValue"] as? String,
                current.rawValue)
            try assertUnchanged(fixture, before: afterSuccess, revision: fixture.observed.document.revision + 1)
            let reopened = try CanonicalRepository(root: fixture.root).observe()
            XCTAssertEqual(try selected(reopened.document, layerID: plainID).propertyValues,
                ["label": "CLI text"])
            XCTAssertTrue(reopened.document.screens[0].root.children[0].children.isEmpty)
            let stale = try propertyCLI(fixture, "unset", layer: plainID, name: "label", state: state)
            XCTAssertEqual(stale.status, 3, stale.stdout + stale.stderr)
            XCTAssertEqual(stale.json?["ok"] as? Bool, false)
            XCTAssertEqual(stale.json?["category"] as? String, "conflict")
            try assertUnchanged(fixture, before: afterSuccess, revision: fixture.observed.document.revision + 1)
        }
    }

    func testCLIDelimiterPreservesLiteralPropertyNameAndValue() throws {
        try withFixture { fixture in
            var state = fixture.observed.statePrecondition
            func update(_ result: CLIResult) throws {
                XCTAssertEqual(result.status, 0, result.stdout + result.stderr)
                XCTAssertEqual(result.json?["ok"] as? Bool, true)
                let mutation = try XCTUnwrap(result.json?["mutation"] as? [String: Any])
                state = ClientPrecondition(try XCTUnwrap(
                    (mutation["statePrecondition"] as? [String: Any])?["rawValue"] as? String))
            }
            try update(propertyCLI(fixture, "set", layer: plainID,
                name: "-", value: "-", state: state))
            XCTAssertEqual(try selected(fixture.repository.observe().document, layerID: plainID)
                .propertyValues["-"], "-")
            let jsonValue = try cli(fixture, arguments: ["component", "property", "set",
                screenID.rawValue, plainID.rawValue, "label", "--state", state.rawValue,
                "--", "--json"])
            try update(jsonValue)
            XCTAssertEqual(try selected(fixture.repository.observe().document, layerID: plainID)
                .propertyValues["label"], "--json")
            let stateValue = try cli(fixture, arguments: ["component", "property", "set",
                screenID.rawValue, plainID.rawValue, "label", "--state", state.rawValue,
                "--", "--state"])
            try update(stateValue)
            XCTAssertEqual(try selected(fixture.repository.observe().document, layerID: plainID)
                .propertyValues["label"], "--state")
            try update(propertyCLI(fixture, "unset", layer: plainID, name: "label", state: state))
            let jsonName = try cli(fixture, arguments: ["component", "property", "set",
                screenID.rawValue, plainID.rawValue, "--state", state.rawValue,
                "--", "--json", "value"])
            try update(jsonName)
            XCTAssertEqual(try selected(fixture.repository.observe().document, layerID: plainID)
                .propertyValues["--json"], "value")
            let unsetJsonName = try cli(fixture, arguments: ["component", "property", "unset",
                screenID.rawValue, plainID.rawValue, "--state", state.rawValue,
                "--", "--json"])
            try update(unsetJsonName)
            let stateName = try cli(fixture, arguments: ["component", "property", "set",
                screenID.rawValue, plainID.rawValue, "--state", state.rawValue,
                "--", "--state", "value"])
            try update(stateName)
            XCTAssertEqual(try selected(fixture.repository.observe().document, layerID: plainID)
                .propertyValues["--state"], "value")
        }
    }

    func testCLIEmptyPropertyNameAndValueRemainDistinctFromUnset() throws {
        try withFixture { fixture in
            let initial = fixture.observed
            let set = try propertyCLI(fixture, "set", layer: plainID,
                name: "", value: "", state: initial.statePrecondition)
            XCTAssertEqual(set.status, 0, set.stdout + set.stderr)
            XCTAssertEqual(set.json?["ok"] as? Bool, true)
            let mutation = try XCTUnwrap(set.json?["mutation"] as? [String: Any])
            XCTAssertEqual(mutation["revision"] as? Int, initial.document.revision + 1)
            let patch = try XCTUnwrap((mutation["patches"] as? [[String: Any]])?.first)
            XCTAssertEqual(patch["path"] as? String, "component.propertyValues[\"\"]")
            XCTAssertEqual(patch["newValue"] as? String, "")
            let state = ClientPrecondition(try XCTUnwrap(
                (mutation["statePrecondition"] as? [String: Any])?["rawValue"] as? String))
            let saved = try CanonicalRepository(root: fixture.root).observe()
            XCTAssertEqual(try selected(saved.document, layerID: plainID).propertyValues, ["": ""])
            XCTAssertTrue(saved.document.screens[0].root.children[0].children.isEmpty)

            let unset = try propertyCLI(fixture, "unset", layer: plainID,
                name: "", state: state)
            XCTAssertEqual(unset.status, 0, unset.stdout + unset.stderr)
            XCTAssertEqual(unset.json?["ok"] as? Bool, true)
            let unsetMutation = try XCTUnwrap(unset.json?["mutation"] as? [String: Any])
            XCTAssertEqual(unsetMutation["revision"] as? Int, initial.document.revision + 2)
            let unsetPatch = try XCTUnwrap((unsetMutation["patches"] as? [[String: Any]])?.first)
            XCTAssertEqual(unsetPatch["path"] as? String, "component.propertyValues[\"\"]")
            XCTAssertEqual(unsetPatch["oldValue"] as? String, "")
            XCTAssertNil(unsetPatch["newValue"])
            XCTAssertEqual(try selected(CanonicalRepository(root: fixture.root).observe().document,
                layerID: plainID).propertyValues, [:])
        }
    }
}
