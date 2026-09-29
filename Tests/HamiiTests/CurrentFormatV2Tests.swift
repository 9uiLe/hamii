import Foundation
import XCTest
import HamiiCore
import HamiiApplication
import HamiiFormat
import HamiiGeneration
import HamiiMigrations

final class CurrentFormatV2Tests: XCTestCase {
    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        var bytes = try encoder.encode(value)
        bytes.append(0x0A)
        return bytes
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testStarterUsesExactCurrentBytesAndLoadsAsCurrentDocument() throws {
        let root = repositoryRoot.appendingPathComponent("Samples/Starter")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("hamii.json"))) as! [String: Any]
        XCTAssertEqual(manifest["formatVersion"] as? Int, 2)
        XCTAssertEqual((manifest["versions"] as? [String: Any])?["document"] as? Int, 2)
        let screenFolder = root.appendingPathComponent("screens")
        let files = try FileManager.default.contentsOfDirectory(at: screenFolder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let source = try Data(contentsOf: file)
            let screen = try JSONDecoder().decode(Screen.self, from: source)
            XCTAssertEqual(try encoded(screen), source)
            XCTAssertEqual(screen.root.effects, [.padding(tokenID: EntityID("token_8af3340c-ee6e-4a55-b230-0dcfb0ecaac0"))])
            XCTAssertTrue(screen.root.children.allSatisfy { $0.effects.isEmpty })
        }
        let document = try CanonicalRepository(root: root).load()
        XCTAssertEqual(document.versions.document, 2)
        XCTAssertEqual(try MigrationPreflight.plan(repository: root).state, "current")
    }

    func testOrderedEffectsRoundTripAcrossScreenComponentAndSlot() throws {
        let first = EntityID("token_first")
        let second = EntityID("token_second")
        let leaf = Layer(id: EntityID("leaf"), name: "Leaf", payload: .text(TextLayerPayload(value: "Text")), effects: [.padding(tokenID: first), .padding(tokenID: second)])
        let slot = Layer(id: EntityID("slot"), name: "Slot", payload: .componentInstance(ComponentInstanceLayerPayload(instance:
            ComponentInstance(definitionID: EntityID("definition"), slotContent: ["content": [leaf]]))))
        let root = Layer(id: EntityID("root"), name: "Root", payload: .stack, children: [slot], effects: [.padding(tokenID: second), .padding(tokenID: first)])
        let screen = Screen(id: EntityID("screen"), name: "Screen", scopeID: EntityID("scope"), root: root)
        let definition = ComponentDefinition(id: EntityID("definition"), name: "Definition", ownerScopeID: EntityID("scope"), root: root)
        for bytes in [try encoded(screen), try encoded(definition)] {
            let json = String(decoding: bytes, as: UTF8.self)
            XCTAssertFalse(json.contains("paddingTokenID"))
            XCTAssertTrue(json.contains("\"effects\""))
        }
        XCTAssertEqual(try encoded(JSONDecoder().decode(Screen.self, from: encoded(screen))), try encoded(screen))
        XCTAssertEqual(try encoded(JSONDecoder().decode(ComponentDefinition.self, from: encoded(definition))), try encoded(definition))
        XCTAssertEqual(try JSONDecoder().decode(Screen.self, from: encoded(screen)).root.effects, root.effects)
        XCTAssertNotEqual(try encoded(root), try encoded(Layer(id: root.id, name: root.name, payload: .stack, children: root.children, effects: root.effects.reversed())))
    }

    func testUnknownEffectAndLegacyLayoutPaddingFailDecoding() throws {
        let layer = Layer(id: EntityID("layer"), name: "Text", payload: .text(TextLayerPayload(value: "Text")))
        var object = try JSONSerialization.jsonObject(with: encoded(layer)) as! [String: Any]
        object["effects"] = [["kind": "unimplemented", "tokenID": ["rawValue": "token"]]]
        XCTAssertThrowsError(try JSONDecoder().decode(Layer.self, from: JSONSerialization.data(withJSONObject: object)))
        object["effects"] = []
        object["layout"] = ["paddingTokenID": ["rawValue": "token"]]
        XCTAssertThrowsError(try JSONDecoder().decode(Layer.self, from: JSONSerialization.data(withJSONObject: object)))
        object["layout"] = [:]
        object["assetID"] = ["rawValue": "cross_kind"]
        XCTAssertThrowsError(try JSONDecoder().decode(Layer.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testV1AndMixedMarkersRejectWithoutChangingCanonicalBytes() throws {
        let sample = repositoryRoot.appendingPathComponent("Samples/Starter")
        for (format, documentVersion) in [(1, 1), (1, 2), (2, 1)] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.copyItem(at: sample, to: root)
            let manifestURL = root.appendingPathComponent("hamii.json")
            var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
            manifest["formatVersion"] = format
            var versions = manifest["versions"] as! [String: Any]
            versions["document"] = documentVersion
            manifest["versions"] = versions
            let bytes = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            try bytes.write(to: manifestURL)
            let repository = CanonicalRepository(root: root)
            XCTAssertThrowsError(try repository.load(), "\(format)/\(documentVersion)")
            XCTAssertThrowsError(try ProjectService(repository: repository).observe())
            if format == documentVersion {
                let plan = try MigrationPreflight.plan(repository: root)
                XCTAssertEqual(plan.state, "noMigrationEdge")
            } else {
                XCTAssertThrowsError(try MigrationPreflight.plan(repository: root))
            }
            XCTAssertEqual(try Data(contentsOf: manifestURL), bytes)
        }
    }

    func testPaddingRequiresExactDeclarationAndGeneratorRejectsIt() throws {
        var document = Document(name: "Effects")
        let target = Target(id: EntityID("target"), platform: .macOS, framework: .swiftUI)
        let token = EntityID("spacing")
        document.tokens = [DesignToken(id: token, name: "Spacing", kind: .spacing, ownerScopeID: document.scopes[0].id, value: .literal("12"))]
        document.targets = [target]
        let root = Layer(id: EntityID("root"), name: "Root", payload: .text(TextLayerPayload(value: "Text")), effects: [.padding(tokenID: token)])
        let screen = Screen(id: EntityID("screen"), name: "Screen", scopeID: document.scopes[0].id, root: root)
        document.screens = [screen]
        document.capabilityDeclarations = [
            CapabilityDeclaration(targetID: target.id, key: CapabilityKeys.legacyText, support: .exact),
            CapabilityDeclaration(targetID: target.id, key: CapabilityKeys.legacySpacing, support: .exact)
        ]
        let requirement = SemanticRequirementExtractor.extract(screen: screen, document: document).requirements
        XCTAssertTrue(requirement.contains { $0.key == .init("effect.padding") })
        let missing = CapabilityEvaluator.evaluate(requirements: requirement, profile: CapabilityProfile(target: target),
            declarations: document.capabilityDeclarations, catalog: NativePreviewCapabilityCatalog.catalog)
        XCTAssertFalse(missing.allowed)
        document.capabilityDeclarations.append(CapabilityDeclaration(targetID: target.id, key: .init("effect.padding"), support: .exact))
        let preview = CapabilityEvaluator.evaluate(requirements: requirement, profile: CapabilityProfile(target: target),
            declarations: document.capabilityDeclarations, catalog: NativePreviewCapabilityCatalog.catalog)
        XCTAssertTrue(preview.allowed)
        XCTAssertThrowsError(try SwiftUIGenerator.generate(document: document, screenID: screen.id, targetID: target.id))
    }

    func testNewProjectReopensAsV2AndNoOpKeepsGeneration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CanonicalRepository(root: root)
        let created = try repository.create(name: "Current")
        XCTAssertEqual(created.versions.document, 2)
        var document = created
        let text = Layer(id: EntityID("text"), name: "Text", payload: .text(TextLayerPayload(value: "Same")))
        document.screens = [Screen(id: EntityID("screen"), name: "Screen", scopeID: document.scopes[0].id, root: text)]
        document.revision += 1
        try repository.save(document, expected: created)
        XCTAssertEqual(try CanonicalRepository(root: root).load(), document)
        let service = ProjectService(repository: repository)
        let observed = try service.observe()
        let before = try CanonicalGenerationStore(root: root).readStable()
        let result = try service.mutate(.setText(screenID: EntityID("screen"), layerID: text.id, text: "Same"),
                                        expectedState: observed.statePrecondition, author: .human)
        XCTAssertTrue(result.patches.isEmpty)
        XCTAssertEqual(result.statePrecondition, observed.statePrecondition)
        XCTAssertEqual(try CanonicalGenerationStore(root: root).readStable(), before)
    }

    func testPaddingSetterRejectsAmbiguousOrderedSequence() throws {
        var document = Document(name: "Ordered")
        let token = EntityID("token")
        let layer = Layer(id: EntityID("layer"), name: "Text", payload: .text(TextLayerPayload(value: "Text")),
                          effects: [.padding(tokenID: token), .padding(tokenID: token)])
        let screen = Screen(id: EntityID("screen"), name: "Screen", scopeID: document.scopes[0].id, root: layer)
        document.screens = [screen]
        XCTAssertThrowsError(try MutationEngine.apply(.setLayoutToken(screenID: screen.id, layerID: layer.id,
            property: .padding, tokenID: token), to: document, expectedRevision: 0, author: .human)) { error in
            guard case AuthoringError.validation(let diagnostics) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(diagnostics.map(\.rule), ["effect.ambiguousPadding"])
        }
    }
}
