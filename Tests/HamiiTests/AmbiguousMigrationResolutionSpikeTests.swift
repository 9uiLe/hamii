import Foundation
import XCTest
import HamiiCore
import HamiiFormat
import HamiiMigrations

/// Evidence-only prototype. Production migration does not consume these types.
final class AmbiguousMigrationResolutionSpikeTests: XCTestCase {
    private typealias Object = [String: Any]

    private struct Choice {
        let id: String
        let spacingIndex: Int?
        let discardsResidual: Bool
        let affectedSemantic: String
        let affectedPaths: [String]
        let affectedEntityID: String?
        let lossClass: MigrationClassification
    }

    private struct Item {
        let diagnostic: MigrationDiagnostic
        let identity: String
        let choices: [Choice]
    }

    private struct Decision: Codable {
        let diagnosticIdentity: String
        let selectedCandidateID: String
    }

    private struct ResolutionManifest: Codable {
        let formatVersion: Int
        let sourceOID: String
        let sourceCanonicalIdentity: String
        let sourceFormatVersion: Int
        let targetFormatVersion: Int
        let decisions: [Decision]

        init(sourceOID: String, sourceCanonicalIdentity: String, decisions: [Decision],
             formatVersion: Int = 1, sourceFormatVersion: Int = 1, targetFormatVersion: Int = 2) {
            self.formatVersion = formatVersion
            self.sourceOID = sourceOID
            self.sourceCanonicalIdentity = sourceCanonicalIdentity
            self.sourceFormatVersion = sourceFormatVersion
            self.targetFormatVersion = targetFormatVersion
            self.decisions = decisions
        }
    }

    private struct Loss: Codable, Equatable {
        let path: String
        let historicalValue: String
        let choiceID: String
    }

    private struct Outcome {
        let candidate: [String: Data]?
        let classification: MigrationClassification
        let diagnostics: [MigrationDiagnostic]
        let unresolved: [String]
        let decisions: [String]
        let losses: [Loss]
    }

    private struct MatrixRow: Codable {
        let scenario: String
        let diagnosticCode: String
        let path: String
        let entityID: String?
        let candidateCount: Int
        let candidateIDs: [String]
        let candidateSemantics: [String]
        let candidateLossClasses: [String]
        let affectedPaths: [String]
        let chosenCandidate: String?
        let sourceBound: Bool
        let classificationBefore: String
        let classificationAfter: String
        let lossVisible: Bool
        let remainingUnresolved: Int
        let candidateProduced: Bool
        let currentV2Valid: Bool
        let deterministic: Bool
        let losses: [Loss]
        let staleResolutionRejected: Bool?
    }

