import HamiiCore

/// Pure availability queries over one observed Document.
enum ProjectResourceAvailability {
    static func components(in document: Document, consumer: EntityID) -> [ComponentDefinition] {
        let scopes = ScopeEvaluator(document.scopes)
        let definitions = Dictionary(document.components.map { ($0.id, $0) },
                                     uniquingKeysWith: { first, _ in first })
        return document.components.filter {
            ComponentAvailability.reason($0, consumer: consumer, scopes: scopes,
                                         definitions: definitions) == nil
        }
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
