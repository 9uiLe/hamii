import HamiiCore

public struct ContextObservation: Codable, Equatable {
    public let documentID: EntityID
    public let documentRevision: Int
    public let statePrecondition: ClientPrecondition

    public init(_ observed: ProjectObservation) {
        documentID = observed.document.id
        documentRevision = observed.document.revision
        statePrecondition = observed.statePrecondition
    }
}

public struct ContextResponse<Payload: Codable & Equatable>: Codable, Equatable {
    public let contextSchemaVersion: Int
    public let observation: ContextObservation
    public let payload: Payload

    public init(observation: ContextObservation, payload: Payload) {
        contextSchemaVersion = 1
        self.observation = observation
        self.payload = payload
    }
}

public struct ContextSelection: Codable, Equatable {
    public let screenID: EntityID
    public let layerID: EntityID?

    public init(screenID: EntityID, layerID: EntityID? = nil) {
        self.screenID = screenID
        self.layerID = layerID
    }
}

public struct ContextProjectCounts: Codable, Equatable {
    public let pages: Int
    public let screens: Int
    public let scopes: Int
    public let components: Int
    public let tokens: Int
    public let assets: Int
}

public struct ContextScreenSummary: Codable, Equatable {
    public let id: EntityID
    public let name: String
    public let scopeID: EntityID
}

public struct ContextProjectSummary: Codable, Equatable {
    public let documentID: EntityID
    public let documentName: String
    public let documentRevision: Int
    public let counts: ContextProjectCounts
    public let selectedScreen: ContextScreenSummary?
    public let selectedLayerID: EntityID?
}

public struct ContextLayerSummary: Codable, Equatable {
    public let id: EntityID
    public let name: String
    public let kind: LayerKind
    public let text: String?
    public let textBinding: String?
    public let emittedEvent: String?
    public let layoutAxis: LayoutAxis?
    public let spacingTokenID: EntityID?
    public let effects: [LayerEffect]
    public let assetID: EntityID?
    public let componentDefinitionID: EntityID?
    public let interactionID: EntityID?
    public let accessibilityLabel: String?
    public let childCount: Int

    public init(_ layer: Layer) {
        id = layer.id
        name = layer.name
        kind = layer.kind
        text = layer.text
        textBinding = layer.textBinding
        emittedEvent = layer.emittedEvent
        layoutAxis = layer.layout.axis
        spacingTokenID = layer.layout.spacingTokenID
        effects = layer.effects
        assetID = layer.assetID
        componentDefinitionID = layer.component?.definitionID
        interactionID = layer.interactionID
        accessibilityLabel = layer.accessibilityLabel
        childCount = layer.children.count
    }
}

public struct ContextLayerDetail: Codable, Equatable {
    public let screenID: EntityID
    public let screenScopeID: EntityID
    public let layer: ContextLayerSummary
}

public enum ContextResourceKind: String, Codable {
    case component, token, asset
}

public struct ContextResourceSummary: Codable, Equatable {
    public let id: EntityID
    public let name: String
    public let ownerScopeID: EntityID
    public let kind: ContextResourceKind
    public let visibility: String?
    public let tokenKind: TokenKind?
    public let mediaType: String?
    public let sourceKind: String?

    public init(_ component: ComponentDefinition) {
        id = component.id; name = component.name; ownerScopeID = component.ownerScopeID
        kind = .component; visibility = component.visibility; tokenKind = nil
        mediaType = nil; sourceKind = nil
    }

    public init(_ token: DesignToken) {
        id = token.id; name = token.name; ownerScopeID = token.ownerScopeID
        kind = .token; visibility = nil; tokenKind = token.kind
        mediaType = nil; sourceKind = nil
    }

    public init(_ asset: Asset) {
        id = asset.id; name = asset.name; ownerScopeID = asset.ownerScopeID
        kind = .asset; visibility = nil; tokenKind = nil
        mediaType = asset.mediaType
        switch asset.source {
        case .repository: sourceKind = "repository"
        case .remote: sourceKind = "remote"
        case .runtime: sourceKind = "runtime"
        case .system: sourceKind = "system"
        case .generated: sourceKind = "generated"
        }
    }
}

