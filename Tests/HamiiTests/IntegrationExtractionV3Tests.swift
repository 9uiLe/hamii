import Foundation
import XCTest
import HamiiCore
import HamiiIntegration

final class IntegrationExtractionV3Tests: XCTestCase {
    private func document(withSemantics: Bool) -> Document {
        var result = Document(name: "Profile")
        result.id = EntityID("document_profile")
        result.scopes = [ArchitectureScope(id: EntityID("scope_app"), name: "App", parentID: nil)]
        var name = Layer(id: EntityID("layer_name"), kind: .text, name: "Name", text: "Preview")
        var screen = Screen(id: EntityID("screen_profile"), name: "Profile", scopeID: EntityID("scope_app"),
                            root: Layer(id: EntityID("layer_root"), kind: .stack, name: "Root", children: [name]))
        if withSemantics {
            result.versions.document = 3
            name.textBinding = "profile.name"
            screen.root.children[0] = name
            screen.semantics = ScreenSemantics(
                sources: [HamiiCore.SemanticSource(key: HamiiCore.SemanticSourceKey("profile.name"), valueKind: .text)],
                outputs: [HamiiCore.SemanticOutput(key: HamiiCore.SemanticOutputKey("profileName"),
                    anchor: .direct(layerID: name.id, property: .text), binding: "profile.name")],
                relations: [HamiiCore.SemanticRelation(output: HamiiCore.SemanticOutputKey("profileName"),
                    source: HamiiCore.SemanticSourceKey("profile.name"), whenNil: .literal("Guest"))])
        }
        result.screens = [screen]
        return result
    }

    func testValidV3ScreenSemanticsReachIntegrationContract() throws {
        let document = document(withSemantics: true)
        XCTAssertFalse(DocumentValidator.validate(document).contains { $0.severity == .error })
        let contract = try IntegrationContracts.make(screenID: EntityID("screen_profile"), document: document)
        XCTAssertEqual(contract.semanticSources, document.screens[0].semantics?.sources)
        XCTAssertEqual(contract.relations, document.screens[0].semantics?.relations)
        XCTAssertEqual(contract.inputs, ["profile.name"])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(contract)) as? [String: Any]
        XCTAssertNotNil(json?["semanticSources"])
        XCTAssertNotNil(json?["relations"])
    }

    func testV2ContractAndScreenJSONDoNotGainEmptySemanticsKeys() throws {
        let document = document(withSemantics: false)
        let contract = try IntegrationContracts.make(screenID: EntityID("screen_profile"), document: document)
        XCTAssertNil(contract.semanticSources)
        XCTAssertNil(contract.relations)
        let contractJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(contract)) as? [String: Any])
        XCTAssertFalse(contractJSON.keys.contains("semanticSources"))
        XCTAssertFalse(contractJSON.keys.contains("relations"))
        let screenJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(document.screens[0])) as? [String: Any])
        XCTAssertFalse(screenJSON.keys.contains("semantics"))
    }

    func testExtractionRejectsInvalidRelationBeforePublishingContract() {
        var document = document(withSemantics: true)
        guard var semantics = document.screens[0].semantics else { return XCTFail("Missing semantics fixture") }
        semantics.relations[0].output = HamiiCore.SemanticOutputKey("missingOutput")
        document.screens[0].semantics = semantics
        XCTAssertThrowsError(try IntegrationContracts.make(screenID: EntityID("screen_profile"),
                                                            document: document)) { error in
            guard case ContractError.invalidDocument(let diagnostics) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(diagnostics.contains { $0.severity == .error })
        }
    }
}
