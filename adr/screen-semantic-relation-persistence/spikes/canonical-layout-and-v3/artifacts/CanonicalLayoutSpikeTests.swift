// Test-only prototype. Copy temporarily into Tests/HamiiTests to run; never build into production.
import Foundation
import XCTest
import HamiiCore
import HamiiFormat
import HamiiIntegration
import HamiiMigrations

private struct CandidateOutput: Codable, Equatable {
    var key: SemanticOutputKey
    var layerID: EntityID
    var property: String
    var binding: String
}

private struct CandidateSemantics: Codable, Equatable {
    var sources: [SemanticSource]
    var outputs: [CandidateOutput]
    var relations: [SemanticRelation]
    static let empty = Self(sources: [], outputs: [], relations: [])
}

private struct CandidateScreen: Codable, Equatable {
    var id: EntityID
    var name: String
    var scopeID: EntityID
    var root: Layer
    var navigation: NavigationConfiguration?
    var semantics: CandidateSemantics
}

private struct CandidateSidecar: Codable, Equatable {
    var screenID: EntityID
    var semantics: CandidateSemantics
}

private enum CandidateFailure: Error { case invalid(String), version }

private func validate(_ screen: Screen, _ semantics: CandidateSemantics) throws {
    let groups = Dictionary(grouping: semantics.sources, by: \.key)
    guard groups.allSatisfy({ !$0.key.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.value.count == 1 }) else {
        throw CandidateFailure.invalid("source key")
    }
    let outputGroups = Dictionary(grouping: semantics.outputs, by: \.key)
    guard outputGroups.allSatisfy({ !$0.key.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.value.count == 1 }) else {
        throw CandidateFailure.invalid("output key")
    }
    var anchors = Set<String>()
    func directLayers(_ layer: Layer) -> [Layer] {
        [layer] + layer.children.flatMap(directLayers)
    }
    let layers = directLayers(screen.root)
    for output in semantics.outputs {
        guard output.property == "text", !output.binding.isEmpty,
              anchors.insert("\(output.layerID.rawValue):\(output.property)").inserted else {
            throw CandidateFailure.invalid("output anchor")
        }
        let matches = layers.filter { $0.id == output.layerID }
        guard matches.count == 1, [.text, .button].contains(matches[0].kind),
              matches[0].textBinding == output.binding else {
            throw CandidateFailure.invalid("missing or ambiguous binding anchor")
        }
    }
    let relationGroups = Dictionary(grouping: semantics.relations, by: \.output)
    guard semantics.outputs.allSatisfy({ relationGroups[$0.key]?.count == 1 }) else {
        throw CandidateFailure.invalid("output without one relation")
    }
    for relation in semantics.relations {
        guard outputGroups[relation.output]?.count == 1,
              relationGroups[relation.output]?.count == 1 else {
            throw CandidateFailure.invalid("undeclared or duplicate relation output")
        }
        for source in relation.dependencies {
            guard groups[source]?.count == 1 else {
                throw CandidateFailure.invalid("missing relation dependency")
            }
        }
        if case .booleanEquals(let source, _) = relation.visibleWhen,
           groups[source]?.first?.valueKind != .boolean {
            throw CandidateFailure.invalid("visibility source type")
        }
    }
}

// Prototype of the future IntegrationContracts.make projection, not a production overload.
private func candidateContract(screenID: EntityID, document: Document,
                               semantics: CandidateSemantics) throws -> IntegrationContract {
    guard let screen = document.screens.first(where: { $0.id == screenID }) else {
        throw CandidateFailure.invalid("screen")
    }
    try validate(screen, semantics)
    var contract = try IntegrationContracts.make(screenID: screenID, document: document)
    contract.semanticSources = semantics.sources
    contract.relations = semantics.relations
    return contract
}