public struct ContextResourceList: Codable, Equatable {
    public let consumerScopeID: EntityID
    public let kind: ContextResourceKind
    public let items: [ContextResourceSummary]
    public let returnedCount: Int
    public let matchingCount: Int
    public let truncated: Bool
}

public struct ContextComponentAvailabilityList: Codable, Equatable {
    public let consumerScopeID: EntityID
    public let items: [ComponentAvailabilityItem]
    public let returnedCount: Int
    public let matchingCount: Int
    public let truncated: Bool
}

public struct ContextBoundedList<Element: Codable & Equatable>: Codable, Equatable {
    public let items: [Element]
    public let totalCount: Int
    public let truncated: Bool

    public init(_ items: [Element], limit: Int = 100) {
        self.items = Array(items.prefix(limit))
        totalCount = items.count
        truncated = items.count > limit
    }
}

public struct ContextComponentVariant: Codable, Equatable {
    public let id: EntityID
    public let axis: String
    public let value: String

    public init(_ variant: ComponentVariant) {
        id = variant.id; axis = variant.axis; value = variant.value
    }
}

public struct ContextComponentDetail: Codable, Equatable {
    public let id: EntityID
    public let name: String
    public let ownerScopeID: EntityID
    public let visibility: String
    public let properties: ContextBoundedList<ComponentProperty>
    public let slots: ContextBoundedList<ComponentSlot>
    public let bindings: ContextBoundedList<String>
    public let events: ContextBoundedList<String>
    public let overridablePaths: ContextBoundedList<String>
    public let variants: ContextBoundedList<ContextComponentVariant>
    public let root: ContextLayerSummary

    public init(_ component: ComponentDefinition) {
        id = component.id; name = component.name; ownerScopeID = component.ownerScopeID
        visibility = component.visibility
        properties = ContextBoundedList(component.api.properties)
        slots = ContextBoundedList(component.api.slots)
        bindings = ContextBoundedList(component.api.bindings)
        events = ContextBoundedList(component.api.events)
        overridablePaths = ContextBoundedList(component.api.overridablePaths)
        variants = ContextBoundedList(component.variants.map(ContextComponentVariant.init))
        root = ContextLayerSummary(component.root)
    }
}

public struct ContextTokenDetail: Codable, Equatable {
    public let id: EntityID
    public let name: String
    public let kind: TokenKind
    public let ownerScopeID: EntityID
    public let value: TokenValue

    public init(_ token: DesignToken) {
        id = token.id; name = token.name; kind = token.kind
        ownerScopeID = token.ownerScopeID; value = token.value
    }
}

public enum ContextQueryError: Error, Equatable {
    case invalidLimit
}

/// Pure projections shared by one-shot reads and a validated read session.
enum ProjectContextProjection {
    static func projectSummary(_ observed: ProjectObservation,
                               selection: ContextSelection?) throws -> ContextResponse<ContextProjectSummary> {
        let document = observed.document
        let selected: ContextScreenSummary?
        if let selection {
            guard let screen = document.screens.first(where: { $0.id == selection.screenID }) else {
                throw AuthoringError.notFound(selection.screenID.rawValue)
            }
            if let layerID = selection.layerID, Self.layer(layerID, in: screen.root) == nil {
                throw AuthoringError.notFound(layerID.rawValue)
            }
            selected = ContextScreenSummary(id: screen.id, name: screen.name, scopeID: screen.scopeID)
        } else {
            selected = nil
        }
        return ContextResponse(observation: ContextObservation(observed), payload: ContextProjectSummary(
            documentID: document.id, documentName: document.name, documentRevision: document.revision,
            counts: ContextProjectCounts(pages: document.pages.count, screens: document.screens.count,
                scopes: document.scopes.count, components: document.components.count,
                tokens: document.tokens.count, assets: document.assets.count),
            selectedScreen: selected, selectedLayerID: selection?.layerID))
    }

