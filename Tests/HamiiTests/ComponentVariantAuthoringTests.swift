import Darwin
import Foundation
import XCTest
import HamiiCore
import HamiiApplication
import HamiiFormat

final class ComponentVariantAuthoringTests: XCTestCase {
    private let componentID = EntityID("component_variants")
    private let screenID = EntityID("screen_primary")
    private let otherScreenID = EntityID("screen_secondary")
    private let plainID = EntityID("instance_plain")
    private let conflictID = EntityID("instance_conflict")
    private let slotID = EntityID("instance_slot")
    private let oddAxis = "quote\"back\\slash"

    private struct Fixture {
        let root: URL
        let repository: CanonicalRepository
        let observed: ProjectObservation
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

    private func layer(_ id: String, text: String) -> Layer {
        Layer(id: EntityID(id), kind: .text, name: id, text: text)
    }

    private func definition(owner: EntityID, equalityPairs: Bool) -> ComponentDefinition {
        let label = layer("label_text", text: "Label")
        let content = Layer(id: EntityID("content_slot"), kind: .stack, name: "Content", children: [label])
        let subtitle = layer("subtitle_text", text: "Subtitle")
        let badge = layer("badge_text", text: "Badge")
        let root = Layer(id: EntityID("definition_root"), kind: .stack, name: "Root",
            children: [content, subtitle, badge])
        var result = ComponentDefinition(id: componentID, name: "Variants", ownerScopeID: owner, root: root)
        result.api.slots = [ComponentSlot(name: "content", targetLayerID: content.id)]
        result.variants = [
            ComponentVariant(id: EntityID("variant_state"), axis: "state", value: "active",
                propertyOverrides: ["label_text.text": "Active"]),
            ComponentVariant(id: EntityID("variant_size"), axis: "size", value: "large",
                propertyOverrides: ["label_text.text": "Large"]),
            ComponentVariant(id: EntityID("variant_literal_dash"), axis: "literal", value: "-",
                propertyOverrides: ["subtitle_text.text": "Dash"]),
            ComponentVariant(id: EntityID("variant_literal_json"), axis: "literal", value: "--json",
                propertyOverrides: ["subtitle_text.text": "JSON"]),
            ComponentVariant(id: EntityID("variant_dot"), axis: "a.b", value: "on",
                propertyOverrides: ["subtitle_text.text": "Dot"]),
            ComponentVariant(id: EntityID("variant_quote"), axis: oddAxis, value: "on",
                propertyOverrides: ["subtitle_text.text": "Quote"]),
            ComponentVariant(id: EntityID("variant_axis_json"), axis: "--json", value: "on",
                propertyOverrides: ["subtitle_text.text": "Axis JSON"]),
            ComponentVariant(id: EntityID("variant_axis_state"), axis: "--state", value: "on",
                propertyOverrides: ["subtitle_text.text": "Axis state"])
        ]
        if equalityPairs {
            result.variants += [
                ComponentVariant(id: EntityID("variant_equal_left"), axis: "a=b", value: "c",
                    propertyOverrides: ["subtitle_text.text": "Left"]),
                ComponentVariant(id: EntityID("variant_equal_right"), axis: "a", value: "b=c",
                    propertyOverrides: ["badge_text.text": "Right"])
            ]
        }
        return result
    }

    private func instanceLayer(_ id: EntityID, selection: [String: String] = [:],
                               slots: [String: [Layer]] = [:]) -> Layer {
        Layer(id: id, kind: .componentInstance, name: id.rawValue,
            component: ComponentInstance(definitionID: componentID,
                variantSelection: selection, slotContent: slots))
    }

