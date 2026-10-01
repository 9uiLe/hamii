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

        let allowed: Set<String> = [
            "formatVersion", "repositoryName", "architectureRules", "componentMappings",
            "tokenMappings", "assetMappings", "routingMappings", "stateMappings",
            "nativeMappings", "codeModificationPolicy"
        ]
        guard Set(object.keys).isSubset(of: allowed) else {
            throw IntegrationProfileFileError.invalid("Unknown profile field")
        }
        let decoder = JSONDecoder()
        let header: Header
        do { header = try decoder.decode(Header.self, from: data) }
        catch { throw IntegrationProfileFileError.invalid("Missing or invalid formatVersion") }
        guard header.formatVersion == 1 else {
            throw IntegrationProfileFileError.unsupportedVersion(header.formatVersion)
        }
        let profile: IntegrationProfile
        do { profile = try decoder.decode(IntegrationProfile.self, from: data) }
        catch { throw IntegrationProfileFileError.invalid("Malformed v1 profile") }
        guard !profile.repositoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IntegrationProfileFileError.invalid("Empty repositoryName")
        }
        let keys = Array(profile.routingMappings.keys) + Array(profile.stateMappings.keys) + Array(profile.nativeMappings.keys) +
            profile.componentMappings.keys.map(\.rawValue) + profile.tokenMappings.keys.map(\.rawValue) +
            profile.assetMappings.keys.map(\.rawValue)
        guard keys.allSatisfy(validMappingKey) else {
            throw IntegrationProfileFileError.invalid("Invalid mapping key")
        }
        return profile
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