    static func layerDetail(_ observed: ProjectObservation, screenID: EntityID,
                            layerID: EntityID) throws -> ContextResponse<ContextLayerDetail> {
        guard let screen = observed.document.screens.first(where: { $0.id == screenID }) else {
            throw AuthoringError.notFound(screenID.rawValue)
        }
        guard let layer = Self.layer(layerID, in: screen.root) else {
            throw AuthoringError.notFound(layerID.rawValue)
        }
        return ContextResponse(observation: ContextObservation(observed),
            payload: ContextLayerDetail(screenID: screen.id, screenScopeID: screen.scopeID,
                                        layer: ContextLayerSummary(layer)))
    }

    static func resources(_ observed: ProjectObservation, consumerScopeID: EntityID,
                          kind: ContextResourceKind, matching: String?, limit: Int) throws -> ContextResponse<ContextResourceList> {
        guard (1...100).contains(limit) else { throw ContextQueryError.invalidLimit }
        let document = observed.document
        try Self.requireScope(consumerScopeID, in: document)
        let available: [ContextResourceSummary]
        switch kind {
        case .component:
            available = ProjectResourceAvailability.components(in: document, consumer: consumerScopeID)
                .map(ContextResourceSummary.init)
        case .token:
            available = ProjectResourceAvailability.tokens(in: document, consumer: consumerScopeID)
                .map(ContextResourceSummary.init)
        case .asset:
            available = ProjectResourceAvailability.assets(in: document, consumer: consumerScopeID)
                .map(ContextResourceSummary.init)
        }
        let term = matching?.lowercased() ?? ""
        let filtered = available.filter { term.isEmpty || $0.name.lowercased().contains(term) }
            .sorted { left, right in
                left.name == right.name ? left.id.rawValue < right.id.rawValue : left.name < right.name
            }
        let items = Array(filtered.prefix(limit))
        return ContextResponse(observation: ContextObservation(observed), payload: ContextResourceList(
            consumerScopeID: consumerScopeID, kind: kind, items: items,
            returnedCount: items.count, matchingCount: filtered.count,
            truncated: filtered.count > limit))
    }

    static func componentAvailability(_ observed: ProjectObservation, consumerScopeID: EntityID,
                                      matching: String?, limit: Int) throws
        -> ContextResponse<ContextComponentAvailabilityList> {
        guard (1...100).contains(limit) else { throw ContextQueryError.invalidLimit }
        let document = observed.document
        try requireScope(consumerScopeID, in: document)
        let term = matching?.lowercased() ?? ""
        let filtered = ProjectResourceAvailability.componentAvailability(in: document, consumer: consumerScopeID)
            .filter { term.isEmpty || $0.name.lowercased().contains(term) }
            .sorted { left, right in
                left.name == right.name ? left.id.rawValue < right.id.rawValue : left.name < right.name
            }
        let items = Array(filtered.prefix(limit))
        return ContextResponse(observation: ContextObservation(observed),
            payload: ContextComponentAvailabilityList(consumerScopeID: consumerScopeID, items: items,
                returnedCount: items.count, matchingCount: filtered.count, truncated: filtered.count > limit))
    }

    static func componentDetail(_ observed: ProjectObservation, componentID: EntityID,
                                consumerScopeID: EntityID) throws -> ContextResponse<ContextComponentDetail> {
        try Self.requireScope(consumerScopeID, in: observed.document)
        guard let component = ProjectResourceAvailability.components(in: observed.document,
            consumer: consumerScopeID).first(where: { $0.id == componentID }) else {
            throw AuthoringError.notFound(componentID.rawValue)
        }
        return ContextResponse(observation: ContextObservation(observed),
            payload: ContextComponentDetail(component))
    }

    static func tokenDetail(_ observed: ProjectObservation, tokenID: EntityID,
                            consumerScopeID: EntityID) throws -> ContextResponse<ContextTokenDetail> {
        try Self.requireScope(consumerScopeID, in: observed.document)
        guard let token = ProjectResourceAvailability.tokens(in: observed.document,
            consumer: consumerScopeID).first(where: { $0.id == tokenID }) else {
            throw AuthoringError.notFound(tokenID.rawValue)
        }
        return ContextResponse(observation: ContextObservation(observed), payload: ContextTokenDetail(token))
    }

