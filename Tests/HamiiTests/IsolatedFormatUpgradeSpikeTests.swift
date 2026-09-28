import CryptoKit
import Foundation
import HamiiCore
import HamiiFormat
import HamiiIndex
import HamiiMigrationBoundarySpike
import XCTest

/// Test-side semantic oracle. The historical edge target imports only Foundation.
final class IsolatedFormatUpgradeSpikeTests: XCTestCase {
    private let folders = ["pages", "screens", "scopes", "components", "tokens", "assets", "interactions", "motions", "fixtures", "targets"]

    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("hamii-migration-probe-\(UUID().uuidString)")
    }

    private func fixture(at root: URL) throws -> Document {
        let repository = CanonicalRepository(root: root)
        let created = try repository.create(name: "Migration boundary")
        var document = created
        let scope = EntityID("scope_app")
        let target = EntityID("target_swiftui")
        let screen = EntityID("screen_probe")
        let padding = EntityID("token_padding")
        let inner = EntityID("component_inner")
        let outer = EntityID("component_outer")
        document.scopes = [ArchitectureScope(id: scope, name: "App", parentID: nil)]
        document.targets = [Target(id: target, platform: .iOS, framework: .swiftUI)]
        document.tokens = [DesignToken(id: padding, name: "Padding", kind: .spacing, ownerScopeID: scope, value: .literal("16"))]
        document.assets = [Asset(id: EntityID("asset_system"), name: "Star", ownerScopeID: scope,
                                 mediaType: "image/system", source: .system(name: "star"))]
        document.capabilityDeclarations = [CapabilityDeclaration(targetID: target, key: CapabilityKeys.paddingToken, support: .portable)]
        let innerRoot = Layer(id: EntityID("layer_inner_root"), kind: .stack, name: "Inner",
                              children: [Layer(id: EntityID("layer_inner_text"), kind: .text, name: "Text", text: "Inner")],
                              layout: Layout(paddingTokenID: padding))
        let innerDefinition = ComponentDefinition(id: inner, name: "Inner", ownerScopeID: scope, root: innerRoot)
        let nested = Layer(id: EntityID("layer_nested_instance"), kind: .componentInstance, name: "Nested",
                           component: ComponentInstance(definitionID: inner))
        let slot = Layer(id: EntityID("layer_slot"), kind: .stack, name: "Slot")
        var outerDefinition = ComponentDefinition(id: outer, name: "Outer", ownerScopeID: scope,
            root: Layer(id: EntityID("layer_outer_root"), kind: .stack, name: "Outer",
                        children: [nested, slot], layout: Layout(paddingTokenID: padding)))
        outerDefinition.api.slots = [ComponentSlot(name: "content", targetLayerID: slot.id)]
        document.components = [innerDefinition, outerDefinition]
        let slotted = Layer(id: EntityID("layer_slotted_text"), kind: .text, name: "Slotted", text: "Content")
        let screenInstance = Layer(id: EntityID("layer_screen_instance"), kind: .componentInstance, name: "Outer",
            component: ComponentInstance(definitionID: outer, slotContent: ["content": [slotted]]))
        document.screens = [Screen(id: screen, name: "Screen", scopeID: scope,
            root: Layer(id: EntityID("layer_screen_root"), kind: .stack, name: "Root",
                        children: [screenInstance], layout: Layout(paddingTokenID: padding)))]
        document.pages = [Page(id: EntityID("page_probe"), name: "Page", surfaces: [
            AppSurface(id: EntityID("surface_probe"), targetID: target, device: "iPhone", runtime: "iOS 26",
                       buildEnvironment: "SDK", screenID: screen, architectureScopeID: scope)
        ])]
        document.revision = 1
        try repository.save(document, expected: created)
        XCTAssertEqual(try repository.load(), document)
        return document
    }

    private func files(at root: URL) throws -> RawFormatUpgradeProbe.Files {
        var paths = ["hamii.json", "hamii-agent-profiles.json"]
        for folder in folders {
            let directory = root.appendingPathComponent(folder)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            paths += try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasSuffix(".json") }.map { "\(folder)/\($0)" }
        }
        return try Dictionary(uniqueKeysWithValues: paths.map { path in
            (path, try Data(contentsOf: root.appendingPathComponent(path)))
        })
    }

    private func digest(_ files: RawFormatUpgradeProbe.Files) -> String {
        var hash = SHA256()
        for path in files.keys.sorted() {
            hash.update(data: Data(path.utf8)); hash.update(data: Data([0]))
            hash.update(data: files[path]!); hash.update(data: Data([0]))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func adaptLayer(_ original: [String: Any]) throws -> [String: Any] {
        var layer = original
        if let effects = layer.removeValue(forKey: "effects") as? [[String: Any]] {
            guard effects.count == 1, effects[0]["kind"] as? String == "padding",
                  let token = effects[0]["tokenID"] as? [String: Any],
                  token["rawValue"] as? String != nil else { throw ProbeError.invalidEffect }
            var layout = layer["layout"] as? [String: Any] ?? [:]
            guard layout["paddingTokenID"] == nil else { throw ProbeError.invalidEffect }
            layout["paddingTokenID"] = token
            layer["layout"] = layout
        }
        if let children = layer["children"] as? [[String: Any]] {
            layer["children"] = try children.map(adaptLayer)
        }
        if var component = layer["component"] as? [String: Any],
           var slots = component["slotContent"] as? [String: [[String: Any]]] {
            for name in slots.keys.sorted() { slots[name] = try slots[name]!.map(adaptLayer) }
            component["slotContent"] = slots
            layer["component"] = component
        }
        return layer
    }

    private enum ProbeError: Error { case invalidEffect, injectedValidation }

    private func currentAdapter(_ candidate: RawFormatUpgradeProbe.Files) throws -> RawFormatUpgradeProbe.Files {
        var files = candidate
        guard let manifestBytes = files["hamii.json"],
              var manifest = try JSONSerialization.jsonObject(with: manifestBytes) as? [String: Any],
              var versions = manifest["versions"] as? [String: Any] else { throw ProbeError.invalidEffect }
        manifest["formatVersion"] = 1; versions["document"] = 1; manifest["versions"] = versions
        files["hamii.json"] = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        for path in files.keys.sorted() where path.hasPrefix("screens/") || path.hasPrefix("components/") {
            guard let bytes = files[path], var json = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let layer = json["root"] as? [String: Any] else { throw ProbeError.invalidEffect }
            json["root"] = try adaptLayer(layer)
            files[path] = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        }
        return files
    }

    private func materialize(_ files: RawFormatUpgradeProbe.Files, at root: URL) throws {
        for (path, bytes) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
    }

    private func git(_ arguments: [String], at root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        process.standardOutput = Pipe(); process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments)")
    }

    func testRawEdgeGraphDeterminismAndCurrentSystemHandoff() throws {
        let sourceRoot = root(); let adaptedRoot = root(); let indexRoot = root()
        defer {
            for url in [sourceRoot, adaptedRoot, indexRoot] { try? FileManager.default.removeItem(at: url) }
        }
        let expected = try fixture(at: sourceRoot)
        let source = try files(at: sourceRoot)
        let sourceDigest = digest(source)
        XCTAssertEqual(source.count, 10) // manifest, agent profile, page, screen, scope, 2 components, token, asset, target
        let oracle: RawFormatUpgradeProbe.Validator = { [self] candidate, version in
            XCTAssertEqual(try RawFormatUpgradeProbe.version(candidate), version)
            let temp = root()
            defer { try? FileManager.default.removeItem(at: temp) }
            try materialize(try currentAdapter(candidate), at: temp)
            XCTAssertEqual(try CanonicalRepository(root: temp).load(), expected)
        }
        var runs: [RawFormatUpgradeProbe.Candidate] = []
        for _ in 0..<3 { runs.append(try RawFormatUpgradeProbe.migrate(source, to: 3, validate: oracle)) }
        let candidate = runs[0]
        XCTAssertEqual(candidate.edges, ["1->2", "2->3"])
        XCTAssertEqual(candidate.validatedVersions, [1, 2, 3])
        XCTAssertEqual(candidate.classification, "losslessWithNormalization")
        XCTAssertEqual(candidate.files["hamii-agent-profiles.json"], source["hamii-agent-profiles.json"])
        for path in source.keys where path != "hamii.json" && !path.hasPrefix("screens/") && !path.hasPrefix("components/") {
            XCTAssertEqual(candidate.files[path], source[path], path)
        }
        for run in runs.dropFirst() {
            XCTAssertEqual(run.files, candidate.files)
            XCTAssertEqual(run.classification, candidate.classification)
            XCTAssertEqual(run.diagnostics, candidate.diagnostics)
        }
        let v2 = try RawFormatUpgradeProbe.migrate(source, to: 2, validate: oracle)
        XCTAssertEqual(v2.validatedVersions, [1, 2])
        XCTAssertEqual(v2.classification, "lossless")
        let stepwise = try RawFormatUpgradeProbe.migrate(v2.files, to: 3, validate: oracle)
        XCTAssertEqual(stepwise.files, candidate.files)
        XCTAssertEqual(try RawFormatUpgradeProbe.migrate(candidate.files, to: 3, validate: oracle).files, candidate.files)
        XCTAssertThrowsError(try RawFormatUpgradeProbe.migrate(source, to: 4, validate: oracle))
        XCTAssertThrowsError(try RawFormatUpgradeProbe.migrate(candidate.files, to: 1, validate: oracle))
        var inconsistent = source
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: source["hamii.json"]!) as? [String: Any])
        manifest["formatVersion"] = 2
        inconsistent["hamii.json"] = try JSONSerialization.data(withJSONObject: manifest)
        XCTAssertThrowsError(try RawFormatUpgradeProbe.migrate(inconsistent, to: 3, validate: oracle))
        for edge in [2, 3] {
            XCTAssertThrowsError(try RawFormatUpgradeProbe.migrate(source, to: 3, failAfterEdge: edge, validate: oracle))
        }
        var visitedVersions: [Int] = []
        XCTAssertThrowsError(try RawFormatUpgradeProbe.migrate(source, to: 3, validate: { _, version in
            visitedVersions.append(version)
            if version == 2 { throw ProbeError.injectedValidation }
        }))
        XCTAssertEqual(visitedVersions, [1, 2])
        XCTAssertEqual(digest(try files(at: sourceRoot)), sourceDigest)
        XCTAssertEqual(source, try files(at: sourceRoot))

        try materialize(try currentAdapter(candidate.files), at: adaptedRoot)
        try git(["init", "-q"], at: adaptedRoot)
        try git(["add", "-A"], at: adaptedRoot)
        try git(["-c", "user.name=Probe", "-c", "user.email=probe@example.invalid", "commit", "-qm", "candidate"], at: adaptedRoot)
        let repository = CanonicalRepository(root: adaptedRoot)
        let snapshot = try repository.withCoordinatedSnapshot { $0 }
        XCTAssertEqual(snapshot.document, expected)
        let calculator = GitCanonicalRevisionCalculator()
        let revision = try calculator.current(at: adaptedRoot)
        let index = try LocalIndex(projectRoot: adaptedRoot, documentID: expected.id,
                                   revisionCalculator: calculator, storageRoot: indexRoot)
        _ = try index.rebuild(from: snapshot, canonicalRevision: revision)
        let hits = try index.components(matching: "Outer", consumerScopeID: expected.scopes[0].id,
                                        documentID: expected.id, revision: expected.revision,
                                        expectedSourceIdentity: snapshot.identity)
        XCTAssertEqual(hits.map(\.id), [EntityID("component_outer")])
        XCTAssertEqual(hits.first?.usageCount, 1)
        if let output = ProcessInfo.processInfo.environment["HAMII_MIGRATION_MATRIX_OUTPUT"] {
            let matrix: [String: Any] = [
                "scope": "test-only edge graph; current-format adapter used only in outer oracle",
                "sourceVersion": 1, "targetVersion": 3, "sourcePathCount": source.count,
                "candidatePathCount": candidate.files.count, "resolvedEdges": candidate.edges,
                "classification": candidate.classification, "sourceDigestBefore": sourceDigest,
                "sourceDigestAfter": digest(try files(at: sourceRoot)), "candidateDigest": digest(candidate.files),
                "repeatDigests": runs.map { digest($0.files) }, "stepwiseDigest": digest(stepwise.files),
                "intermediateValidation": candidate.validatedVersions, "finalValidation": "passed via v1 test adapter",
                "referencePreservation": "current semantic Document equality", "freshIndexRebuild": "passed; Outer usage=1",
                "agentProfileBytePassthrough": true, "injectedFailures": [2, 3],
                "versionMarkerMismatch": "rejected", "unsupportedTarget": "noPath", "downgrade": "rejected",
                "cases": [
                    ["from": 1, "to": 2, "result": "passed; v1-to-v2; lossless"],
                    ["from": 2, "to": 3, "result": "passed; v2-to-v3; losslessWithNormalization"],
                    ["from": 1, "to": 3, "result": "passed; both edges; v1,v2,v3 validated"],
                    ["from": 3, "to": 3, "result": "passed; no-op"],
                    ["from": 1, "to": 4, "result": "noPath"],
                    ["from": 3, "to": 1, "result": "downgrade rejected"]
                ]
            ]
            let bytes = try JSONSerialization.data(withJSONObject: matrix, options: [.prettyPrinted, .sortedKeys]) + Data([0x0a])
            try bytes.write(to: URL(fileURLWithPath: output))
        }
    }
}
