import Foundation
import HamiiCore

public enum IntegrationProfileFileError: Error, Equatable, CustomStringConvertible {
    case unreadable
    case unsupportedVersion(Int)
    case invalid(String)

    public var description: String {
        switch self {
        case .unreadable: "Integration profile file cannot be read"
        case .unsupportedVersion(let version): "Unsupported integration profile format version \(version)"
        case .invalid(let reason): "Invalid integration profile: \(reason)"
        }
    }
}

/// A read-only, caller-selected file. This path is not a hamii Canonical shard.
public enum IntegrationProfileFile {
    private struct Header: Decodable { let formatVersion: Int }

    public static func requireDocumentVersion(_ version: Int) throws {
        guard version == 1 else { throw IntegrationProfileFileError.unsupportedVersion(version) }
    }

    public static func load(at url: URL) throws -> IntegrationProfile {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw IntegrationProfileFileError.unreadable }

        return try decode(data: data)
    }

    public static func loadV2(at url: URL) throws -> IntegrationProfileV2 {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw IntegrationProfileFileError.unreadable }
        return try decodeV2(data: data)
    }

    public static func decodeVersioned(data: Data) throws -> IntegrationProfileDocument {
        let version = try profileVersion(data)
        switch version {
        case 1: return .v1(try decode(data: data))
        case 2: return .v2(try decodeV2(data: data))
        default: throw IntegrationProfileFileError.unsupportedVersion(version)
        }
    }

    /// Validate already captured Profile bytes without reading a mutable path again.
    public static func decode(data: Data) throws -> IntegrationProfile {
        let object = try validatedObject(data)
        let version = try profileVersion(data)
        guard version == 1 else { throw IntegrationProfileFileError.unsupportedVersion(version) }
        let allowed: Set<String> = [
            "formatVersion", "repositoryName", "architectureRules", "componentMappings",
            "tokenMappings", "assetMappings", "routingMappings", "stateMappings",
            "nativeMappings", "codeModificationPolicy"
        ]
        guard Set(object.keys).isSubset(of: allowed) else {
            throw IntegrationProfileFileError.invalid("Unknown profile field")
        }
        let profile: IntegrationProfile
        do { profile = try JSONDecoder().decode(IntegrationProfile.self, from: data) }
        catch { throw IntegrationProfileFileError.invalid("Malformed v1 profile") }
        try validateStructuralFields(profile.repositoryName, routing: profile.routingMappings,
            state: profile.stateMappings, native: profile.nativeMappings,
            component: profile.componentMappings, token: profile.tokenMappings, asset: profile.assetMappings)
        return profile
    }

    /// A separate format boundary: v1 strings remain structural-only and are
    /// never inferred to be v2 source locators. A well-typed locator with a
    /// malformed target, or a key also present in a structural map, is kept
    /// for Runtime's per-mapping failure classification.
    public static func decodeV2(data: Data) throws -> IntegrationProfileV2 {
        let object = try validatedObject(data)
        let version = try profileVersion(data)
        guard version == 2 else { throw IntegrationProfileFileError.unsupportedVersion(version) }
        let allowed: Set<String> = [
            "formatVersion", "repositoryName", "architectureRules", "componentMappings",
            "tokenMappings", "assetMappings", "routingMappings", "stateMappings",
            "nativeMappings", "codeModificationPolicy", "sourceLocators"
        ]
        guard Set(object.keys).isSubset(of: allowed) else {
            throw IntegrationProfileFileError.invalid("Unknown profile field")
        }
        guard let locators = object["sourceLocators"] as? [String: Any] else {
            throw IntegrationProfileFileError.invalid("Missing or invalid sourceLocators")
        }
        let locatorFields: Set<String> = [
            "kind", "path", "enclosingKind", "enclosingName", "memberKind", "memberName"
        ]
        for (key, value) in locators {
            guard validLocatorKey(key) else {
                throw IntegrationProfileFileError.invalid("Invalid source locator key")
            }
            guard let fields = value as? [String: Any], Set(fields.keys) == locatorFields else {
                throw IntegrationProfileFileError.invalid("Invalid source locator fields")
            }
        }
        let profile: IntegrationProfileV2
        do { profile = try JSONDecoder().decode(IntegrationProfileV2.self, from: data) }
        catch { throw IntegrationProfileFileError.invalid("Malformed v2 profile") }
        try validateStructuralFields(profile.repositoryName, routing: profile.routingMappings,
            state: profile.stateMappings, native: profile.nativeMappings,
            component: profile.componentMappings, token: profile.tokenMappings, asset: profile.assetMappings)
        return profile
    }

    private static func profileVersion(_ data: Data) throws -> Int {
        do { return try JSONDecoder().decode(Header.self, from: data).formatVersion }
        catch { throw IntegrationProfileFileError.invalid("Missing or invalid formatVersion") }
    }

    private static func validatedObject(_ data: Data) throws -> [String: Any] {
        let object: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw IntegrationProfileFileError.invalid("Expected a JSON object")
            }
            object = parsed
        } catch let error as IntegrationProfileFileError { throw error }
        catch { throw IntegrationProfileFileError.invalid("Malformed JSON") }

        // Foundation decoders keep only one value for duplicate object keys. A profile
        // must never turn conflicting assertions into a seemingly resolved plan.
        try UniqueJSONKeys.validate(data)
        for field in ["componentMappings", "tokenMappings", "assetMappings"] {
            guard let entries = object[field] as? [Any] else { continue } // decoder diagnoses shape
            var seen = Set<String>()
            for offset in stride(from: 0, to: entries.count, by: 2) {
                guard let key = entries[offset] as? [String: Any],
                      let rawValue = key["rawValue"] as? String else { continue }
                guard seen.insert(rawValue).inserted else {
                    throw IntegrationProfileFileError.invalid("Duplicate \(field) key")
                }
            }
        }

        return object
    }

    private static func validateStructuralFields(_ repositoryName: String,
                                                  routing: [String: String], state: [String: String],
                                                  native: [String: String], component: [EntityID: String],
                                                  token: [EntityID: String], asset: [EntityID: String]) throws {
        guard !repositoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IntegrationProfileFileError.invalid("Empty repositoryName")
        }
        let keys = Array(routing.keys) + Array(state.keys) + Array(native.keys) +
            component.keys.map(\.rawValue) + token.keys.map(\.rawValue) + asset.keys.map(\.rawValue)
        guard keys.allSatisfy(validMappingKey) else {
            throw IntegrationProfileFileError.invalid("Invalid mapping key")
        }
    }

    private static func validLocatorKey(_ key: String) -> Bool {
        guard let separator = key.firstIndex(of: ":") else { return false }
        let kind = String(key[..<separator])
        let semanticID = String(key[key.index(after: separator)...])
        return IntegrationMappingKind(rawValue: kind) != nil && validMappingKey(semanticID)
    }

    private static func validMappingKey(_ key: String) -> Bool {
        !key.isEmpty && key == key.trimmingCharacters(in: .whitespacesAndNewlines) &&
            !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

/// Detects duplicate keys before JSONDecoder's keyed containers discard them.
/// JSONSerialization above remains responsible for full JSON syntax validation.
private struct UniqueJSONKeys {
    private let bytes: [UInt8]
    private var offset = 0

    private init(_ data: Data) { bytes = Array(data) }

    static func validate(_ data: Data) throws {
        var scanner = UniqueJSONKeys(data)
        try scanner.value(depth: 0)
    }

    private mutating func value(depth: Int) throws {
        guard depth < 128 else { throw IntegrationProfileFileError.invalid("JSON nesting too deep") }
        whitespace()
        guard offset < bytes.count else { throw IntegrationProfileFileError.invalid("Malformed JSON") }
        switch bytes[offset] {
        case 123: // {
            offset += 1
            whitespace()
            var keys = Set<String>()
            if take(125) { return } // }
            while true {
                let key = try JSONDecoder().decode(String.self, from: stringToken())
                guard keys.insert(key).inserted else {
                    throw IntegrationProfileFileError.invalid("Duplicate JSON key")
                }
                whitespace()
                guard take(58) else { throw IntegrationProfileFileError.invalid("Malformed JSON") } // :
                try value(depth: depth + 1)
                whitespace()
                if take(125) { return }
                guard take(44) else { throw IntegrationProfileFileError.invalid("Malformed JSON") } // ,
                whitespace()
            }
        case 91: // [
            offset += 1
            whitespace()
            if take(93) { return } // ]
            while true {
                try value(depth: depth + 1)
                whitespace()
                if take(93) { return }
                guard take(44) else { throw IntegrationProfileFileError.invalid("Malformed JSON") }
            }
        case 34: // string value
            _ = try stringToken()
        default:
            while offset < bytes.count && ![UInt8(44), 93, 125, 32, 9, 10, 13].contains(bytes[offset]) {
                offset += 1
            }
        }
    }

    private mutating func stringToken() throws -> Data {
        whitespace()
        guard take(34) else { throw IntegrationProfileFileError.invalid("Malformed JSON") }
        let start = offset - 1
        while offset < bytes.count {
            let byte = bytes[offset]
            offset += 1
            if byte == 92 { offset += 1; continue } // escaped next byte
            if byte == 34 {
                return Data(bytes[start..<offset])
            }
        }
        throw IntegrationProfileFileError.invalid("Malformed JSON")
    }

    private mutating func whitespace() {
        while offset < bytes.count && [UInt8(32), 9, 10, 13].contains(bytes[offset]) { offset += 1 }
    }

    private mutating func take(_ byte: UInt8) -> Bool {
        guard offset < bytes.count && bytes[offset] == byte else { return false }
        offset += 1
        return true
    }
}