    private static func requireScope(_ scopeID: EntityID, in document: Document) throws {
        guard document.scopes.contains(where: { $0.id == scopeID }) else {
            throw AuthoringError.notFound(scopeID.rawValue)
        }
    }

    private static func layer(_ id: EntityID, in root: Layer) -> Layer? {
        if root.id == id { return root }
        for child in root.children {
            if let match = layer(id, in: child) { return match }
        }
        return nil
    }
}

/// Bounded semantic reads. Each one-shot call derives its response from a new
/// Canonical observation; this remains the CLI's safe baseline.
public final class ProjectContextService {
    private let repository: any ProjectRepository
    public init(repository: any ProjectRepository) { self.repository = repository }

    private func withObservation<Result>(expectedState: ClientPrecondition?,
                                         _ body: (ProjectObservation) throws -> Result) throws -> Result {
        let observed = try repository.observe()
        if let expectedState, observed.statePrecondition != expectedState {
            throw AuthoringError.staleState
        }
        return try body(observed)
    }

    public func projectSummary(selection: ContextSelection? = nil,
                               expectedState: ClientPrecondition? = nil) throws -> ContextResponse<ContextProjectSummary> {
        try withObservation(expectedState: expectedState) {
            try ProjectContextProjection.projectSummary($0, selection: selection)
        }
    }

    public func layerDetail(screenID: EntityID, layerID: EntityID,
                            expectedState: ClientPrecondition) throws -> ContextResponse<ContextLayerDetail> {
        try withObservation(expectedState: expectedState) {
            try ProjectContextProjection.layerDetail($0, screenID: screenID, layerID: layerID)
        }
    }

    public func resources(consumerScopeID: EntityID, kind: ContextResourceKind,
                          matching: String? = nil, limit: Int = 32,
                          expectedState: ClientPrecondition) throws -> ContextResponse<ContextResourceList> {
        guard (1...100).contains(limit) else { throw ContextQueryError.invalidLimit }
        return try withObservation(expectedState: expectedState) {
            try ProjectContextProjection.resources($0, consumerScopeID: consumerScopeID,
                kind: kind, matching: matching, limit: limit)
        }
    }

    public func componentAvailability(consumerScopeID: EntityID, matching: String? = nil,
                                      limit: Int = 32, expectedState: ClientPrecondition) throws
        -> ContextResponse<ContextComponentAvailabilityList> {
        guard (1...100).contains(limit) else { throw ContextQueryError.invalidLimit }
        return try withObservation(expectedState: expectedState) {
            try ProjectContextProjection.componentAvailability($0, consumerScopeID: consumerScopeID,
                matching: matching, limit: limit)
        }
    }

    public func componentDetail(componentID: EntityID, consumerScopeID: EntityID,
                                expectedState: ClientPrecondition) throws -> ContextResponse<ContextComponentDetail> {
        try withObservation(expectedState: expectedState) {
            try ProjectContextProjection.componentDetail($0, componentID: componentID,
                consumerScopeID: consumerScopeID)
        }
    }

    public func tokenDetail(tokenID: EntityID, consumerScopeID: EntityID,
                            expectedState: ClientPrecondition) throws -> ContextResponse<ContextTokenDetail> {
        try withObservation(expectedState: expectedState) {
            try ProjectContextProjection.tokenDetail($0, tokenID: tokenID,
                consumerScopeID: consumerScopeID)
        }
    }

    public func surfaceCapabilityDetail(surfaceID: EntityID,
                                        expectedState: ClientPrecondition) throws -> ContextResponse<ContextSurfaceCapabilityDetail> {
        try withObservation(expectedState: expectedState) {
            try ProjectContextProjection.surfaceCapabilityDetail($0, surfaceID: surfaceID)
        }
    }
}
