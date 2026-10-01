import Foundation
import HamiiCore

/// The strict Current Canonical Document Format codec.
package enum CanonicalDocumentV3Codec {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case invalid(String)
        case filenameMismatch(String)

        var description: String {
            switch self {
            case .invalid(let detail): "Invalid Canonical v3: \(detail)"
            case .filenameMismatch(let path): "Canonical file name does not match stable ID: \(path)"
            }
        }
    }

    private struct Manifest: Codable {
        var formatVersion: Int
        var id: EntityID
        var name: String
        var revision: Int
        var versions: FormatVersions
        var authoringHarness: AuthoringHarness
        var capabilityDeclarations: [CapabilityDeclaration]
        var tokenTemplate: TokenTemplateProvenance?
    }

    private static let folders: Set<String> = [
        "pages", "screens", "scopes", "components", "tokens", "assets",
        "interactions", "motions", "fixtures", "targets"
    ]

    static func encode(document: Document) throws -> [String: Data] {
        guard document.versions.document == 3, document.versions.authoringHarness == 1 else {
            throw Failure.invalid("document and authoringHarness versions must be 3 and 1")
        }
        var files: [String: Data] = [:]
        try add(document.pages, folder: "pages", to: &files)
        try add(document.screens, folder: "screens", to: &files)
        try add(document.scopes, folder: "scopes", to: &files)
        try add(document.components, folder: "components", to: &files)
        try add(document.tokens, folder: "tokens", to: &files)
        try add(document.assets, folder: "assets", to: &files)
        try add(document.interactions, folder: "interactions", to: &files)
        try add(document.motions, folder: "motions", to: &files)
        try add(document.fixtures, folder: "fixtures", to: &files)
        try add(document.targets, folder: "targets", to: &files)
        files["hamii.json"] = try bytes(Manifest(formatVersion: 3, id: document.id,
            name: document.name, revision: document.revision, versions: document.versions,
            authoringHarness: document.authoringHarness,
            capabilityDeclarations: document.capabilityDeclarations,
            tokenTemplate: document.tokenTemplate))
        return files
    }

    package static func decode(
        files: [String: Data],
        onManifestDecoded: ((Double) -> Void)? = nil,
        onFolderDecoded: ((String, Double) -> Void)? = nil,
        onProfilesValidated: ((Double) -> Void)? = nil
    ) throws -> Document {
        guard let manifestBytes = files["hamii.json"] else {
            throw Failure.invalid("missing hamii.json")
        }
        for path in files.keys {
            if path == "hamii.json" || path == "hamii-agent-profiles.json" { continue }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, folders.contains(String(parts[0])),
                  parts[1].hasSuffix(".json") else {
                throw Failure.invalid("unexpected Canonical path: \(path)")
            }
        }
        let manifestStart = ProcessInfo.processInfo.systemUptime
        let manifest: Manifest = try strictDecode(Manifest.self, bytes: manifestBytes, path: "hamii.json")
        onManifestDecoded?((ProcessInfo.processInfo.systemUptime - manifestStart) * 1_000)
        guard manifest.formatVersion == 3, manifest.versions.document == 3,
              manifest.versions.authoringHarness == 1 else {
            throw Failure.invalid("manifest formatVersion, versions.document, and authoringHarness must be 3, 3, and 1")
        }
        if let profiles = files["hamii-agent-profiles.json"] {
            let profilesStart = ProcessInfo.processInfo.systemUptime
            _ = try AgentProfilesRepository.decodeProfiles(from: profiles)
            onProfilesValidated?((ProcessInfo.processInfo.systemUptime - profilesStart) * 1_000)
        }
        var document = Document(name: manifest.name)
        document.id = manifest.id
        document.revision = manifest.revision
        document.versions = manifest.versions
        document.authoringHarness = manifest.authoringHarness
        document.capabilityDeclarations = manifest.capabilityDeclarations
        document.tokenTemplate = manifest.tokenTemplate
        func decodeFolder<T: Codable & Identifiable>(_ type: T.Type, _ folder: String) throws -> [T] where T.ID == EntityID {
            let started = ProcessInfo.processInfo.systemUptime
            let values = try decodeAll(type, folder: folder, files: files)
            onFolderDecoded?(folder, (ProcessInfo.processInfo.systemUptime - started) * 1_000)
            return values
        }
        document.pages = try decodeFolder(Page.self, "pages")
        document.screens = try decodeFolder(Screen.self, "screens")
        document.scopes = try decodeFolder(ArchitectureScope.self, "scopes")
        document.components = try decodeFolder(ComponentDefinition.self, "components")
        document.tokens = try decodeFolder(DesignToken.self, "tokens")
        document.assets = try decodeFolder(Asset.self, "assets")
        document.interactions = try decodeFolder(Interaction.self, "interactions")
        document.motions = try decodeFolder(Motion.self, "motions")
        document.fixtures = try decodeFolder(PreviewFixture.self, "fixtures")
        document.targets = try decodeFolder(Target.self, "targets")
        return document
    }

    private static func add<T: Encodable & Identifiable>(_ values: [T], folder: String,
                                                        to files: inout [String: Data]) throws where T.ID == EntityID {
        for value in values {
            guard value.id.rawValue.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil else {
                throw Failure.invalid("unsafe stable ID: \(value.id.rawValue)")
            }
            let path = "\(folder)/\(value.id.rawValue).json"
            guard files[path] == nil else { throw Failure.invalid("duplicate Canonical path: \(path)") }
            files[path] = try bytes(value)
        }
    }

    private static func decodeAll<T: Decodable & Encodable & Identifiable>(_ type: T.Type,
        folder: String, files: [String: Data]) throws -> [T] where T.ID == EntityID {
        try files.keys.filter { $0.hasPrefix(folder + "/") }.sorted().map { path in
            guard let bytes = files[path] else { throw Failure.invalid("missing \(path)") }
            let value: T = try strictDecode(T.self, bytes: bytes, path: path)
            guard path == "\(folder)/\(value.id.rawValue).json" else {
                throw Failure.filenameMismatch(path)
            }
            return value
        }
    }

    /// Structural round-trip rejects unknown or omitted nested keys, including
    /// enum payload fields. JSON whitespace and object key order remain free.
    private static func strictDecode<T: Codable>(_ type: T.Type, bytes: Data, path: String) throws -> T {
        let value = try JSONDecoder().decode(T.self, from: bytes)
        let original = try JSONSerialization.jsonObject(with: bytes)
        let normalized = try JSONSerialization.jsonObject(with: self.bytes(value))
        guard let original = original as? [String: Any], let normalized = normalized as? [String: Any],
              NSDictionary(dictionary: original).isEqual(to: normalized) else {
            throw Failure.invalid("unknown, missing, or noncanonical nested field in \(path)")
        }
        return value
    }

    private static func bytes<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        var bytes = try encoder.encode(value)
        bytes.append(0x0A)
        return bytes
    }
}