    private var fixtureRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/format-v1-safe-project")
    }

    private func sourceFiles() throws -> [String: Data] {
        var files: [String: Data] = [:]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: fixtureRoot, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where !url.hasDirectoryPath {
            files[String(url.path.dropFirst(fixtureRoot.path.count + 1))] = try Data(contentsOf: url)
        }
        return files
    }

    private func object(_ bytes: Data) throws -> Object {
        try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? Object)
    }

    private func encoded(_ value: Any) throws -> Data {
        var bytes = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        bytes.append(0x0A)
        return bytes
    }

    private func exactJSON(_ value: Any) throws -> String {
        String(decoding: try encoded(["value": value]), as: UTF8.self)
    }

    private func fingerprint(_ value: Any) throws -> String {
        CanonicalByteIdentity.compute(files: ["value.json": try encoded(["value": value])]).rawValue
    }

    private func edit(_ files: inout [String: Data], path: String, _ body: (inout Object) throws -> Void) throws {
        var value = try object(XCTUnwrap(files[path]))
        try body(&value)
        files[path] = try encoded(value)
    }

    private func declarations(_ files: [String: Data]) throws -> [Object] {
        try XCTUnwrap(object(XCTUnwrap(files["hamii.json"]))["capabilityDeclarations"] as? [Object])
    }

    private func addSpacing(_ files: inout [String: Data], equivalent: Bool) throws {
        try edit(&files, path: "hamii.json") { manifest in
            var values = try XCTUnwrap(manifest["capabilityDeclarations"] as? [Object])
            var duplicate = values[0]
            if !equivalent { duplicate["support"] = "portable"; duplicate["reason"] = "second v1 spacing support" }
            values.append(duplicate)
            manifest["capabilityDeclarations"] = values
        }
    }

    private func editScreenRoot(_ files: inout [String: Data], _ body: (inout Object) throws -> Void) throws {
        try edit(&files, path: "screens/screen_main.json") { screen in
            var root = try XCTUnwrap(screen["root"] as? Object)
            try body(&root)
            screen["root"] = root
        }
    }

    private func addResidual(_ files: inout [String: Data], to entityID: String) throws {
        try editScreenRoot(&files) { root in
            var children = try XCTUnwrap(root["children"] as? [Object])
            if entityID == "layer_title" {
                var scroll = children[0]
                var descendants = try XCTUnwrap(scroll["children"] as? [Object])
                descendants[0]["assetID"] = ["rawValue": "asset_symbol"]
                scroll["children"] = descendants
                children[0] = scroll
            } else {
                children[1]["assetID"] = ["rawValue": "asset_symbol"]
            }
            root["children"] = children
        }
    }

    private func scenario(_ name: String) throws -> [String: Data] {
        var files = try sourceFiles()
        switch name {
        case "A": try addSpacing(&files, equivalent: false)
        case "B": try addSpacing(&files, equivalent: true)
        case "C":
            try edit(&files, path: "hamii.json") { manifest in
                var values = try XCTUnwrap(manifest["capabilityDeclarations"] as? [Object])
                values.append(["targetID": ["rawValue": "target_ios"], "key": ["rawValue": "effect.padding"],
                               "support": "exact", "reason": "unreviewed historical declaration"])
                manifest["capabilityDeclarations"] = values
            }
        case "D": try addResidual(&files, to: "layer_title")
        case "E": try addResidual(&files, to: "layer_title"); try addResidual(&files, to: "layer_button")
        case "F": try addUnknownCapability(&files)
        case "G": try editScreenRoot(&files) { $0["futureLayerField"] = "unreviewed" }
        case "H": try edit(&files, path: "assets/asset_symbol.json") { $0["source"] = ["futureAssetSource": ["value": "unreviewed"]] }
        case "I": try editScreenRoot(&files) { $0["kind"] = "futureLayer" }
        case "J": files["future/unknown.json"] = Data("{}\n".utf8)
        case "K": try addSpacing(&files, equivalent: false); try addResidual(&files, to: "layer_title"); try addUnknownCapability(&files)
        case "L": try addSpacing(&files, equivalent: false)
        case "M": break
        default: XCTFail("Unknown scenario \(name)")
        }
        return files
    }

    private func addUnknownCapability(_ files: inout [String: Data]) throws {
        try edit(&files, path: "hamii.json") { manifest in
            var values = try XCTUnwrap(manifest["capabilityDeclarations"] as? [Object])
            values.append(["targetID": ["rawValue": "target_ios"], "key": ["rawValue": "future.capability"],
                           "support": "exact", "reason": "unknown meaning"])
            manifest["capabilityDeclarations"] = values
        }
    }

    private func layer(_ value: Object, id: String) -> Object? {
        if (value["id"] as? Object)?["rawValue"] as? String == id { return value }
        for child in value["children"] as? [Object] ?? [] {
            if let result = layer(child, id: id) { return result }
        }
        if let slots = (value["component"] as? Object)?["slotContent"] as? Object {
            for values in slots.values {
                for child in values as? [Object] ?? [] {
                    if let result = layer(child, id: id) { return result }
                }
            }
        }
        return nil
    }

    private func residualValue(_ files: [String: Data], diagnostic: MigrationDiagnostic) throws -> Any {
        let file = try XCTUnwrap(diagnostic.path.components(separatedBy: ".root").first)
        let entity = try object(XCTUnwrap(files[file]))
        let root = try XCTUnwrap(entity["root"] as? Object)
        let found = try XCTUnwrap(layer(root, id: XCTUnwrap(diagnostic.entityID)))
        let key = try XCTUnwrap(diagnostic.path.split(separator: ".").last.map(String.init))
        return try XCTUnwrap(found[key])
    }

    private func items(_ files: [String: Data]) throws -> [Item] {
        let analysis = try MigrationRegistry.analyze(MigrationFileSet(files: files))
        let values = try declarations(files)
        return try analysis.diagnostics.map { diagnostic in
            let relevant: Any
            var choices: [Choice] = []
            switch diagnostic.code {
            case "capability.ambiguousSpacing":
                let matching = values.enumerated().filter { _, value in
                    ((value["targetID"] as? Object)?["rawValue"] as? String) == diagnostic.entityID &&
                    ((value["key"] as? Object)?["rawValue"] as? String) == "token.spacing"
                }
                relevant = matching.map(\.element)
                let equivalent = try Set(matching.map { try exactJSON($0.element) }).count == 1
                choices = try matching.map { index, value in
                    Choice(id: "spacing:\(index):\(try fingerprint(value))", spacingIndex: index, discardsResidual: false,
                           affectedSemantic: "v2 effect.padding and retained token.spacing declarations",
                           affectedPaths: [diagnostic.path], affectedEntityID: diagnostic.entityID,
                           lossClass: equivalent ? .losslessWithNormalization : .potentiallyLossy)
                }
            case "layer.crossKindResidual":
                relevant = try residualValue(files, diagnostic: diagnostic)
                let key = diagnostic.path.split(separator: ".").last.map(String.init) ?? ""
                if ["assetID", "component", "text", "textBinding", "emittedEvent"].contains(key) {
                    choices = [Choice(id: "discard:\(try fingerprint(relevant))", spacingIndex: nil, discardsResidual: true,
                                      affectedSemantic: "historical cross-kind \(key) residual",
                                      affectedPaths: [diagnostic.path], affectedEntityID: diagnostic.entityID,
                                      lossClass: .potentiallyLossy)]
                }
            default:
                // For an unknown schema/meaning, the whole containing file is
                // a conservative historical-value fingerprint. No candidate
                // is synthesized from bytes whose semantics we do not know.
                let containingPath = files.keys.sorted(by: { $0.count > $1.count }).first {
                    diagnostic.path == $0 || diagnostic.path.hasPrefix($0 + ".")
                }
                relevant = containingPath.flatMap { files[$0]?.base64EncodedString() } ?? diagnostic.path
            }
            let identity = try fingerprint(["code": diagnostic.code, "path": diagnostic.path,
                                            "entityID": diagnostic.entityID ?? "", "value": relevant])
            return Item(diagnostic: diagnostic, identity: identity, choices: choices)
        }
    }

    private func manifest(_ files: [String: Data], items: [Item], selected: [String], sourceOID: String = "fixture-source-OID") -> ResolutionManifest {
        ResolutionManifest(sourceOID: sourceOID,
            sourceCanonicalIdentity: CanonicalByteIdentity.compute(files: files).rawValue,
            decisions: items.filter { selected.contains($0.diagnostic.code) }.compactMap { item in
                item.choices.first.map { Decision(diagnosticIdentity: item.identity, selectedCandidateID: $0.id) }
            })
    }

    private func removeResidual(_ value: inout Object, id: String, key: String) -> Bool {
        if (value["id"] as? Object)?["rawValue"] as? String == id {
            value.removeValue(forKey: key)
            return true
        }
        if var children = value["children"] as? [Object] {
            for index in children.indices where removeResidual(&children[index], id: id, key: key) {
                value["children"] = children
                return true
            }
        }
        if var component = value["component"] as? Object, var slots = component["slotContent"] as? Object {
            for slot in slots.keys.sorted() {
                guard var children = slots[slot] as? [Object] else { continue }
                for index in children.indices where removeResidual(&children[index], id: id, key: key) {
                    slots[slot] = children
                    component["slotContent"] = slots
                    value["component"] = component
                    return true
                }
            }
        }
        return false
    }

    private func apply(_ files: [String: Data], manifest: ResolutionManifest, sourceOID: String = "fixture-source-OID") throws -> Outcome {
        guard manifest.formatVersion == 1, manifest.sourceFormatVersion == 1, manifest.targetFormatVersion == 2,
              manifest.sourceOID == sourceOID,
              manifest.sourceCanonicalIdentity == CanonicalByteIdentity.compute(files: files).rawValue else {
            throw SpikeFailure.staleSource
        }
        let analysis = try MigrationRegistry.analyze(MigrationFileSet(files: files))
        let sourceItems = try items(files)
        var selected: [(Item, Choice)] = []
        var seen = Set<String>()
        for decision in manifest.decisions {
            guard seen.insert(decision.diagnosticIdentity).inserted,
                  let item = sourceItems.first(where: { $0.identity == decision.diagnosticIdentity }),
                  let choice = item.choices.first(where: { $0.id == decision.selectedCandidateID }) else {
                throw SpikeFailure.invalidChoice
            }
            selected.append((item, choice))
        }
        let unresolved = sourceItems.filter { !seen.contains($0.identity) }.map(\.identity)
        if !unresolved.isEmpty {
            return Outcome(candidate: nil, classification: .manual, diagnostics: analysis.diagnostics,
                           unresolved: unresolved, decisions: selected.map { $0.1.id }, losses: [])
        }
        var edited = files
        var losses: [Loss] = []
        for (item, choice) in selected {
            switch item.diagnostic.code {
            case "capability.ambiguousSpacing":
                let chosen = try XCTUnwrap(choice.spacingIndex)
                let original = try declarations(files)
                let target = try XCTUnwrap(item.diagnostic.entityID)
                let sameTargetSpacing: (Object) -> Bool = { value in
                    ((value["targetID"] as? Object)?["rawValue"] as? String) == target &&
                    ((value["key"] as? Object)?["rawValue"] as? String) == "token.spacing"
                }
                let kept = original[chosen]
                try edit(&edited, path: "hamii.json") { value in
                    value["capabilityDeclarations"] = original.enumerated().filter { index, declaration in
                        !sameTargetSpacing(declaration) || index == chosen
                    }.map(\.element)
                }
                for (index, declaration) in original.enumerated() where index != chosen && sameTargetSpacing(declaration) {
                    if try exactJSON(declaration) != exactJSON(kept) {
                        losses.append(Loss(path: "hamii.json.capabilityDeclarations[\(index)]",
                                           historicalValue: try exactJSON(declaration), choiceID: choice.id))
                    }
                }
            case "layer.crossKindResidual":
                guard choice.discardsResidual else { throw SpikeFailure.invalidChoice }
                let value = try residualValue(files, diagnostic: item.diagnostic)
                let key = try XCTUnwrap(item.diagnostic.path.split(separator: ".").last.map(String.init))
                let id = try XCTUnwrap(item.diagnostic.entityID)
                let file = try XCTUnwrap(item.diagnostic.path.components(separatedBy: ".root").first)
                try edit(&edited, path: file) { entity in
                    var root = try XCTUnwrap(entity["root"] as? Object)
                    guard removeResidual(&root, id: id, key: key) else { throw SpikeFailure.invalidChoice }
                    entity["root"] = root
                }
                losses.append(Loss(path: item.diagnostic.path, historicalValue: try exactJSON(value), choiceID: choice.id))
            default: throw SpikeFailure.invalidChoice
            }
        }
        let migrated = try MigrationRegistry.transform(MigrationFileSet(files: edited))
        return Outcome(candidate: migrated.files.files,
                       classification: losses.isEmpty ? .losslessWithNormalization : .potentiallyLossy,
                       diagnostics: analysis.diagnostics, unresolved: [], decisions: selected.map { $0.1.id }, losses: losses)
    }

    private enum SpikeFailure: Error { case staleSource, invalidChoice }

    private func currentValid(_ files: [String: Data]) throws -> Bool {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for (path, bytes) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
        let document = try CanonicalRepository(root: root).load()
        return document.versions.document == 2 && DocumentValidator.validate(document).isEmpty
    }

    func testProductionBlockerMatrixAndTypedResolution() throws {
        let expected: [String: [String]] = [
            "A": ["capability.ambiguousSpacing"], "B": ["capability.ambiguousSpacing"],
            "C": ["capability.ambiguousPadding"], "D": ["layer.crossKindResidual"],
            "E": ["layer.crossKindResidual", "layer.crossKindResidual"],
            "F": ["capability.unknown"], "G": ["schema.unknownField"],
            "H": ["schema.unknownCase"], "I": ["layer.unknownKind"], "J": ["path.unknown"],
            "K": ["capability.ambiguousSpacing", "layer.crossKindResidual", "capability.unknown"],
            "L": ["capability.ambiguousSpacing"], "M": []
        ]
        var matrix: [MatrixRow] = []
        for name in "ABCDEFGHIJKLM".map(String.init) {
            let files = try scenario(name)
            let analysis = try MigrationRegistry.analyze(MigrationFileSet(files: files))
            let found = try items(files)
            XCTAssertEqual(analysis.diagnostics.map(\.code).sorted(), expected[name]?.sorted(), name)
            XCTAssertEqual(found.map(\.diagnostic), analysis.diagnostics, name)
            for item in found {
                for choice in item.choices {
                    XCTAssertFalse(choice.affectedSemantic.isEmpty)
                    XCTAssertTrue(choice.affectedPaths.contains(item.diagnostic.path))
                    XCTAssertEqual(choice.affectedEntityID, item.diagnostic.entityID)
                }
            }
            XCTAssertEqual(analysis.automaticCandidateEligible, name == "M", name)
            let selectedCodes: [String] = switch name {
            case "A", "B", "L": ["capability.ambiguousSpacing"]
            case "D", "E": ["layer.crossKindResidual"]
            case "K": ["capability.ambiguousSpacing"]
            default: []
            }
            let resolution = manifest(files, items: found, selected: selectedCodes)
            let wireManifest = try JSONDecoder().decode(ResolutionManifest.self, from: JSONEncoder().encode(resolution))
            let result = try apply(files, manifest: wireManifest)
            let expectedCandidate = ["A", "B", "D", "E", "L", "M"].contains(name)
            XCTAssertEqual(result.candidate != nil, expectedCandidate, name)
            XCTAssertEqual(result.unresolved.count, found.count - resolution.decisions.count, name)
            XCTAssertEqual(result.classification, name == "A" || name == "D" || name == "E" || name == "L"
                ? .potentiallyLossy : expectedCandidate ? .losslessWithNormalization : .manual, name)
            if name == "A" || name == "D" || name == "E" || name == "L" { XCTAssertFalse(result.losses.isEmpty, name) }
            if name == "B" { XCTAssertTrue(result.losses.isEmpty) }
            let valid = try result.candidate.map(currentValid) ?? false
            if expectedCandidate { XCTAssertTrue(valid, name) }
            if let candidate = result.candidate, name == "A" || name == "B" || name == "L" {
                let migrated = try object(XCTUnwrap(candidate["hamii.json"]))
                let entries = try XCTUnwrap(migrated["capabilityDeclarations"] as? [Object])
                let padding = try XCTUnwrap(entries.first {
                    (($0["key"] as? Object)?["rawValue"] as? String) == "effect.padding"
                })
                XCTAssertEqual(padding["support"] as? String, "exact", name)
                XCTAssertEqual(padding["reason"] as? String, "v1 spacing support", name)
                XCTAssertEqual(entries.filter {
                    (($0["key"] as? Object)?["rawValue"] as? String) == "token.spacing"
                }.count, 1, name)
            }
            if let candidate = result.candidate, name == "D" || name == "E" {
                let migrated = try object(XCTUnwrap(candidate["screens/screen_main.json"]))
                let root = try XCTUnwrap(migrated["root"] as? Object)
                for id in name == "E" ? ["layer_title", "layer_button"] : ["layer_title"] {
                    XCTAssertNil(layer(root, id: id)?["assetID"], "discarded residual remains on \(id)")
                }
            }
            var deterministic = true
            for _ in 0..<3 {
                let repeated = try apply(files, manifest: resolution)
                deterministic = deterministic && repeated.candidate == result.candidate &&
                    repeated.classification == result.classification && repeated.diagnostics == result.diagnostics &&
                    repeated.unresolved == result.unresolved && repeated.decisions == result.decisions &&
                    repeated.losses == result.losses
            }
            XCTAssertTrue(deterministic, name)
            var staleRejected: Bool? = nil
            if name == "L" {
                var changed = files
                try edit(&changed, path: "pages/page_main.json") { $0["name"] = "Same diagnostic, changed source bytes" }
                XCTAssertEqual(try items(changed).map(\.identity), found.map(\.identity))
                XCTAssertThrowsError(try apply(changed, manifest: resolution))
                staleRejected = true
            }
            let rows = found.isEmpty ? [nil] : found.map(Optional.some)
            for item in rows {
                matrix.append(MatrixRow(scenario: name, diagnosticCode: item?.diagnostic.code ?? "none",
                    path: item?.diagnostic.path ?? "", entityID: item?.diagnostic.entityID,
                    candidateCount: item?.choices.count ?? 0, candidateIDs: item?.choices.map(\.id) ?? [],
                    candidateSemantics: item?.choices.map(\.affectedSemantic) ?? [],
                    candidateLossClasses: item?.choices.map { $0.lossClass.rawValue } ?? [],
                    affectedPaths: item?.choices.flatMap(\.affectedPaths) ?? [],
                    chosenCandidate: resolution.decisions.first { $0.diagnosticIdentity == item?.identity }?.selectedCandidateID,
                    sourceBound: true, classificationBefore: analysis.classification?.rawValue ?? "none",
                    classificationAfter: result.classification.rawValue, lossVisible: !result.losses.isEmpty,
                    remainingUnresolved: result.unresolved.count, candidateProduced: result.candidate != nil,
                    currentV2Valid: valid, deterministic: deterministic, losses: result.losses,
                    staleResolutionRejected: staleRejected))
            }
            if name == "M" {
                XCTAssertEqual(analysis.classification, .losslessWithNormalization)
                XCTAssertTrue(analysis.automaticCandidateEligible)
                XCTAssertEqual(result.candidate, try MigrationRegistry.transform(MigrationFileSet(files: files)).files.files)
            }
        }
        if let destination = ProcessInfo.processInfo.environment["HAMII_SPIKE_MATRIX_PATH"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var bytes = try encoder.encode(matrix)
            bytes.append(0x0A)
            try bytes.write(to: URL(fileURLWithPath: destination))
        }
    }

    func testNonexistentOrDuplicateChoiceAndPartialResolutionFailClosed() throws {
        let files = try scenario("K")
        let found = try items(files)
        let partial = manifest(files, items: found, selected: ["capability.ambiguousSpacing"])
        XCTAssertNil(try apply(files, manifest: partial).candidate)
        let first = try XCTUnwrap(partial.decisions.first)
        let invalid = ResolutionManifest(sourceOID: partial.sourceOID, sourceCanonicalIdentity: partial.sourceCanonicalIdentity,
            decisions: [Decision(diagnosticIdentity: first.diagnosticIdentity, selectedCandidateID: "injected-json-patch")])
        XCTAssertThrowsError(try apply(files, manifest: invalid))
        let duplicated = ResolutionManifest(sourceOID: partial.sourceOID, sourceCanonicalIdentity: partial.sourceCanonicalIdentity,
            decisions: [first, first])
        XCTAssertThrowsError(try apply(files, manifest: duplicated))
        let wrongOID = ResolutionManifest(sourceOID: "other-source", sourceCanonicalIdentity: partial.sourceCanonicalIdentity,
            decisions: partial.decisions)
        XCTAssertThrowsError(try apply(files, manifest: wrongOID))
    }

    func testAlternativeEnumeratedSpacingChoiceChangesOnlyReviewedSemantics() throws {
        let files = try scenario("A")
        let item = try XCTUnwrap(items(files).first)
        XCTAssertEqual(item.choices.count, 2)
        let second = item.choices[1]
        let resolution = ResolutionManifest(sourceOID: "fixture-source-OID",
            sourceCanonicalIdentity: CanonicalByteIdentity.compute(files: files).rawValue,
            decisions: [Decision(diagnosticIdentity: item.identity, selectedCandidateID: second.id)])
        let result = try apply(files, manifest: resolution)
        let candidate = try XCTUnwrap(result.candidate)
        XCTAssertTrue(try currentValid(candidate))
        XCTAssertEqual(result.classification, .potentiallyLossy)
        XCTAssertEqual(result.losses.count, 1)
        XCTAssertEqual(result.losses[0].path, "hamii.json.capabilityDeclarations[0]")
        let migrated = try object(XCTUnwrap(candidate["hamii.json"]))
        let entries = try XCTUnwrap(migrated["capabilityDeclarations"] as? [Object])
        for key in ["token.spacing", "effect.padding"] {
            let declaration = try XCTUnwrap(entries.first {
                (($0["key"] as? Object)?["rawValue"] as? String) == key
            })
            XCTAssertEqual(declaration["support"] as? String, "portable")
            XCTAssertEqual(declaration["reason"] as? String, "second v1 spacing support")
        }
    }
}
