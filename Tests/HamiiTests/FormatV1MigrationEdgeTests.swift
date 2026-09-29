import Foundation
import XCTest
import HamiiCore
import HamiiApplication
import HamiiFormat
@testable import HamiiIndex
import HamiiGeneration
import HamiiMigrations

final class FormatV1MigrationEdgeTests: XCTestCase {
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures")
    }

    private func sourceFiles() throws -> [String: Data] {
        let root = fixtures.appendingPathComponent("format-v1-safe-project")
        var files: [String: Data] = [:]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where !url.hasDirectoryPath {
            files[String(url.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: url)
        }
        return files
    }

    private func materialize(_ files: [String: Data], at root: URL) throws {
        for (path, bytes) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
    }

    private func canonicalBytes<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        var bytes = try encoder.encode(value)
        bytes.append(0x0A)
        return bytes
    }

    private struct FixedRevision: CanonicalRevisionCalculating {
        func current(at root: URL) throws -> CanonicalRevision { CanonicalRevision("migration-test") }
    }

    func testProductionEdgeBuildsCurrentCandidateAndPreservesUnchangedBytes() throws {
        let source = try sourceFiles()
        let original = source
        let analysis = try MigrationRegistry.analyze(MigrationFileSet(files: source))
        XCTAssertEqual(analysis.classification, .losslessWithNormalization)
        XCTAssertTrue(analysis.automaticCandidateEligible)
        let planRoot = fixtures.appendingPathComponent("format-v1-safe-project")
        let plan = try MigrationPreflight.plan(repository: planRoot)
        XCTAssertEqual(plan.state, "migrationAvailable")
        XCTAssertTrue(plan.notes.contains { $0.contains("not yet available") })
        let candidate = try MigrationRegistry.transform(MigrationFileSet(files: source))
        XCTAssertEqual(candidate.edgePath, ["1->2"])
        XCTAssertEqual(source, original)
        XCTAssertEqual(candidate.files.files.keys.sorted(), source.keys.sorted())
        for _ in 0..<3 {
            XCTAssertEqual(try MigrationRegistry.transform(MigrationFileSet(files: source)).files.files, candidate.files.files)
        }
        for (path, bytes) in source where path != "hamii.json" && !path.hasPrefix("screens/") && !path.hasPrefix("components/") {
            XCTAssertEqual(candidate.files.files[path], bytes, path)
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try materialize(candidate.files.files, at: root)
        let repository = CanonicalRepository(root: root)
        let document = try repository.load()
        XCTAssertEqual(document.versions.document, 2)
        XCTAssertEqual(document.revision, 1)
        XCTAssertEqual(document.pages.count, 1)
        XCTAssertEqual(document.screens.count, 1)
        XCTAssertEqual(document.components.count, 2)
        XCTAssertEqual(document.tokens.count, 1)
        XCTAssertEqual(document.assets.count, 1)
        XCTAssertTrue(DocumentValidator.validate(document).isEmpty)
        let declarations = document.capabilityDeclarations
        XCTAssertEqual(declarations.count, 3)
        let spacing = try XCTUnwrap(declarations.first { $0.key.rawValue == "token.spacing" })
        let padding = try XCTUnwrap(declarations.first { $0.key.rawValue == "effect.padding" })
        XCTAssertEqual(padding.targetID, spacing.targetID)
        XCTAssertEqual(padding.support, spacing.support)
        XCTAssertEqual(padding.reason, spacing.reason)
        let screen = try XCTUnwrap(document.screens.first)
        XCTAssertEqual(screen.root.layout.spacingTokenID, EntityID("token_space"))
        XCTAssertEqual(screen.root.effects, [.padding(tokenID: EntityID("token_space"))])
        XCTAssertEqual(screen.root.children[0].children[0].effects.count, 1)
        XCTAssertEqual(screen.root.children[2].component?.slotContent["content"]?.first?.effects.count, 1)
        XCTAssertEqual(document.components.first { $0.id == EntityID("component_badge") }?.root.effects.count, 1)

        let manifest = try JSONDecoder().decode(DocumentManifestProbe.self, from: XCTUnwrap(candidate.files.files["hamii.json"]))
        XCTAssertEqual(candidate.files.files["hamii.json"], try canonicalBytes(manifest))
        for (path, bytes) in candidate.files.files where path.hasPrefix("screens/") || path.hasPrefix("components/") {
            if path.hasPrefix("screens/") { XCTAssertEqual(bytes, try canonicalBytes(JSONDecoder().decode(Screen.self, from: bytes)), path) }
            if path.hasPrefix("components/") { XCTAssertEqual(bytes, try canonicalBytes(JSONDecoder().decode(ComponentDefinition.self, from: bytes)), path) }
        }
        let snapshot = try repository.withCoordinatedSnapshot { $0 }
        let index = try LocalIndex(projectRoot: root, documentID: document.id, revisionCalculator: FixedRevision(),
                                   storageRoot: root.appendingPathComponent("derived-indexes"))
        _ = try index.rebuild(from: snapshot, canonicalRevision: CanonicalRevision("migration-test"))
        XCTAssertEqual(try index.components(matching: "Badge", consumerScopeID: EntityID("scope_app"),
            documentID: document.id, revision: document.revision, expectedSourceIdentity: snapshot.identity).count, 1)
        XCTAssertThrowsError(try SwiftUIGenerator.generate(document: document, screenID: screen.id,
            targetID: EntityID("target_ios")))
        let service = ProjectService(repository: repository)
        let observed = try service.observe()
        _ = try service.mutate(.setText(screenID: screen.id, layerID: EntityID("layer_title"), text: "Updated"),
                               expectedState: observed.statePrecondition, author: .human)
    }

    func testManualBlockersAndNoPathKeepSourceBytes() throws {
        var source = try sourceFiles()
        let originalScreen = try XCTUnwrap(source["screens/screen_main.json"])
        var screen = try XCTUnwrap(JSONSerialization.jsonObject(with: originalScreen) as? [String: Any])
        var root = try XCTUnwrap(screen["root"] as? [String: Any])
        var children = try XCTUnwrap(root["children"] as? [[String: Any]])
        var scroll = children[0]
        var grandchildren = try XCTUnwrap(scroll["children"] as? [[String: Any]])
        grandchildren[0]["assetID"] = ["rawValue": "asset_symbol"]
        scroll["children"] = grandchildren
        children[0] = scroll
        root["children"] = children
        screen["root"] = root
        source["screens/screen_main.json"] = try JSONSerialization.data(withJSONObject: screen)
        let analysis = try MigrationRegistry.analyze(MigrationFileSet(files: source))
        XCTAssertEqual(analysis.classification, .manual)
        XCTAssertTrue(analysis.diagnostics.contains { $0.code == "layer.crossKindResidual" && $0.entityID == "layer_title" })
        XCTAssertThrowsError(try MigrationRegistry.transform(MigrationFileSet(files: source)))
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        try materialize(source, at: temp)
        let plan = try MigrationPreflight.plan(repository: temp)
        XCTAssertEqual(plan.state, "requiresResolution")
        XCTAssertTrue(plan.blockers.contains { $0.contains("layer_title") })
        XCTAssertEqual(try Data(contentsOf: temp.appendingPathComponent("screens/screen_main.json")), source["screens/screen_main.json"])

        var unknown = try sourceFiles()
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(unknown["hamii.json"])) as? [String: Any])
        manifest["formatVersion"] = 3
        var versions = try XCTUnwrap(manifest["versions"] as? [String: Any])
        versions["document"] = 3
        manifest["versions"] = versions
        unknown["hamii.json"] = try JSONSerialization.data(withJSONObject: manifest)
        XCTAssertThrowsError(try MigrationRegistry.transform(MigrationFileSet(files: unknown)))
        XCTAssertThrowsError(try MigrationRegistry.transform(MigrationFileSet(files: try sourceFiles()), to: 0))
    }

    func testVersionMarkersNoOpAndUnchangedBlobAreExplicit() throws {
        var source = try sourceFiles()
        source["assets/blobs/sha256/example"] = Data([0, 1, 2, 255])
        let candidate = try MigrationRegistry.transform(MigrationFileSet(files: source))
        XCTAssertEqual(candidate.files.files["assets/blobs/sha256/example"], source["assets/blobs/sha256/example"])
        let current = try MigrationRegistry.transform(candidate.files)
        XCTAssertEqual(current.edgePath, [])
        XCTAssertEqual(current.files.files, candidate.files.files)
        var mixed = source
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(mixed["hamii.json"])) as? [String: Any])
        manifest["formatVersion"] = 2
        mixed["hamii.json"] = try JSONSerialization.data(withJSONObject: manifest)
        XCTAssertThrowsError(try MigrationRegistry.analyze(MigrationFileSet(files: mixed)))

        var noPadding = try sourceFiles()
        for path in noPadding.keys where path.hasPrefix("screens/") || path.hasPrefix("components/") {
            var entity = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(noPadding[path])) as? [String: Any])
            func strip(_ value: [String: Any]) -> [String: Any] {
                var layer = value
                var layout = layer["layout"] as? [String: Any] ?? [:]
                layout.removeValue(forKey: "paddingTokenID")
                layer["layout"] = layout
                layer["children"] = (layer["children"] as? [[String: Any]] ?? []).map(strip)
                if var component = layer["component"] as? [String: Any], var slots = component["slotContent"] as? [String: [[String: Any]]] {
                    for key in slots.keys { slots[key] = slots[key]?.map(strip) }
                    component["slotContent"] = slots
                    layer["component"] = component
                }
                return layer
            }
            entity["root"] = strip(try XCTUnwrap(entity["root"] as? [String: Any]))
            noPadding[path] = try JSONSerialization.data(withJSONObject: entity)
        }
        let result = try MigrationRegistry.transform(MigrationFileSet(files: noPadding))
        let resultManifest = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(result.files.files["hamii.json"])) as? [String: Any])
        let declarations = try XCTUnwrap(resultManifest["capabilityDeclarations"] as? [[String: Any]])
        XCTAssertFalse(declarations.contains { (($0["key"] as? [String: Any])?["rawValue"] as? String) == "effect.padding" })
    }

    func testHistoricalUnknownFieldsAndPreexistingEffectCapabilityRequireManualReview() throws {
        var source = try sourceFiles()
        var screen = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(source["screens/screen_main.json"])) as? [String: Any])
        var root = try XCTUnwrap(screen["root"] as? [String: Any])
        root["newSemantic"] = "unreviewed"
        screen["root"] = root
        source["screens/screen_main.json"] = try JSONSerialization.data(withJSONObject: screen)
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(source["hamii.json"])) as? [String: Any])
        var declarations = try XCTUnwrap(manifest["capabilityDeclarations"] as? [[String: Any]])
        declarations.append(["targetID": ["rawValue": "target_ios"], "key": ["rawValue": "effect.padding"], "support": "exact", "reason": "ambiguous"])
        manifest["capabilityDeclarations"] = declarations
        source["hamii.json"] = try JSONSerialization.data(withJSONObject: manifest)
        let analysis = try MigrationRegistry.analyze(MigrationFileSet(files: source))
        XCTAssertEqual(analysis.classification, .manual)
        XCTAssertEqual(Set(analysis.diagnostics.map(\.code)), ["schema.unknownField", "capability.ambiguousPadding"])
        XCTAssertThrowsError(try MigrationRegistry.transform(MigrationFileSet(files: source)))
    }

    func testPreservedHistoricalCrossKindFixtureBlocksAutomaticCandidate() throws {
        var source = try sourceFiles()
        let rootBytes = try Data(contentsOf: fixtures.appendingPathComponent("format-v1-layer.json"))
        var screen = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(source["screens/screen_main.json"])) as? [String: Any])
        screen["root"] = try JSONSerialization.jsonObject(with: rootBytes)
        source["screens/screen_main.json"] = try JSONSerialization.data(withJSONObject: screen)
        let analysis = try MigrationRegistry.analyze(MigrationFileSet(files: source))
        XCTAssertEqual(analysis.classification, .manual)
        XCTAssertTrue(analysis.diagnostics.contains { $0.code == "layer.crossKindResidual" && $0.entityID == "layer_text" })
    }

    // Manifest is encoded through a historical-independent shape solely to assert writer bytes.
    private struct DocumentManifestProbe: Codable {
        var authoringHarness: AuthoringHarness
        var capabilityDeclarations: [CapabilityDeclaration]
        var formatVersion: Int
        var id: EntityID
        var name: String
        var revision: Int
        var versions: FormatVersions
    }
}
