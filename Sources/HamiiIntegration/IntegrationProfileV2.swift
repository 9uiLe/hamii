import Foundation
import HamiiCore

/// The first Product-owned source locator covers only a direct declaration in a
/// top-level Swift nominal. Its meaning is pinned source existence, not build
/// membership or Product behavior.
public enum SwiftNominalKind: String, Codable, Equatable, Sendable {
    case structType = "struct"
    case classType = "class"
    case enumType = "enum"
}

public enum SwiftDirectMemberKind: String, Codable, Equatable, Sendable {
    case storedProperty
    case enumCase
}

public struct SwiftDirectDeclarationLocator: Codable, Equatable, Sendable {
    public let path: String
    public let enclosingKind: SwiftNominalKind
    public let enclosingName: String
    public let memberKind: SwiftDirectMemberKind
    public let memberName: String

    public var kind: String { "swiftDirectDeclaration" }

    public init(path: String, enclosingKind: SwiftNominalKind, enclosingName: String,
                memberKind: SwiftDirectMemberKind, memberName: String) {
        self.path = path
        self.enclosingKind = enclosingKind
        self.enclosingName = enclosingName
        self.memberKind = memberKind
        self.memberName = memberName
    }

    private enum CodingKeys: String, CodingKey {
        case kind, path, enclosingKind, enclosingName, memberKind, memberName
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(String.self, forKey: .kind)
        guard kind == "swiftDirectDeclaration" else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: values,
                debugDescription: "Unsupported source locator kind")
        }
        path = try values.decode(String.self, forKey: .path)
        enclosingKind = try values.decode(SwiftNominalKind.self, forKey: .enclosingKind)
        enclosingName = try values.decode(String.self, forKey: .enclosingName)
        memberKind = try values.decode(SwiftDirectMemberKind.self, forKey: .memberKind)
        memberName = try values.decode(String.self, forKey: .memberName)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        try values.encode(path, forKey: .path)
        try values.encode(enclosingKind, forKey: .enclosingKind)
        try values.encode(enclosingName, forKey: .enclosingName)
        try values.encode(memberKind, forKey: .memberKind)
        try values.encode(memberName, forKey: .memberName)
    }
}

/// Profile v2 preserves the v1 structural fields but adds explicit Product
/// source locators. For a supported mapping key, a locator is the sole source
/// authority; a free string at the same key is a per-mapping conflict. Decoding
/// retains both values so Runtime can report that conflict without losing the
/// other mappings. V1 strings are never promoted to locators.
public struct IntegrationProfileV2: Codable, Equatable {
    public let formatVersion: Int
    public var repositoryName: String
    public var architectureRules: [String]
    public var componentMappings: [EntityID: String]
    public var tokenMappings: [EntityID: String]
    public var assetMappings: [EntityID: String]
    public var routingMappings: [String: String]
    public var stateMappings: [String: String]
    public var nativeMappings: [String: String]
    public var codeModificationPolicy: [String]
    /// Keys are IntegrationMappingKey.identifier values, e.g. input:user.name.
    /// Eligibility for source verification is decided for each mapping at runtime.
    public var sourceLocators: [String: SwiftDirectDeclarationLocator]

    public init(repositoryName: String) {
        formatVersion = 2
        self.repositoryName = repositoryName
        architectureRules = []; componentMappings = [:]; tokenMappings = [:]
        assetMappings = [:]; routingMappings = [:]; stateMappings = [:]; nativeMappings = [:]
        codeModificationPolicy = []; sourceLocators = [:]
    }

    /// Existing Planner's structural input. Runtime must handle v2 locator
    /// authority before planning; this projection never supplies source proof.
    public var structuralProfile: IntegrationProfile {
        var profile = IntegrationProfile(repositoryName: repositoryName)
        profile.architectureRules = architectureRules
        profile.componentMappings = componentMappings
        profile.tokenMappings = tokenMappings
        profile.assetMappings = assetMappings
        profile.routingMappings = routingMappings
        profile.stateMappings = stateMappings
        profile.nativeMappings = nativeMappings
        profile.codeModificationPolicy = codeModificationPolicy
        return profile
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, repositoryName, architectureRules, componentMappings
        case tokenMappings, assetMappings, routingMappings, stateMappings
        case nativeMappings, codeModificationPolicy, sourceLocators
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .formatVersion)
        guard version == 2 else {
            throw DecodingError.dataCorruptedError(forKey: .formatVersion, in: values,
                debugDescription: "Expected Profile format version 2")
        }
        formatVersion = version
        repositoryName = try values.decode(String.self, forKey: .repositoryName)
        architectureRules = try values.decode([String].self, forKey: .architectureRules)
        componentMappings = try values.decode([EntityID: String].self, forKey: .componentMappings)
        tokenMappings = try values.decode([EntityID: String].self, forKey: .tokenMappings)
        assetMappings = try values.decode([EntityID: String].self, forKey: .assetMappings)
        routingMappings = try values.decode([String: String].self, forKey: .routingMappings)
        stateMappings = try values.decode([String: String].self, forKey: .stateMappings)
        nativeMappings = values.contains(.nativeMappings)
            ? try values.decode([String: String].self, forKey: .nativeMappings) : [:]
        codeModificationPolicy = try values.decode([String].self, forKey: .codeModificationPolicy)
        sourceLocators = try values.decode([String: SwiftDirectDeclarationLocator].self, forKey: .sourceLocators)
    }
}

public enum IntegrationProfileDocument: Equatable {
    case v1(IntegrationProfile)
    case v2(IntegrationProfileV2)
}
