import Foundation
import XCTest
import HamiiCore
import HamiiIntegration

final class IntegrationProfileV2Tests: XCTestCase {
    private func fixture() -> IntegrationProfileV2 {
        var profile = IntegrationProfileV2(repositoryName: "Product")
        profile.stateMappings["user.name"] = "Domain.Profile.nickname"
        profile.routingMappings["editProfile"] = "FeatureProfile.ProfileMainAction.tapEditProfile"
        profile.assetMappings[EntityID("asset_avatar")] = "App.Avatar"
        profile.sourceLocators["input:user.name"] = SwiftDirectDeclarationLocator(
            path: "Packages/Domain/Sources/Domain/Entities/Profile.swift",
            enclosingKind: .structType, enclosingName: "Profile",
            memberKind: .storedProperty, memberName: "nickname")
        profile.sourceLocators["event:editProfile"] = SwiftDirectDeclarationLocator(
            path: "Packages/FeatureProfile/Sources/FeatureProfile/Main/ProfileMainStore.swift",
            enclosingKind: .enumType, enclosingName: "ProfileMainAction",
            memberKind: .enumCase, memberName: "tapEditProfile")
        return profile
    }

    private func changed(_ data: Data, _ edit: (inout [String: Any]) -> Void) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        edit(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func testV2RoundTripAndVersionBoundary() throws {
        let profile = fixture()
        let data = try JSONEncoder().encode(profile)
        let decoded = try IntegrationProfileFile.decodeV2(data: data)
        XCTAssertEqual(decoded, profile)
        XCTAssertEqual(decoded.formatVersion, 2)
        XCTAssertEqual(decoded.structuralProfile.formatVersion, 1)
        XCTAssertEqual(decoded.structuralProfile.stateMappings["user.name"], "Domain.Profile.nickname")
        XCTAssertEqual(decoded.structuralProfile.assetMappings[EntityID("asset_avatar")], "App.Avatar")
        // The codec preserves an overlap; Runtime classifies it per mapping as
        // duplicateMappingAuthority rather than linking this string to the locator.
        XCTAssertNotNil(decoded.sourceLocators["input:user.name"])
        guard case .v2(let versioned) = try IntegrationProfileFile.decodeVersioned(data: data) else {
            return XCTFail("Expected v2 Profile")
        }
        XCTAssertEqual(versioned, profile)
        XCTAssertThrowsError(try IntegrationProfileFile.decode(data: data)) {
            XCTAssertEqual($0 as? IntegrationProfileFileError, .unsupportedVersion(2))
        }
        XCTAssertThrowsError(try IntegrationProfileFile.decodeV2(data: JSONEncoder().encode(
            IntegrationProfile(repositoryName: "Product")))) {
            XCTAssertEqual($0 as? IntegrationProfileFileError, .unsupportedVersion(1))
        }
        guard case .v1(let v1) = try IntegrationProfileFile.decodeVersioned(data: JSONEncoder().encode(
            IntegrationProfile(repositoryName: "Product"))) else {
            return XCTFail("Expected v1 Profile")
        }
        XCTAssertEqual(v1.formatVersion, 1)
        XCTAssertNoThrow(try IntegrationProfileFile.requireDocumentVersion(1))
        XCTAssertThrowsError(try IntegrationProfileFile.requireDocumentVersion(2))
    }

    func testV2LocatorJSONIsExplicitAndPartialMappingsAreAllowed() throws {
        var profile = fixture()
        profile.sourceLocators.removeValue(forKey: "event:editProfile")
        let data = try JSONEncoder().encode(profile)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let locators = try XCTUnwrap(object["sourceLocators"] as? [String: [String: Any]])
        let locator = try XCTUnwrap(locators["input:user.name"])
        XCTAssertEqual(locator["kind"] as? String, "swiftDirectDeclaration")
        XCTAssertEqual(locator["enclosingKind"] as? String, "struct")
        XCTAssertEqual(locator["memberKind"] as? String, "storedProperty")
        XCTAssertEqual(Set(locator.keys), ["kind", "path", "enclosingKind", "enclosingName",
            "memberKind", "memberName"])
        XCTAssertEqual(try IntegrationProfileFile.decodeV2(data: data).sourceLocators.count, 1)

        profile.sourceLocators = [:]
        XCTAssertNoThrow(try IntegrationProfileFile.decodeV2(data: JSONEncoder().encode(profile)))

        // The typed locator is sufficient schema input without a parallel
        // structural free string for the same key.
        profile.sourceLocators["input:user.name"] = fixture().sourceLocators["input:user.name"]
        profile.stateMappings.removeValue(forKey: "user.name")
        let typedOnly = try IntegrationProfileFile.decodeV2(data: JSONEncoder().encode(profile))
        XCTAssertNil(typedOnly.stateMappings["user.name"])
        XCTAssertNotNil(typedOnly.sourceLocators["input:user.name"])
    }

    func testV2MalformedLocatorAndKeysFailClosed() throws {
        let data = try JSONEncoder().encode(fixture())
        func alteredLocator(_ edit: (inout [String: Any]) -> Void) throws -> Data {
            try changed(data) { object in
                var locators = object["sourceLocators"] as! [String: [String: Any]]
                var locator = locators["input:user.name"]!
                edit(&locator)
                locators["input:user.name"] = locator
                object["sourceLocators"] = locators
            }
        }
        let invalid = [
            try alteredLocator { $0["kind"] = "untypedString" },
            try alteredLocator { $0["memberKind"] = "method" },
            try alteredLocator { $0["unknown"] = "ignored?" },
            try alteredLocator { $0.removeValue(forKey: "path") }
        ]
        for bytes in invalid {
            XCTAssertThrowsError(try IntegrationProfileFile.decodeV2(data: bytes))
        }
        // Typed but invalid target strings survive decoding so each mapping can
        // receive its own invalidLocator evidence without touching the filesystem.
        for value in ["../Profile.swift", "/tmp/Profile.swift", "A//Profile.swift", "A\\Profile.swift", "A/Profile.json", ""] {
            let bytes = try alteredLocator { $0["path"] = value }
            XCTAssertEqual(try IntegrationProfileFile.decodeV2(data: bytes)
                .sourceLocators["input:user.name"]?.path, value)
        }
        XCTAssertNoThrow(try IntegrationProfileFile.decodeV2(data: alteredLocator {
            $0["memberName"] = ""
        }))
        XCTAssertNoThrow(try IntegrationProfileFile.decodeV2(data: alteredLocator {
            $0["memberKind"] = "enumCase"
        }))
        for key in ["input:", "unknown:user.name", " input:user.name", "user.name", "asset:"] {
            let bytes = try changed(data) { object in
                var locators = object["sourceLocators"] as! [String: Any]
                locators[key] = locators.removeValue(forKey: "input:user.name")
                object["sourceLocators"] = locators
            }
            XCTAssertThrowsError(try IntegrationProfileFile.decodeV2(data: bytes), key)
        }
        let unsupportedClass = try changed(data) { object in
            var locators = object["sourceLocators"] as! [String: Any]
            locators["asset:asset_avatar"] = locators.removeValue(forKey: "input:user.name")
            object["sourceLocators"] = locators
        }
        XCTAssertNotNil(try IntegrationProfileFile.decodeV2(data: unsupportedClass)
            .sourceLocators["asset:asset_avatar"])
        XCTAssertThrowsError(try IntegrationProfileFile.decodeV2(data: changed(data) {
            $0.removeValue(forKey: "sourceLocators")
        }))
        XCTAssertThrowsError(try IntegrationProfileFile.decodeV2(data: changed(data) {
            $0["sourceLocators"] = NSNull()
        }))
        XCTAssertThrowsError(try IntegrationProfileFile.decodeV2(data: changed(data) {
            $0["unknownTopLevel"] = 1
        }))
    }

    func testV1StringsDoNotBecomeTypedLocatorsAndDuplicateJSONKeysFail() throws {
        var v1 = IntegrationProfile(repositoryName: "Product")
        v1.stateMappings["user.name"] = "Profile.nickname"
        let v1Data = try JSONEncoder().encode(v1)
        guard case .v1(let decoded) = try IntegrationProfileFile.decodeVersioned(data: v1Data) else {
            return XCTFail("Expected v1 Profile")
        }
        XCTAssertEqual(decoded.stateMappings["user.name"], "Profile.nickname")
        let illegalV1 = try changed(v1Data) { $0["sourceLocators"] = [:] }
        XCTAssertThrowsError(try IntegrationProfileFile.decode(data: illegalV1))

        let v2Text = try XCTUnwrap(String(data: JSONEncoder().encode(fixture()), encoding: .utf8))
        let duplicate = Data(v2Text.replacingOccurrences(of: "\"kind\":\"swiftDirectDeclaration\"",
            with: "\"kind\":\"swiftDirectDeclaration\",\"kind\":\"swiftDirectDeclaration\"").utf8)
        XCTAssertNotEqual(duplicate, Data(v2Text.utf8))
        XCTAssertThrowsError(try IntegrationProfileFile.decodeV2(data: duplicate)) {
            guard case .invalid = $0 as? IntegrationProfileFileError else {
                return XCTFail("Expected invalid duplicate-key Profile")
            }
        }
    }
}
