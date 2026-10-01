import Foundation
import XCTest
import HamiiMigrations
import HamiiFormat
import HamiiCore

final class MigrationResolutionProductionTests: XCTestCase {
    private typealias Object = [String: Any]
    private var fixtureRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/format-v1-safe-project")
    }

    private func source() throws -> [String: Data] {
        var files: [String: Data] = [:]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: fixtureRoot, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where !url.hasDirectoryPath {
            files[String(url.path.dropFirst(fixtureRoot.path.count + 1))] = try Data(contentsOf: url)
        }
        return files
    }

    private func edit(_ files: inout [String: Data], _ path: String, _ body: (inout Object) throws -> Void) throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(files[path])) as? Object)
        try body(&json)
        var bytes = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        bytes.append(0x0A)
        files[path] = bytes
    }

    private func addSpacing(_ files: inout [String: Data], equivalent: Bool) throws {
        try edit(&files, "hamii.json") { manifest in
            var values = try XCTUnwrap(manifest["capabilityDeclarations"] as? [Object])
            var duplicate = values[0]
            if !equivalent {
                duplicate["support"] = "portable"
                duplicate["reason"] = "second historical declaration"
            }
            values.append(duplicate)
            manifest["capabilityDeclarations"] = values
        }
    }

    private func addResidual(_ files: inout [String: Data], button: Bool = false) throws {
        try edit(&files, "screens/screen_main.json") { screen in
            var root = try XCTUnwrap(screen["root"] as? Object)
            var children = try XCTUnwrap(root["children"] as? [Object])
            if button {
                children[1]["assetID"] = ["rawValue": "asset_symbol"]
            } else {
                var scroll = children[0]
                var descendants = try XCTUnwrap(scroll["children"] as? [Object])
                descendants[0]["assetID"] = ["rawValue": "asset_symbol"]
                scroll["children"] = descendants
                children[0] = scroll
            }
            root["children"] = children
            screen["root"] = root
        }
    }

    private func binding(_ files: [String: Data], oid: String = "fixture-oid") -> MigrationResolutionSourceBinding {
        MigrationResolutionSourceBinding(sourceOID: oid,
            sourceCanonicalIdentity: CanonicalByteIdentity.compute(files: files).rawValue)
    }

    private func report(_ files: [String: Data]) throws -> MigrationResolutionReport {
        try MigrationRegistry.resolutionReport(MigrationFileSet(files: files), sourceBinding: binding(files))
    }

    private func manifest(_ report: MigrationResolutionReport,
                          choose: (MigrationResolutionItem) -> MigrationResolutionChoice?) -> MigrationResolutionManifest {
        MigrationResolutionManifest(source: report.source,
            decisions: report.items.compactMap { item in
                choose(item).map { MigrationResolutionDecision(item: item.id, selectedCandidateID: $0.id) }
            })
    }

    private func transform(_ files: [String: Data],
                           manifest: MigrationResolutionManifest) throws -> MigrationCandidate {
        try MigrationRegistry.transform(MigrationFileSet(files: files), applying: manifest,
            actualSourceBinding: binding(files))
    }

    private func validCurrent(_ files: [String: Data]) throws -> Bool {
        let final = try MigrationRegistry.applyEdge(MigrationFileSet(files: files),
            edge: MigrationEdge(sourceVersion: 2, targetVersion: 3))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for (path, bytes) in final.files.files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
        let document = try CanonicalRepository(root: root).load()
        return document.versions.document == 3 && DocumentValidator.validate(document).isEmpty
    }

    func testResolutionCannotApplyWhenItsEdgeIsAbsentFromRoute() throws {
        let current = try MigrationRegistry.transform(MigrationFileSet(files: source()), to: 2).files
        let currentBinding = binding(current.files)
        let irrelevant = MigrationResolutionManifest(source: currentBinding, decisions: [])
        XCTAssertThrowsError(try MigrationRegistry.resolutionReport(current,
            sourceBinding: currentBinding))
        XCTAssertThrowsError(try MigrationRegistry.transform(current, applying: irrelevant,
            actualSourceBinding: currentBinding))
    }

    func testDistinctAndEquivalentSpacingChoicesStayExplicit() throws {
        for equivalent in [false, true] {
            var files = try source()
            try addSpacing(&files, equivalent: equivalent)
            let observed = try report(files)
            XCTAssertEqual(observed.items.map { $0.diagnostic.code }, ["capability.ambiguousSpacing"])
            let item = try XCTUnwrap(observed.items.first)
            XCTAssertEqual(item.choices.count, 2)
            for choice in item.choices {
                let selected = manifest(observed) { _ in choice }
                let candidate = try transform(files, manifest: selected)
                XCTAssertTrue(try validCurrent(candidate.files.files))
                XCTAssertEqual(candidate.classification, equivalent ? .losslessWithNormalization : .potentiallyLossy)
                XCTAssertEqual(candidate.losses.count, equivalent ? 0 : 1)
                XCTAssertEqual(candidate.resolutionDecisions, selected.decisions)
                if !equivalent {
                    XCTAssertTrue(candidate.losses[0].path.hasPrefix("hamii.json.capabilityDeclarations["))
                    XCTAssertTrue(candidate.losses[0].historicalValue.contains("support"))
                }
                let converted = try XCTUnwrap(JSONSerialization.jsonObject(with:
                    XCTUnwrap(candidate.files.files["hamii.json"])) as? Object)
                let values = try XCTUnwrap(converted["capabilityDeclarations"] as? [Object])
                let padding = try XCTUnwrap(values.first {
                    (($0["key"] as? Object)?["rawValue"] as? String) == "effect.padding"
                })
                let expected = choice.id.hasPrefix("spacing:0:") ? "exact" : equivalent ? "exact" : "portable"
                XCTAssertEqual(padding["support"] as? String, expected)
                for _ in 0..<3 {
                    let repeated = try transform(files, manifest: selected)
                    XCTAssertEqual(repeated.files.files, candidate.files.files)
                    XCTAssertEqual(repeated.classification, candidate.classification)
                    XCTAssertEqual(repeated.losses, candidate.losses)
                    XCTAssertEqual(repeated.resolutionDecisions, candidate.resolutionDecisions)
                    XCTAssertEqual(repeated.remainingUnresolved, candidate.remainingUnresolved)
                }
            }
        }
    }

    func testResidualsNeedIndependentExplicitChoicesAndPreserveLoss() throws {
        var files = try source()
        try addResidual(&files)
        try addResidual(&files, button: true)
        let observed = try report(files)
        XCTAssertEqual(observed.items.count, 2)
        XCTAssertTrue(observed.items.allSatisfy { $0.diagnostic.code == "layer.crossKindResidual" && $0.choices.count == 1 })
        let partial = MigrationResolutionManifest(source: observed.source,
            decisions: [MigrationResolutionDecision(item: observed.items[0].id,
                selectedCandidateID: observed.items[0].choices[0].id)])
        XCTAssertThrowsError(try transform(files, manifest: partial))
        let all = manifest(observed) { $0.choices.first }
        let candidate = try transform(files, manifest: all)
        XCTAssertEqual(candidate.classification, .potentiallyLossy)
        XCTAssertEqual(candidate.losses.count, 2)
        XCTAssertEqual(Set(candidate.losses.map(\.entityID)), ["layer_title", "layer_button"])
        XCTAssertTrue(candidate.losses.allSatisfy { $0.historicalValue.contains("asset_symbol") })
        XCTAssertTrue(try validCurrent(candidate.files.files))
    }

    func testZeroChoiceDiagnosticsRemainBlocked() throws {
        for name in ["padding", "capability", "field", "case", "kind", "path"] {
            var files = try source()
            switch name {
            case "padding":
                try edit(&files, "hamii.json") { value in
                    var declarations = try XCTUnwrap(value["capabilityDeclarations"] as? [Object])
                    declarations.append(["targetID": ["rawValue": "target_ios"],
                                         "key": ["rawValue": "effect.padding"], "support": "exact", "reason": "unknown"])
                    value["capabilityDeclarations"] = declarations
                }
            case "capability":
                try edit(&files, "hamii.json") { value in
                    var declarations = try XCTUnwrap(value["capabilityDeclarations"] as? [Object])
                    declarations.append(["targetID": ["rawValue": "target_ios"],
                                         "key": ["rawValue": "future.capability"], "support": "exact", "reason": "unknown"])
                    value["capabilityDeclarations"] = declarations
                }
            case "field":
                try edit(&files, "screens/screen_main.json") { value in
                    var root = try XCTUnwrap(value["root"] as? Object)
                    root["futureField"] = "unknown"
                    value["root"] = root
                }
            case "case": try edit(&files, "assets/asset_symbol.json") { $0["source"] = ["futureSource": ["value": "unknown"]] }
            case "kind":
                try edit(&files, "screens/screen_main.json") { value in
                    var root = try XCTUnwrap(value["root"] as? Object)
                    root["kind"] = "futureKind"
                    value["root"] = root
                }
            case "path": files["future/unknown.json"] = Data("{}\n".utf8)
            default: XCTFail("unexpected scenario")
            }
            let observed = try report(files)
            XCTAssertEqual(observed.items.count, 1, name)
            XCTAssertTrue(observed.items[0].choices.isEmpty, name)
            XCTAssertThrowsError(try transform(files, manifest: manifest(observed) { $0.choices.first }), name)
        }
    }

    func testPartialStaleInvalidManifestAndAutomaticPath() throws {
        var files = try source()
        try addSpacing(&files, equivalent: false)
        try addResidual(&files)
        let observed = try report(files)
        let partial = manifest(observed) { $0.diagnostic.code == "capability.ambiguousSpacing" ? $0.choices.first : nil }
        XCTAssertThrowsError(try transform(files, manifest: partial))
        var changed = files
        try edit(&changed, "pages/page_main.json") { $0["name"] = "Different source" }
        XCTAssertThrowsError(try MigrationRegistry.transform(MigrationFileSet(files: changed), applying: partial,
            actualSourceBinding: binding(changed)))
        let wrongChoice = MigrationResolutionManifest(source: observed.source,
            decisions: [MigrationResolutionDecision(item: observed.items[0].id, selectedCandidateID: "not-a-candidate")])
        XCTAssertThrowsError(try transform(files, manifest: wrongChoice))
        let duplicate = MigrationResolutionManifest(source: observed.source,
            decisions: [partial.decisions[0], partial.decisions[0]])
        XCTAssertThrowsError(try transform(files, manifest: duplicate))
        let wrongOID = MigrationResolutionManifest(source: binding(files, oid: "wrong"), decisions: partial.decisions)
        XCTAssertThrowsError(try transform(files, manifest: wrongOID))

        let encoder = JSONEncoder()
        let valid = try encoder.encode(partial)
        XCTAssertEqual(try MigrationResolutionManifest.decodeStrict(valid).decisions, partial.decisions)
        for mutation in ["unknownField", "formatVersion", "targetFormatVersion"] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? Object)
            if mutation == "unknownField" { json["arbitraryPatch"] = ["path": "hamii.json", "value": 2] }
            if mutation == "formatVersion" { json["formatVersion"] = 9 }
            if mutation == "targetFormatVersion" { json["targetFormatVersion"] = 3 }
            XCTAssertThrowsError(try MigrationResolutionManifest.decodeStrict(
                JSONSerialization.data(withJSONObject: json)), mutation)
        }
        let safe = try source()
        let automatic = try MigrationRegistry.transform(MigrationFileSet(files: safe), to: 2)
        XCTAssertEqual(automatic.classification, .losslessWithNormalization)
        XCTAssertTrue(automatic.resolutionDecisions.isEmpty)
        XCTAssertTrue(automatic.losses.isEmpty)
        XCTAssertEqual(automatic.files.files,
            try MigrationRegistry.transform(MigrationFileSet(files: safe), to: 2).files.files)
    }
}