    private func withFixture(equalityPairs: Bool = false, _ body: (Fixture) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("component-variant-authoring-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CanonicalRepository(root: root)
        _ = try repository.create(name: "Variant authoring")
        let created = try repository.observe()
        var base = created.document
        base.components = [definition(owner: base.scopes[0].id, equalityPairs: equalityPairs)]
        base.screens = [
            Screen(id: screenID, name: "Primary", scopeID: base.scopes[0].id,
                root: Layer(id: EntityID("primary_root"), kind: .stack, name: "Root",
                    children: [
                        instanceLayer(plainID),
                        instanceLayer(conflictID, selection: ["size": "large"]),
                        instanceLayer(slotID, slots: ["content": []]),
                        layer("ordinary_text", text: "Not a component")
                    ])),
            Screen(id: otherScreenID, name: "Secondary", scopeID: base.scopes[0].id,
                root: Layer(id: EntityID("secondary_root"), kind: .stack, name: "Root"))
        ]
        base.revision += 1
        XCTAssertEqual(DocumentValidator.validate(base), [])
        let observed = try repository.commit(base, expected: created)
        try body(Fixture(root: root, repository: repository, observed: observed))
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

    private func mutate(_ service: ProjectService, _ intent: AuthoringIntent,
                        state: ClientPrecondition, author: Author) throws -> MutationResult {
        try service.mutate(intent, expectedState: state, author: author,
            agent: author == .agent ? AgentHarness(profileName: "variant-test") : nil)
    }

    private func assertValidation(_ expectedRule: String, _ operation: () throws -> Void,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard case AuthoringError.validation(let diagnostics) = error else {
                return XCTFail("Expected validation, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(diagnostics.contains { $0.rule == expectedRule },
                "\(diagnostics)", file: file, line: line)
        }
    }

    func testHumanAndAgentShareSetUnsetAndSparsePersistence() throws {
        for author in [Author.human, .agent] {
            try withFixture { fixture in
                let service = ProjectService(repository: fixture.repository)
                let initial = try service.observe()
                let set = try mutate(service, .setComponentVariant(screenID: screenID, layerID: plainID,
                    axis: "state", value: "active"), state: initial.statePrecondition, author: author)
                XCTAssertEqual(set.revision, initial.document.revision + 1)
                XCTAssertEqual(set.patches, [SemanticPatch(entityID: plainID,
                    path: "component.variantSelection[\"state\"]", oldValue: nil, newValue: "active")])
                let reopened = try CanonicalRepository(root: fixture.root).observe()
                let instance = try selected(reopened.document, layerID: plainID)
                XCTAssertEqual(instance.variantSelection, ["state": "active"])
                XCTAssertTrue(reopened.document.screens[0].root.children[0].children.isEmpty)
                XCTAssertEqual(instance.definitionID, componentID)

                let beforeNoop = try canonicalJSON(fixture.root)
                let same = try mutate(service, .setComponentVariant(screenID: screenID, layerID: plainID,
                    axis: "state", value: "active"), state: try XCTUnwrap(set.statePrecondition), author: author)
                XCTAssertEqual(same.revision, set.revision)
                XCTAssertEqual(same.patches, [])
                XCTAssertEqual(same.statePrecondition, set.statePrecondition)
                try assertUnchanged(fixture, before: beforeNoop, revision: set.revision)

                let unset = try mutate(service, .unsetComponentVariant(screenID: screenID, layerID: plainID,
                    axis: "state"), state: try XCTUnwrap(same.statePrecondition), author: author)
                XCTAssertEqual(unset.revision, set.revision + 1)
                XCTAssertEqual(unset.patches, [SemanticPatch(entityID: plainID,
                    path: "component.variantSelection[\"state\"]", oldValue: "active", newValue: nil)])
                XCTAssertEqual(try selected(CanonicalRepository(root: fixture.root).observe().document,
                    layerID: plainID).variantSelection, [:])
            }
        }
    }

    func testKnownUnselectedUnsetNoopsAndUnknownAxisUnsetRejects() throws {
        try withFixture { fixture in
            let service = ProjectService(repository: fixture.repository)
            let initial = try service.observe()
            let before = try canonicalJSON(fixture.root)
            let unselected = try mutate(service, .unsetComponentVariant(screenID: screenID,
                layerID: plainID, axis: "state"), state: initial.statePrecondition, author: .human)
            XCTAssertEqual(unselected.revision, initial.document.revision)
            XCTAssertEqual(unselected.patches, [])
            XCTAssertEqual(unselected.statePrecondition, initial.statePrecondition)
            try assertUnchanged(fixture, before: before, revision: initial.document.revision)

            assertValidation("component.variant", {
                _ = try mutate(service, .unsetComponentVariant(screenID: screenID,
                    layerID: plainID, axis: "missing"), state: initial.statePrecondition, author: .agent)
            })
            try assertUnchanged(fixture, before: before, revision: initial.document.revision)
        }
    }

    func testInvalidSelectionResolverConflictsAndStaleStatePreserveCanonical() throws {
        try withFixture { fixture in
            let service = ProjectService(repository: fixture.repository)
            let initial = try service.observe()
            let before = try canonicalJSON(fixture.root)
            let rejected: [(AuthoringIntent, String)] = [
                (.setComponentVariant(screenID: screenID, layerID: plainID, axis: "missing", value: "on"), "component.variant"),
                (.setComponentVariant(screenID: screenID, layerID: plainID, axis: "state", value: "missing"), "component.variant"),
                (.setComponentVariant(screenID: screenID, layerID: conflictID, axis: "state", value: "active"), "component.resolution"),
                (.setComponentVariant(screenID: screenID, layerID: slotID, axis: "state", value: "active"), "component.resolution")
            ]
            for (intent, rule) in rejected {
                assertValidation(rule, {
                    _ = try mutate(service, intent, state: initial.statePrecondition, author: .agent)
                })
                try assertUnchanged(fixture, before: before, revision: initial.document.revision)
            }
            _ = try mutate(service, .setComponentVariant(screenID: screenID, layerID: plainID,
                axis: "state", value: "active"), state: initial.statePrecondition, author: .human)
            let afterSuccess = try canonicalJSON(fixture.root)
            let revision = try service.observe().document.revision
            XCTAssertThrowsError(try mutate(service, .unsetComponentVariant(screenID: screenID,
                layerID: plainID, axis: "state"), state: initial.statePrecondition, author: .agent)) { error in
                guard case AuthoringError.staleState = error else { return XCTFail("\(error)") }
            }
            try assertUnchanged(fixture, before: afterSuccess, revision: revision)
        }
    }

    func testWrongKindAndOtherScreenDoNotChangeCanonical() throws {
        try withFixture { fixture in
            let service = ProjectService(repository: fixture.repository)
            let before = try canonicalJSON(fixture.root)
            let state = fixture.observed.statePrecondition
            for (screen, layer) in [(screenID, EntityID("ordinary_text")), (otherScreenID, plainID)] {
                XCTAssertThrowsError(try mutate(service, .setComponentVariant(screenID: screen,
                    layerID: layer, axis: "state", value: "active"), state: state, author: .human))
                try assertUnchanged(fixture, before: before, revision: fixture.observed.document.revision)
            }
        }
    }

    func testDynamicAxisPatchPathIsUnambiguousAndEqualPairsRemainDistinct() throws {
        for (axis, expectedPath) in [
            ("state", "component.variantSelection[\"state\"]"),
            ("a.b", "component.variantSelection[\"a.b\"]"),
            (oddAxis, "component.variantSelection[\"quote\\\"back\\\\slash\"]")
        ] {
            try withFixture { fixture in
                let service = ProjectService(repository: fixture.repository)
                let result = try mutate(service, .setComponentVariant(screenID: screenID,
                    layerID: plainID, axis: axis, value: axis == "state" ? "active" : "on"),
                    state: fixture.observed.statePrecondition, author: .human)
                XCTAssertEqual(result.patches.first?.path, expectedPath)
                XCTAssertEqual(result.patches.count, 1)
            }
        }
        try withFixture(equalityPairs: true) { fixture in
            let service = ProjectService(repository: fixture.repository)
            let left = try mutate(service, .setComponentVariant(screenID: screenID,
                layerID: plainID, axis: "a=b", value: "c"),
                state: fixture.observed.statePrecondition, author: .human)
            let right = try mutate(service, .setComponentVariant(screenID: screenID,
                layerID: plainID, axis: "a", value: "b=c"),
                state: try XCTUnwrap(left.statePrecondition), author: .agent)
            XCTAssertEqual(right.revision, left.revision + 1)
            let reopened = try CanonicalRepository(root: fixture.root).observe()
            XCTAssertEqual(try selected(reopened.document, layerID: plainID).variantSelection,
                ["a=b": "c", "a": "b=c"])
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
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        return CLIResult(status: process.terminationStatus,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self))
    }

    private func variantCLI(_ fixture: Fixture, _ action: String, layer: EntityID, axis: String,
                            value: String? = nil, state: ClientPrecondition) throws -> CLIResult {
        var args = ["component", "variant", action, screenID.rawValue, layer.rawValue,
            axis, "--state", state.rawValue]
        if let value { args.insert(value, at: 6) }
        return try cli(fixture, arguments: args)
    }

    func testCLIJSONSuccessValidationConflictNoopAndSparseReopen() throws {
        try withFixture { fixture in
            let state = fixture.observed.statePrecondition
            let before = try canonicalJSON(fixture.root)
            for (layer, axis, value) in [
                (plainID, "missing", "on"), (plainID, "state", "missing"),
                (conflictID, "state", "active"), (slotID, "state", "active")
            ] {
                let failed = try variantCLI(fixture, "set", layer: layer, axis: axis,
                    value: value, state: state)
                XCTAssertEqual(failed.status, 5, failed.stdout + failed.stderr)
                XCTAssertEqual(failed.json?["ok"] as? Bool, false)
                XCTAssertEqual(failed.json?["category"] as? String, "validation")
                try assertUnchanged(fixture, before: before, revision: fixture.observed.document.revision)
            }
            let success = try variantCLI(fixture, "set", layer: plainID, axis: "state",
                value: "active", state: state)
            XCTAssertEqual(success.status, 0, success.stdout + success.stderr)
            XCTAssertEqual(success.json?["ok"] as? Bool, true)
            let mutation = try XCTUnwrap(success.json?["mutation"] as? [String: Any])
            XCTAssertEqual(mutation["revision"] as? Int, fixture.observed.document.revision + 1)
            let patches = try XCTUnwrap(mutation["patches"] as? [[String: Any]])
            XCTAssertEqual(patches.count, 1)
            XCTAssertEqual(patches.first?["path"] as? String, "component.variantSelection[\"state\"]")
            let currentState = try XCTUnwrap((mutation["statePrecondition"] as? [String: Any])?["rawValue"] as? String)
            let afterSuccess = try canonicalJSON(fixture.root)
            let same = try variantCLI(fixture, "set", layer: plainID, axis: "state",
                value: "active", state: ClientPrecondition(currentState))
            XCTAssertEqual(same.status, 0, same.stdout + same.stderr)
            let sameMutation = try XCTUnwrap(same.json?["mutation"] as? [String: Any])
            XCTAssertEqual(sameMutation["revision"] as? Int, mutation["revision"] as? Int)
            XCTAssertEqual((sameMutation["patches"] as? [Any])?.count, 0)
            XCTAssertEqual((sameMutation["statePrecondition"] as? [String: Any])?["rawValue"] as? String,
                currentState)
            try assertUnchanged(fixture, before: afterSuccess, revision: fixture.observed.document.revision + 1)
            let reopened = try CanonicalRepository(root: fixture.root).observe()
            XCTAssertEqual(try selected(reopened.document, layerID: plainID).variantSelection, ["state": "active"])
            XCTAssertTrue(reopened.document.screens[0].root.children[0].children.isEmpty)

            let stale = try variantCLI(fixture, "unset", layer: plainID, axis: "state", state: state)
            XCTAssertEqual(stale.status, 3, stale.stdout + stale.stderr)
            XCTAssertEqual(stale.json?["ok"] as? Bool, false)
            XCTAssertEqual(stale.json?["category"] as? String, "conflict")
            try assertUnchanged(fixture, before: afterSuccess, revision: fixture.observed.document.revision + 1)
        }
    }

    func testCLIDelimiterPreservesLiteralDashJsonAndOptionLikeAxes() throws {
        try withFixture { fixture in
            var state = fixture.observed.statePrecondition
            func update(_ result: CLIResult) throws {
                XCTAssertEqual(result.status, 0, result.stdout + result.stderr)
                XCTAssertEqual(result.json?["ok"] as? Bool, true)
                let mutation = try XCTUnwrap(result.json?["mutation"] as? [String: Any])
                state = ClientPrecondition(try XCTUnwrap(
                    (mutation["statePrecondition"] as? [String: Any])?["rawValue"] as? String))
            }
            try update(variantCLI(fixture, "set", layer: plainID, axis: "literal", value: "-", state: state))
            XCTAssertEqual(try selected(fixture.repository.observe().document, layerID: plainID)
                .variantSelection["literal"], "-")
            let jsonValue = try cli(fixture, arguments: ["component", "variant", "set",
                screenID.rawValue, plainID.rawValue, "literal", "--state", state.rawValue,
                "--", "--json"])
            try update(jsonValue)
            XCTAssertEqual(try selected(fixture.repository.observe().document, layerID: plainID)
                .variantSelection["literal"], "--json")

            let plainOutput = try cli(fixture, arguments: ["component", "variant", "set",
                screenID.rawValue, plainID.rawValue, "literal", "--state", state.rawValue,
                "--", "--json"], json: false)
            XCTAssertEqual(plainOutput.status, 0, plainOutput.stdout + plainOutput.stderr)
            XCTAssertNil(plainOutput.json, "Literal --json must not switch on JSON output")
            XCTAssertTrue(plainOutput.stdout.hasPrefix("revision "), plainOutput.stdout)

            try update(variantCLI(fixture, "unset", layer: plainID, axis: "literal", state: state))
            let axisJson = try cli(fixture, arguments: ["component", "variant", "set",
                screenID.rawValue, plainID.rawValue, "--state", state.rawValue,
                "--", "--json", "on"])
            try update(axisJson)
            XCTAssertEqual(try selected(fixture.repository.observe().document, layerID: plainID)
                .variantSelection["--json"], "on")
            let unsetAxisJson = try cli(fixture, arguments: ["component", "variant", "unset",
                screenID.rawValue, plainID.rawValue, "--state", state.rawValue,
                "--", "--json"])
            try update(unsetAxisJson)

            let axisState = try cli(fixture, arguments: ["component", "variant", "set",
                screenID.rawValue, plainID.rawValue, "--state", state.rawValue,
                "--", "--state", "on"])
            try update(axisState)
            XCTAssertEqual(try selected(fixture.repository.observe().document, layerID: plainID)
                .variantSelection["--state"], "on")
            let unsetAxisState = try cli(fixture, arguments: ["component", "variant", "unset",
                screenID.rawValue, plainID.rawValue, "--state", state.rawValue,
                "--", "--state"])
            try update(unsetAxisState)

            try update(variantCLI(fixture, "set", layer: plainID, axis: "a.b", value: "on", state: state))
            XCTAssertEqual(try selected(fixture.repository.observe().document, layerID: plainID)
                .variantSelection["a.b"], "on")
        }
    }

    func testExistingPageCommandKeepsDoubleDashAsLiteralName() throws {
        try withFixture { fixture in
            let result = try cli(fixture, arguments: ["page", "create", "--", "--state",
                fixture.observed.statePrecondition.rawValue])
            XCTAssertEqual(result.status, 0, result.stdout + result.stderr)
            XCTAssertEqual(result.json?["ok"] as? Bool, true)
            let reopened = try CanonicalRepository(root: fixture.root).observe()
            XCTAssertEqual(reopened.document.pages.map(\.name), ["--"])
            XCTAssertEqual(reopened.document.revision, fixture.observed.document.revision + 1)
        }
    }
}
