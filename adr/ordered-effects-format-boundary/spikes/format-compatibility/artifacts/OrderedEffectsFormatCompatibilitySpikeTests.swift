import Foundation
import XCTest
import HamiiCore
import HamiiApplication
import HamiiFormat
import HamiiGeneration
import HamiiMigrations

/// The production modules imported here are the current-v1 reader/writer from baseline 878cf929.
/// This file contains only test candidates; no ordered-effect model is installed in production.
final class OrderedEffectsFormatCompatibilitySpikeTests: XCTestCase {
    private let target = Target(id: EntityID("target_swiftui"), platform: .macOS, framework: .swiftUI)
    private let screenID = EntityID("screen_probe")
    private let textID = EntityID("layer_text")

    private func project() throws -> (URL, CanonicalRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = CanonicalRepository(root: root)
        let initial = try repository.create(name: "Format compatibility")
        var document = initial
        document.revision = 1
        document.targets = [target]
        document.capabilityDeclarations = [
            CapabilityDeclaration(targetID: target.id, key: CapabilityKeys.legacyText, support: .exact)
        ]
        document.screens = [Screen(id: screenID, name: "Probe", scopeID: document.scopes[0].id,
                                   root: Layer(id: textID, name: "Title", payload: .text(TextLayerPayload(value: "Original"))))]
        try repository.save(document, expected: initial)
        return (root, repository)
    }