final class CanonicalLayoutSpikeTests: XCTestCase {
    private var fixtureRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/format-v1-safe-project")
    }

    private func fixtureFiles() throws -> [String: Data] {
        let root = fixtureRoot
        var files: [String: Data] = [:]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]))
        for case let url as URL in enumerator where !url.hasDirectoryPath {
            files[String(url.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: url)
        }
        return files
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func example() -> (Document, CandidateSemantics) {
        var document = Document(name: "Candidate")
        let text = Layer(id: EntityID("layer_name"), name: "Name",
                         payload: .text(TextLayerPayload(value: "Name", binding: "user.name")))
        let root = Layer(id: EntityID("layer_root"), name: "Root", payload: .stack, children: [text])
        document.screens = [Screen(id: EntityID("screen_profile"), name: "Profile",
                                   scopeID: document.scopes[0].id, root: root)]
        let semantics = CandidateSemantics(
            sources: [.init(key: .init("profile.displayName"), valueKind: .text),
                      .init(key: .init("profile.visible"), valueKind: .boolean)],
            outputs: [.init(key: .init("title"), layerID: text.id, property: "text", binding: "user.name")],
            relations: [.init(output: .init("title"), source: .init("profile.displayName"),
                              visibleWhen: .booleanEquals(source: .init("profile.visible"), value: true),
                              whenNil: .hidden)])
        return (document, semantics)
    }

    func testAnchorValidationAndCompleteContractProjection() throws {
        let (document, base) = example()
        let screen = try XCTUnwrap(document.screens.first)
        XCTAssertNoThrow(try validate(screen, base))
        let contract = try candidateContract(screenID: screen.id, document: document, semantics: base)
        XCTAssertEqual(contract.inputs, ["user.name"])
        XCTAssertEqual(contract.semanticSources, base.sources)
        XCTAssertEqual(contract.relations, base.relations)
        var invalids = [CandidateSemantics]()
        var emptyOutput = base; emptyOutput.outputs[0].key = .init(""); invalids.append(emptyOutput)
        var duplicateOutput = base; duplicateOutput.outputs.append(base.outputs[0]); invalids.append(duplicateOutput)
        var emptySource = base; emptySource.sources[0].key = .init(""); invalids.append(emptySource)
        var duplicateSource = base; duplicateSource.sources.append(base.sources[0]); invalids.append(duplicateSource)
        var missingAnchor = base; missingAnchor.outputs[0].layerID = EntityID("missing"); invalids.append(missingAnchor)
        var wrongBinding = base; wrongBinding.outputs[0].binding = "different"; invalids.append(wrongBinding)
        var duplicateAnchor = base; duplicateAnchor.outputs.append(.init(key: .init("other"), layerID: base.outputs[0].layerID,
                                                                property: "text", binding: "user.name")); invalids.append(duplicateAnchor)
        var undeclared = base; undeclared.relations[0].output = .init("missing"); invalids.append(undeclared)
        var missingSource = base; missingSource.relations[0].source = .init("missing"); invalids.append(missingSource)
        var missingVisibility = base; missingVisibility.relations[0].visibleWhen = .booleanEquals(source: .init("missing"), value: true); invalids.append(missingVisibility)
        var wrongVisibility = base; wrongVisibility.relations[0].visibleWhen = .booleanEquals(source: .init("profile.displayName"), value: true); invalids.append(wrongVisibility)
        var duplicateRelation = base; duplicateRelation.relations.append(base.relations[0]); invalids.append(duplicateRelation)
        var missingRelation = base; missingRelation.relations.removeAll(); invalids.append(missingRelation)
        for (index, candidate) in invalids.enumerated() {
            XCTAssertThrowsError(try validate(screen, candidate), "case \(index)")
        }
        var repeatedLayer = screen
        repeatedLayer.root.children.append(repeatedLayer.root.children[0])
        XCTAssertThrowsError(try validate(repeatedLayer, base), "duplicate Layer ID anchor")
        print("SPIKE anchor invalid cases=\(invalids.count + 1) rejected=\(invalids.count + 1)")
    }

    func testBothCandidateLayoutsRoundTripAndChangeIdentity() throws {
        let (document, base) = example()
        let screen = document.screens[0]
        let a = CandidateScreen(id: screen.id, name: screen.name, scopeID: screen.scopeID,
                                root: screen.root, navigation: screen.navigation, semantics: base)
        let b = CandidateSidecar(screenID: screen.id, semantics: base)
        let encodedA = try encode(a)
        let encodedB = try encode(b)
        XCTAssertEqual(try encode(JSONDecoder().decode(CandidateScreen.self, from: encodedA)), encodedA)
        XCTAssertEqual(try encode(JSONDecoder().decode(CandidateSidecar.self, from: encodedB)), encodedB)
        XCTAssertNotEqual(try encode(JSONDecoder().decode(Screen.self, from: encodedA)), encodedA)
        var changed = base
        changed.relations[0].whenNil = .literal("Unknown")
        let aChanged = CandidateScreen(id: a.id, name: a.name, scopeID: a.scopeID,
                                       root: a.root, navigation: a.navigation, semantics: changed)
        let bChanged = CandidateSidecar(screenID: b.screenID, semantics: changed)
        let screenPath = "screens/\(screen.id.rawValue).json"
        let sidecarPath = "integration/screens/\(screen.id.rawValue).json"
        let aFirst = CanonicalByteIdentity.compute(files: [screenPath: encodedA])
        let aNext = CanonicalByteIdentity.compute(files: [screenPath: try encode(aChanged)])
        let bFirst = CanonicalByteIdentity.compute(files: [sidecarPath: encodedB])
        let bNext = CanonicalByteIdentity.compute(files: [sidecarPath: try encode(bChanged)])
        XCTAssertNotEqual(aFirst, aNext)
        XCTAssertNotEqual(bFirst, bNext)
        XCTAssertFalse(String(decoding: encodedA + encodedB, as: UTF8.self).contains("Profile.nickname"))
        print("SPIKE roundtrip layouts=2 identityChanges=2 v2ScreenDropsUnknownSemantics=1")
    }

    func testCurrentV2ReaderRejectsV3AndCandidateV3ReaderRejectsV2() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CanonicalRepository(root: root)
        _ = try repository.create(name: "Version gate")
        let manifestURL = root.appendingPathComponent("hamii.json")
        let original = try Data(contentsOf: manifestURL)
        func candidateV3Header(_ data: Data) throws {
            let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let versions = try XCTUnwrap(manifest["versions"] as? [String: Any])
            guard manifest["formatVersion"] as? Int == 3,
                  versions["document"] as? Int == 3 else { throw CandidateFailure.version }
        }
        XCTAssertThrowsError(try candidateV3Header(original))
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var versions = try XCTUnwrap(manifest["versions"] as? [String: Any])
        manifest["formatVersion"] = 3; versions["document"] = 3; manifest["versions"] = versions
        let v3 = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try v3.write(to: manifestURL)
        XCTAssertNoThrow(try candidateV3Header(v3))
        XCTAssertThrowsError(try repository.load()) { error in
            guard case .unsupportedFormat(3) = error as? CanonicalError else {
                return XCTFail("Expected unsupportedFormat(3), got \(error)")
            }
        }
        print("SPIKE readerV2RejectsV3=1 candidateV3RejectsV2=1")
    }

    func testUnregisteredSidecarIsInvisibleToCurrentObservation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CanonicalRepository(root: root)
        _ = try repository.create(name: "Sidecar boundary")
        let before = try repository.withCoordinatedSnapshot { $0.identity }
        let beforeClient = try repository.observe().statePrecondition
        let sidecar = root.appendingPathComponent("integration/screens/example.json")
        try FileManager.default.createDirectory(at: sidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"screenID":{"rawValue":"example"},"semantics":{"sources":[],"outputs":[],"relations":[]}}"#.utf8).write(to: sidecar)
        XCTAssertEqual(try repository.withCoordinatedSnapshot { $0.identity }, before)
        XCTAssertEqual(try repository.observe().statePrecondition, beforeClient)
        print("SPIKE currentSidecarObservedBySnapshot=0 currentSidecarInvalidatesClient=0")
    }

    func testInstalledV1V2EdgeComposesWithTestOnlyV2V3Candidate() throws {
        var source = try fixtureFiles()
        source["assets/blobs/sha256/example"] = Data([0, 1, 2, 255])
        let v2 = try MigrationRegistry.transform(MigrationFileSet(files: source))
        XCTAssertEqual(v2.edgePath, ["1->2"])
        func toV3(_ files: [String: Data]) throws -> [String: Data] {
            var transformed = files
            var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(files["hamii.json"])) as? [String: Any])
            var versions = try XCTUnwrap(manifest["versions"] as? [String: Any])
            guard manifest["formatVersion"] as? Int == 2, versions["document"] as? Int == 2 else {
                throw CandidateFailure.version
            }
            manifest["formatVersion"] = 3; versions["document"] = 3; manifest["versions"] = versions
            transformed["hamii.json"] = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            for (path, bytes) in files where path.hasPrefix("screens/") {
                var screen = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                screen["semantics"] = ["sources": [], "outputs": [], "relations": []]
                transformed[path] = try JSONSerialization.data(withJSONObject: screen, options: [.sortedKeys])
            }
            return transformed
        }
        let first = try toV3(v2.files.files)
        XCTAssertEqual(first, try toV3(v2.files.files))
        XCTAssertEqual((try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(first["hamii.json"])) as? [String: Any]))["formatVersion"] as? Int, 3)
        for (path, bytes) in v2.files.files where path != "hamii.json" && !path.hasPrefix("screens/") {
            XCTAssertEqual(first[path], bytes, path)
        }
        for (path, bytes) in first where path.hasPrefix("screens/") {
            let screen = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let semantics = try XCTUnwrap(screen["semantics"] as? [String: Any])
            XCTAssertEqual((semantics["relations"] as? [Any])?.count, 0)
            let candidate = try JSONDecoder().decode(CandidateScreen.self, from: bytes)
            XCTAssertEqual(candidate.semantics, .empty)
        }
        let newManifest = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(first["hamii.json"])) as? [String: Any])
        let oldManifest = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(v2.files.files["hamii.json"])) as? [String: Any])
        let newVersions = try XCTUnwrap(newManifest["versions"] as? [String: Int])
        let oldVersions = try XCTUnwrap(oldManifest["versions"] as? [String: Int])
        XCTAssertEqual(newVersions["document"], 3)
        XCTAssertEqual(newVersions["integrationProfile"], oldVersions["integrationProfile"])
        XCTAssertThrowsError(try MigrationRegistry.transform(MigrationFileSet(files: source), to: 3))
        print("SPIKE path=1->2(installed),2->3(test-only); installed1to3=0; unrelatedBytesPreserved=1")
    }
}
