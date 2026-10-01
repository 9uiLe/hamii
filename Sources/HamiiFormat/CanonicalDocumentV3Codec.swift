import Foundation
import HamiiCore

/// An isolated candidate codec. The installed CanonicalRepository remains v2
/// until the reviewed v3 publication path and Current-format cutover are ready.
package enum CanonicalDocumentV3Codec {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case invalid(String)

        var description: String {
            switch self { case .invalid(let detail): "Invalid Canonical v3: \(detail)" }
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
        guard document.screens.allSatisfy({ $0.semantics != nil }) else {
            throw Failure.invalid("each Screen requires semantics")
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

    package static func decode(files: [String: Data]) throws -> Document {
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
        let manifest: Manifest = try strictDecode(Manifest.self, bytes: manifestBytes, path: "hamii.json")
        guard manifest.formatVersion == 3, manifest.versions.document == 3,
              manifest.versions.authoringHarness == 1 else {
            throw Failure.invalid("manifest formatVersion, versions.document, and authoringHarness must be 3, 3, and 1")
        }
        if let profiles = files["hamii-agent-profiles.json"] {
            _ = try AgentProfilesRepository.decodeProfiles(from: profiles)
        }
        var document = Document(name: manifest.name)
        document.id = manifest.id
        document.revision = manifest.revision
        document.versions = manifest.versions
        document.authoringHarness = manifest.authoringHarness
        document.capabilityDeclarations = manifest.capabilityDeclarations
        document.tokenTemplate = manifest.tokenTemplate
        document.pages = try decodeAll(Page.self, folder: "pages", files: files)
        document.screens = try decodeAll(Screen.self, folder: "screens", files: files)
        document.scopes = try decodeAll(ArchitectureScope.self, folder: "scopes", files: files)
        document.components = try decodeAll(ComponentDefinition.self, folder: "components", files: files)
        document.tokens = try decodeAll(DesignToken.self, folder: "tokens", files: files)
        document.assets = try decodeAll(Asset.self, folder: "assets", files: files)
        document.interactions = try decodeAll(Interaction.self, folder: "interactions", files: files)
        document.motions = try decodeAll(Motion.self, folder: "motions", files: files)
        document.fixtures = try decodeAll(PreviewFixture.self, folder: "fixtures", files: files)
        document.targets = try decodeAll(Target.self, folder: "targets", files: files)
        guard document.screens.allSatisfy({ $0.semantics != nil }) else {
            throw Failure.invalid("each Screen requires semantics")
        }
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
                throw Failure.invalid("filename does not match stable ID: \(path)")
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
