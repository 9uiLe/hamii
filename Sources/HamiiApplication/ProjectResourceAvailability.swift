import HamiiCore

public struct ComponentAvailabilityItem: Codable, Equatable {
    public let id: EntityID
    public let name: String
    public let ownerScopeID: EntityID
    public let available: Bool
    public let ruleID: String?
    public let blockingComponentID: EntityID?

    public init(_ component: ComponentDefinition, assessment: ComponentAvailabilityAssessment) {
        id = component.id
        name = component.name
        ownerScopeID = component.ownerScopeID
        available = assessment.available
        ruleID = assessment.ruleID
        blockingComponentID = assessment.blockingComponentID
    }
}

/// Pure availability queries over one observed Document.
enum ProjectResourceAvailability {
    private static func assessedComponents(in document: Document, consumer: EntityID)
        -> [(ComponentDefinition, ComponentAvailabilityAssessment)] {
        let scopes = ScopeEvaluator(document.scopes)
        let definitions = Dictionary(document.components.map { ($0.id, $0) },
                                     uniquingKeysWith: { first, _ in first })
        return document.components.map { component in
            (component, ComponentAvailability.assess(component, consumer: consumer,
                scopes: scopes, definitions: definitions))
        }
    }

    static func components(in document: Document, consumer: EntityID) -> [ComponentDefinition] {
        assessedComponents(in: document, consumer: consumer)
            .filter { $0.1.available }.map { $0.0 }
    }

    static func componentAvailability(in document: Document, consumer: EntityID,
                                      includeNonOwned: Bool = true) -> [ComponentAvailabilityItem] {
        let scopes = ScopeEvaluator(document.scopes)
        return assessedComponents(in: document, consumer: consumer)
            .filter { includeNonOwned || scopes.canUse(owner: $0.0.ownerScopeID, consumer: consumer) }
            .map { ComponentAvailabilityItem($0.0, assessment: $0.1) }
    }

    static func tokens(in document: Document, consumer: EntityID, kind: TokenKind? = nil) -> [DesignToken] {
        let scopes = ScopeEvaluator(document.scopes)
        return document.tokens.filter {
            (kind == nil || $0.kind == kind) && scopes.canUse(owner: $0.ownerScopeID, consumer: consumer)
        }
    }

    static func assets(in document: Document, consumer: EntityID) -> [Asset] {
        let scopes = ScopeEvaluator(document.scopes)
        return document.assets.filter { scopes.canUse(owner: $0.ownerScopeID, consumer: consumer) }
    }
}
