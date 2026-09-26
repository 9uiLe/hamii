import HamiiCore

struct IndexedComponent {
    let id: EntityID
    let name: String
    let ownerScopeID: EntityID
    let usageCount: Int
}

/// The query rows derived from one validated Canonical Document.
struct IndexProjection {
    let components: [IndexedComponent]
    let scopeClosure: [(consumer: EntityID, ancestor: EntityID)]
    let availability: [(consumer: EntityID, component: EntityID)]

    init(document: Document) {
        let scopes = ScopeEvaluator(document.scopes)
        let definitions = Dictionary(document.components.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var usageCounts: [EntityID: Int] = [:]
        for screen in document.screens {
            Self.collectUsage(in: screen.root, counts: &usageCounts)
        }
        components = document.components.map {
            IndexedComponent(id: $0.id, name: $0.name, ownerScopeID: $0.ownerScopeID, usageCount: usageCounts[$0.id, default: 0])
        }
        scopeClosure = document.scopes.flatMap { scope in
            (scopes.ancestorsIncludingSelf(of: scope.id) ?? []).map { (consumer: scope.id, ancestor: $0) }
        }
        availability = document.components.flatMap { component in
            document.scopes.compactMap { scope in
                ComponentAvailability.reason(component, consumer: scope.id, scopes: scopes, definitions: definitions) == nil
                    ? (consumer: scope.id, component: component.id) : nil
            }
        }
    }

    private static func collectUsage(in layer: Layer, counts: inout [EntityID: Int]) {
        if let id = layer.component?.definitionID { counts[id, default: 0] += 1 }
        for child in layer.children { collectUsage(in: child, counts: &counts) }
    }
}
