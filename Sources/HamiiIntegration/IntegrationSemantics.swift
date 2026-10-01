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
}

public enum SemanticNilBehavior: Codable, Equatable, Sendable {
    case needsResolution
    case hidden
    case literal(String)
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