    private func modifyJSON(_ url: URL, _ change: (inout [String: Any]) -> Void) throws -> Data {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        change(&json)
        let bytes = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) + Data([0x0A])
        try bytes.write(to: url)
        return bytes
    }

    private func surface(scopeID: EntityID) -> AppSurface {
        AppSurface(id: EntityID("surface_probe"), targetID: target.id, device: "Mac", runtime: "macOS 27",
                   buildEnvironment: "SDK", screenID: screenID, architectureScopeID: scopeID)
    }

    func testV1UnknownEffectIsReadButSilentlyOmittedByLegacyConsumersAndWriteFailsClosed() throws {
        let (root, repository) = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ProjectService(repository: repository)
        let baseline = try service.observe()
        let baselineSource = try SwiftUIGenerator.generate(document: baseline.document, screenID: screenID, targetID: target.id).source
        let screenURL = root.appendingPathComponent("screens/\(screenID.rawValue).json")
        let effectBytes = try modifyJSON(screenURL) { json in
            var node = json["root"] as! [String: Any]
            node["effects"] = [
                ["kind": "padding", "tokenID": "token_pad"],
                ["kind": "background", "tokenID": "token_bg"]
            ]
            json["root"] = node
        }
        let manifestURL = root.appendingPathComponent("hamii.json")
        let manifestBytes = try Data(contentsOf: manifestURL)

        let loaded = try repository.load()
        let observed = try service.observe()
        XCTAssertEqual(loaded, observed.document)
        XCTAssertEqual(loaded.versions.document, 1)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(loaded.screens[0].root), as: UTF8.self).contains("effects"))
        XCTAssertTrue(TargetPlanner.plan(surface: surface(scopeID: loaded.scopes[0].id), document: loaded).canPreview)
        XCTAssertEqual(try SwiftUIGenerator.generate(document: loaded, screenID: screenID, targetID: target.id).source, baselineSource)
        let preflight = try MigrationPreflight.plan(repository: root)
        XCTAssertEqual(preflight.sourceDocumentFormatVersion, 1)
        XCTAssertEqual(preflight.state, "current")

        XCTAssertThrowsError(try service.mutate(.setText(screenID: screenID, layerID: textID, text: "Changed"),
                                                 expectedState: observed.statePrecondition, author: .human)) { error in
            guard case CanonicalError.transactionConflict(let path) = error else {
                return XCTFail("Expected exact-byte conflict, got \(error)")
            }
            XCTAssertEqual(path, "screens/\(self.screenID.rawValue).json")
        }
        XCTAssertEqual(try Data(contentsOf: screenURL), effectBytes)
        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBytes)
    }

    func testVersionMarkerMatrixExposesMixedPreflightMismatchAndV2Gate() throws {
        for (format, documentVersion, expectedPreflight) in [(1, 2, "current"), (2, 2, "noMigrationEdge"), (2, 1, "noMigrationEdge")] {
            let (root, repository) = try project()
            defer { try? FileManager.default.removeItem(at: root) }
            let manifestURL = root.appendingPathComponent("hamii.json")
            let markedBytes = try modifyJSON(manifestURL) { json in
                json["formatVersion"] = format
                var versions = json["versions"] as! [String: Any]
                versions["document"] = documentVersion
                json["versions"] = versions
            }
            let screenURL = root.appendingPathComponent("screens/\(screenID.rawValue).json")
            let originalScreenBytes = try Data(contentsOf: screenURL)

            XCTAssertThrowsError(try repository.load(), "\(format)/\(documentVersion)") { error in
                guard case CanonicalError.unsupportedFormat = error else {
                    return XCTFail("Expected unsupportedFormat, got \(error)")
                }
            }
            XCTAssertThrowsError(try repository.observe())
            XCTAssertThrowsError(try ProjectService(repository: repository).mutate(
                .setText(screenID: screenID, layerID: textID, text: "Changed"),
                expectedState: ClientPrecondition("old"), author: .human))
            let plan = try MigrationPreflight.plan(repository: root)
            XCTAssertEqual(plan.sourceDocumentFormatVersion, format)
            XCTAssertEqual(plan.state, expectedPreflight, "\(format)/\(documentVersion)")
            XCTAssertEqual(try Data(contentsOf: manifestURL), markedBytes)
            XCTAssertEqual(try Data(contentsOf: screenURL), originalScreenBytes)
        }
    }

    private enum EffectKind: String, Codable { case padding, background }
    private struct OrderedEffect: Codable, Equatable {
        var kind: EffectKind
        var tokenID: EntityID
    }
    private struct CandidateNode: Codable, Equatable {
        var base: Layer
        var effects: [OrderedEffect]
        var children: [CandidateNode]

        init(v1 layer: Layer) {
            effects = layer.layout.paddingTokenID.map { [OrderedEffect(kind: .padding, tokenID: $0)] } ?? []
            children = layer.children.map(CandidateNode.init(v1:))
            base = layer
            base.layout.paddingTokenID = nil
            base.children = []
        }
        func restoredV1() -> Layer {
            var layer = base
            layer.layout.paddingTokenID = effects.first { $0.kind == .padding }?.tokenID
            layer.children = children.map { $0.restoredV1() }
            return layer
        }
        var requirements: [SemanticRequirement] {
            var result = effects.map {
                SemanticRequirement(key: CapabilityKey("effect.\($0.kind.rawValue)"), sourceEntityID: base.id)
            }
            if effects.count > 1 { result.append(SemanticRequirement(key: CapabilityKey("effect.order"), sourceEntityID: base.id)) }
            return result + children.flatMap(\.requirements)
        }
    }

    func testCandidateOrderRoundTripAndV1PaddingTransformation() throws {
        let text = Layer(id: EntityID("nested_text"), name: "Nested", payload: .text(TextLayerPayload(value: "Text")),
                         layout: Layout(paddingTokenID: EntityID("token_nested")))
        let root = Layer(id: EntityID("root"), name: "Root", payload: .stack, children: [text],
                         layout: Layout(paddingTokenID: EntityID("token_root")))
        let noPadding = Layer(id: EntityID("plain"), name: "Plain", payload: .text(TextLayerPayload(value: "Plain")))
        let componentRoot = Layer(id: EntityID("component_root"), name: "Component", payload: .overlay, children: [text])
        let definition = ComponentDefinition(id: EntityID("component_probe"), name: "Probe", ownerScopeID: EntityID("scope_app"), root: componentRoot)
        let instance = Layer(id: EntityID("component_instance"), name: "Instance", payload: .componentInstance(
            ComponentInstanceLayerPayload(instance: ComponentInstance(definitionID: definition.id))))
        for layer in [noPadding, root, componentRoot] {
            let candidate = CandidateNode(v1: layer)
            let decoded = try JSONDecoder().decode(CandidateNode.self, from: JSONEncoder().encode(candidate))
            XCTAssertEqual(decoded, candidate)
            XCTAssertEqual(decoded.restoredV1(), layer)
        }
        XCTAssertEqual(CandidateNode(v1: noPadding).effects, [])
        XCTAssertEqual(CandidateNode(v1: root).effects.map(\.kind), [.padding])
        let candidateDefinition = CandidateNode(v1: definition.root)
        let candidateInstance = CandidateNode(v1: instance)
        XCTAssertEqual(candidateDefinition.children[0].effects.map(\.kind), [.padding])
        XCTAssertEqual(candidateDefinition.restoredV1(), definition.root)
        XCTAssertEqual(candidateInstance.restoredV1(), instance)
        XCTAssertEqual(candidateInstance.base.component?.definitionID, definition.id)

        var candidate = CandidateNode(v1: root)
        candidate.effects.append(OrderedEffect(kind: .background, tokenID: EntityID("token_bg")))
        var reversed = candidate
        reversed.effects.reverse()
        XCTAssertNotEqual(candidate, reversed)
        XCTAssertNotEqual(try JSONEncoder().encode(candidate), try JSONEncoder().encode(reversed))
        XCTAssertEqual(try JSONDecoder().decode(CandidateNode.self, from: JSONEncoder().encode(candidate)), candidate)

        let requirements = candidate.requirements
        XCTAssertEqual(requirements.map(\.key.rawValue), ["effect.padding", "effect.background", "effect.order", "effect.padding"])
        let declarations = requirements.map { CapabilityDeclaration(targetID: target.id, key: $0.key, support: .exact) }
        let report = CapabilityEvaluator.evaluate(requirements: requirements, profile: CapabilityProfile(target: target),
                                                  declarations: declarations, catalog: CapabilityCatalog(supportedKeys: []))
        XCTAssertFalse(report.allowed)
        XCTAssertTrue(report.items.allSatisfy { $0.support == .unsupported })
    }

    func testGenericFieldsDoNotProvideTypedEffectSemantics() {
        var layer = Layer(id: textID, name: "Text", payload: .text(TextLayerPayload(value: "Hello")))
        layer.nativeIntent = "padding(token_pad),background(token_bg)"
        layer.targetOverrides = ["swiftUI": "background(token_bg),padding(token_pad)"]
        var document = Document(name: "Generic bag")
        document.targets = [target]
        document.screens = [Screen(id: screenID, name: "Probe", scopeID: document.scopes[0].id, root: layer)]
        XCTAssertEqual(DocumentValidator.validate(document), [])
        let keys = SemanticRequirementExtractor.extract(screen: document.screens[0], document: document).requirements.map(\.key)
        XCTAssertEqual(keys, [CapabilityKeys.textVisual, CapabilityKeys.nativeIntent, CapabilityKeys.targetOverride])
        XCTAssertFalse(keys.contains(CapabilityKey("effect.order")))
    }
}
