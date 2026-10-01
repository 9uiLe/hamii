import Foundation
import XCTest
import HamiiCore
import HamiiIntegration

final class IntegrationProfileFileTests: XCTestCase {
    private func withProfile(_ data: Data, body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("profile.json")
        try data.write(to: file)
        try body(file)
    }

    private func encodedProfile() throws -> Data {
        let profile = IntegrationProfile(repositoryName: "Product")
        return try JSONEncoder().encode(profile)
    }

    private func changed(_ data: Data, _ edit: (inout [String: Any]) -> Void) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        edit(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func testV1AndLegacyV1WithoutNativeMappingsLoad() throws {
        let data = try encodedProfile()
        try withProfile(data) { file in
            let loaded = try IntegrationProfileFile.load(at: file)
            XCTAssertEqual(loaded.formatVersion, 1)
            XCTAssertEqual(loaded.repositoryName, "Product")
            XCTAssertTrue(loaded.nativeMappings.isEmpty)
        }
        let legacy = try changed(data) { $0.removeValue(forKey: "nativeMappings") }
        try withProfile(legacy) { file in
            XCTAssertEqual(try IntegrationProfileFile.load(at: file).nativeMappings, [:])
        }
        var withEntityMapping = IntegrationProfile(repositoryName: "Product")
        withEntityMapping.assetMappings[EntityID("asset_avatar")] = "Product.Avatar"
        let mappedData = try JSONEncoder().encode(withEntityMapping)
        let mappedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: mappedData) as? [String: Any])
        XCTAssertTrue(mappedObject["assetMappings"] is [Any])
        try withProfile(mappedData) { file in
            XCTAssertEqual(try IntegrationProfileFile.load(at: file).assetMappings,
                           [EntityID("asset_avatar"): "Product.Avatar"])
        }
    }

    func testWrongVersionAndMalformedJSONFailClosed() throws {
        XCTAssertThrowsError(try IntegrationProfileFile.requireDocumentVersion(2)) {
            XCTAssertEqual($0 as? IntegrationProfileFileError, .unsupportedVersion(2))
        }
        XCTAssertNoThrow(try IntegrationProfileFile.requireDocumentVersion(1))
        let unsupported = try changed(encodedProfile()) { $0["formatVersion"] = 2 }
        try withProfile(unsupported) { file in
            XCTAssertThrowsError(try IntegrationProfileFile.load(at: file)) {
                XCTAssertEqual($0 as? IntegrationProfileFileError, .unsupportedVersion(2))
            }
        }
        try withProfile(Data("{bad JSON".utf8)) { file in
            XCTAssertThrowsError(try IntegrationProfileFile.load(at: file))
        }
    }

    func testEmptyNameUnknownFieldAndInvalidMappingKeysFailClosed() throws {
        for modified in [
            try changed(encodedProfile()) { $0["repositoryName"] = " \n " },
            try changed(encodedProfile()) { $0["stateMapings"] = [:] },
            try changed(encodedProfile()) { $0["stateMappings"] = [" ": "Product.name"] },
            try changed(encodedProfile()) { $0["nativeMappings"] = ["navigation.system ": "Product.navigation"] }
        ] {
            try withProfile(modified) { file in
                XCTAssertThrowsError(try IntegrationProfileFile.load(at: file))
            }
        }
    }

    func testWhitespaceValueIsPreservedForPlannerAndNativeIntentNeedsMapping() throws {
        let data = try changed(encodedProfile()) {
            $0["stateMappings"] = ["user.name": " \t "]
            $0["nativeMappings"] = ["navigation.system": "Product.navigation"]
        }
        try withProfile(data) { file in
            let profile = try IntegrationProfileFile.load(at: file)
            XCTAssertEqual(profile.stateMappings["user.name"], " \t ")
            let contract = IntegrationContract(screenID: EntityID("screen"), name: "Screen",
                architectureScopeID: EntityID("scope"), inputs: ["user.name"], events: [],
                tokenIDs: [], assetIDs: [], nativeIntents: ["navigation.system"], accessibilityLabels: [])
            let plan = IntegrationContracts.plan(contract, profile: profile)
            XCTAssertEqual(plan.unresolvedMappings, ["input:user.name"])
            XCTAssertEqual(plan.resolutionIssues.map(\.code), [.emptyMapping])
            var missing = profile
            missing.nativeMappings.removeAll()
            XCTAssertEqual(IntegrationContracts.plan(contract, profile: missing).unresolvedMappings,
                           ["input:user.name", "native:navigation.system"])
            missing.nativeMappings["navigation.system"] = " \n "
            let emptyNative = IntegrationContracts.plan(contract, profile: missing)
            XCTAssertTrue(emptyNative.resolutionIssues.contains(.init(code: .emptyMapping,
                semanticID: "native:navigation.system")))
            var assessments = IntegrationPlanner.assessments(for: contract, profile: profile)
            let native = IntegrationMappingKey(kind: .native, semanticID: "navigation.system")
            assessments.removeAll { $0.key == native }
            assessments.append(.init(key: native, status: .conflicting))
            let conflicted = IntegrationPlanner.plan(contract, assessments: assessments)
            XCTAssertTrue(conflicted.resolutionIssues.contains(.init(code: .conflictingMapping,
                semanticID: "native:navigation.system")))
        }
    }

    func testDuplicateKeysAndExplicitNullFailClosed() throws {
        let encoded = try XCTUnwrap(String(data: encodedProfile(), encoding: .utf8))
        let cases: [(String, String)] = [
            ("\"formatVersion\":1", "\"formatVersion\":1,\"formatVersion\":1"),
            ("\"stateMappings\":{}", "\"stateMappings\":{\"user.name\":\"First\",\"\\u0075ser.name\":\"Second\"}"),
            ("\"nativeMappings\":{}", "\"nativeMappings\":{\"navigation.system\":\"First\",\"navigation.system\":\"Second\"}"),
            ("\"assetMappings\":[]", "\"assetMappings\":[{\"rawValue\":\"asset_avatar\"},\"First\",{\"rawValue\":\"asset_avatar\"},\"Second\"]"),
            ("\"nativeMappings\":{}", "\"nativeMappings\":null")
        ]
        for (original, replacement) in cases {
            XCTAssertTrue(encoded.contains(original), "Missing test field: \(original)")
            let data = Data(encoded.replacingOccurrences(of: original, with: replacement).utf8)
            try withProfile(data) { file in
                XCTAssertThrowsError(try IntegrationProfileFile.load(at: file), replacement) { error in
                    guard case .invalid = error as? IntegrationProfileFileError else {
                        return XCTFail("Expected invalid profile, got \(error)")
                    }
                }
            }
        }
    }
}
