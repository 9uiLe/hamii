import Foundation
import XCTest
import HamiiCore
@testable import HamiiFormat

// Copy into Tests/HamiiTests to reproduce the current same-revision save gap.
final class SequentialExternalEditProbe: XCTestCase {
    func testExternalEditBetweenLoadAndSaveIsOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CanonicalRepository(root: root)
        var base = try repository.create(name: "External edit probe")
        let owner = try XCTUnwrap(base.scopes.first?.id)
        let componentID = EntityID("component_probe")
        base.components = [ComponentDefinition(
            id: componentID,
            name: "BaseButton",
            ownerScopeID: owner,
            root: Layer(id: EntityID("layer_probe"), kind: .stack, name: "Root")
        )]
        base.revision = 1
        try repository.save(base, expectedRevision: 0)

        let loadedBeforeExternalEdit = try repository.load()
        let componentFile = root.appendingPathComponent("components/component_probe.json")
        let externalBytes = try XCTUnwrap(
            String(data: Data(contentsOf: componentFile), encoding: .utf8)?
                .replacingOccurrences(of: "BaseButton", with: "ExternalButton")
                .data(using: .utf8)
        )
        try externalBytes.write(to: componentFile)

        var intendedSave = loadedBeforeExternalEdit
        intendedSave.components[0].name = "HamiiButton"
        intendedSave.revision = 2
        try repository.save(intendedSave, expectedRevision: 1)

        let finalBytes = try Data(contentsOf: componentFile)
        XCTAssertNotEqual(finalBytes, externalBytes)
        XCTAssertEqual(try repository.load().components[0].name, "HamiiButton")
    }
}
