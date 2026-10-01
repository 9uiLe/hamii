import Foundation

/// Stable, product-independent names. Product symbols belong in IntegrationProfile.
public struct SemanticSourceKey: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ value: String) { self.rawValue = value }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct SemanticOutputKey: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ value: String) { self.rawValue = value }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum SemanticValueKind: String, Codable, Sendable {
    case text, boolean, date, number, image
}

public struct SemanticSource: Codable, Equatable, Sendable {
    public var key: SemanticSourceKey
    public var valueKind: SemanticValueKind
    public init(key: SemanticSourceKey, valueKind: SemanticValueKind) {
        self.key = key
        self.valueKind = valueKind
    }
}

public enum SemanticVisibility: Codable, Equatable, Sendable {
    case always
    case booleanEquals(source: SemanticSourceKey, value: Bool)

    public var source: SemanticSourceKey? {
        if case .booleanEquals(let source, _) = self { return source }
        return nil
    }

    private enum CodingKeys: String, CodingKey { case kind, source, value }
    private enum Kind: String, Codable { case always, booleanEquals }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .always: self = .always
        case .booleanEquals:
            self = .booleanEquals(source: try values.decode(SemanticSourceKey.self, forKey: .source),
                                  value: try values.decode(Bool.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .always:
            try values.encode(Kind.always, forKey: .kind)
        case .booleanEquals(let source, let value):
            try values.encode(Kind.booleanEquals, forKey: .kind)
            try values.encode(source, forKey: .source)
            try values.encode(value, forKey: .value)
        }
    }
}

public enum SemanticNilBehavior: Codable, Equatable, Sendable {
    case needsResolution
    case hidden
    case literal(String)

    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable { case needsResolution, hidden, literal }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .needsResolution: self = .needsResolution
        case .hidden: self = .hidden
        case .literal: self = .literal(try values.decode(String.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .needsResolution: try values.encode(Kind.needsResolution, forKey: .kind)
        case .hidden: try values.encode(Kind.hidden, forKey: .kind)
        case .literal(let literal):
            try values.encode(Kind.literal, forKey: .kind)
            try values.encode(literal, forKey: .value)
        }
    }
}

public struct SemanticTransformKey: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ value: String) { self.rawValue = value }
    public static let identity = Self("identity")

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct SemanticRelation: Codable, Equatable, Sendable {
    public var output: SemanticOutputKey
    public var source: SemanticSourceKey
    public var visibleWhen: SemanticVisibility
    public var whenNil: SemanticNilBehavior
    public var transform: SemanticTransformKey

    public init(output: SemanticOutputKey, source: SemanticSourceKey,
                visibleWhen: SemanticVisibility = .always,
                whenNil: SemanticNilBehavior = .needsResolution,
                transform: SemanticTransformKey = .identity) {
        self.output = output
        self.source = source
        self.visibleWhen = visibleWhen
        self.whenNil = whenNil
        self.transform = transform
    }

    public var dependencies: Set<SemanticSourceKey> {
        var result: Set<SemanticSourceKey> = [source]
        if let visibilitySource = visibleWhen.source { result.insert(visibilitySource) }
        return result
    }
}

/// A path step identifies one Component instance occurrence in its owning
/// Screen or raw Component definition. Repeated instances remain distinct.
public struct SemanticOccurrenceFrame: Codable, Hashable, Sendable {
    public var instanceLayerID: EntityID
    public var expectedDefinitionID: EntityID
    public var layerPath: [EntityID]

    public init(instanceLayerID: EntityID, expectedDefinitionID: EntityID, layerPath: [EntityID]) {
        self.instanceLayerID = instanceLayerID
        self.expectedDefinitionID = expectedDefinitionID
        self.layerPath = layerPath
    }
}

public enum SemanticOutputProperty: String, Codable, Hashable, Sendable {
    case text
}

/// Anchors are about physical hamii UI outputs, never Product symbols.
public enum SemanticOutputAnchor: Codable, Hashable, Sendable {
    case direct(layerID: EntityID, property: SemanticOutputProperty)
    case component(path: [SemanticOccurrenceFrame], layerID: EntityID, property: SemanticOutputProperty)

    private enum CodingKeys: String, CodingKey { case kind, path, layerID, property }
    private enum Kind: String, Codable { case direct, component }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .direct:
            self = .direct(layerID: try values.decode(EntityID.self, forKey: .layerID),
                           property: try values.decode(SemanticOutputProperty.self, forKey: .property))
        case .component:
            self = .component(path: try values.decode([SemanticOccurrenceFrame].self, forKey: .path),
                              layerID: try values.decode(EntityID.self, forKey: .layerID),
                              property: try values.decode(SemanticOutputProperty.self, forKey: .property))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .direct(let layerID, let property):
            try values.encode(Kind.direct, forKey: .kind)
            try values.encode(layerID, forKey: .layerID)
            try values.encode(property, forKey: .property)
        case .component(let path, let layerID, let property):
            try values.encode(Kind.component, forKey: .kind)
            try values.encode(path, forKey: .path)
            try values.encode(layerID, forKey: .layerID)
            try values.encode(property, forKey: .property)
        }
    }
}

public struct SemanticOutput: Codable, Equatable, Sendable {
    public var key: SemanticOutputKey
    public var anchor: SemanticOutputAnchor
    public var binding: String

    public init(key: SemanticOutputKey, anchor: SemanticOutputAnchor, binding: String) {
        self.key = key
        self.anchor = anchor
        self.binding = binding
    }
}

public struct ScreenSemantics: Codable, Equatable, Sendable {
    public var sources: [SemanticSource]
    public var outputs: [SemanticOutput]
    public var relations: [SemanticRelation]

    public init(sources: [SemanticSource] = [], outputs: [SemanticOutput] = [], relations: [SemanticRelation] = []) {
        self.sources = sources
        self.outputs = outputs
        self.relations = relations
    }
}
