import Foundation
import HamiiCore

public struct IntegrationContract: Codable, Equatable {
    public var screenID: EntityID
    public var name: String
    public var architectureScopeID: EntityID
    public var inputs: [String]
    public var events: [String]
    public var tokenIDs: [EntityID]
    public var assetIDs: [EntityID]
    public var nativeIntents: [String]
    public var accessibilityLabels: [String]
    // Nil preserves the JSON shape of contracts extracted from the current IR.
    // A textBinding alone cannot establish visibility, nil or transform semantics.
    public var semanticSources: [SemanticSource]? = nil
    public var relations: [SemanticRelation]? = nil

    public init(screenID: EntityID, name: String, architectureScopeID: EntityID,
                inputs: [String], events: [String], tokenIDs: [EntityID], assetIDs: [EntityID],
                nativeIntents: [String], accessibilityLabels: [String],
                semanticSources: [SemanticSource]? = nil, relations: [SemanticRelation]? = nil) {
        self.screenID = screenID
        self.name = name
        self.architectureScopeID = architectureScopeID
        self.inputs = inputs
        self.events = events
        self.tokenIDs = tokenIDs
        self.assetIDs = assetIDs
        self.nativeIntents = nativeIntents
        self.accessibilityLabels = accessibilityLabels
        self.semanticSources = semanticSources
        self.relations = relations
    }
}

public struct IntegrationProfile: Codable, Equatable {
    public var formatVersion: Int
    public var repositoryName: String
    public var architectureRules: [String]
    public var componentMappings: [EntityID: String]
    public var tokenMappings: [EntityID: String]
    public var assetMappings: [EntityID: String]
    public var routingMappings: [String: String]
    public var stateMappings: [String: String]
    public var nativeMappings: [String: String]
    public var codeModificationPolicy: [String]
    public init(repositoryName: String) {
        formatVersion = 1; self.repositoryName = repositoryName
        architectureRules = []; componentMappings = [:]; tokenMappings = [:]
        assetMappings = [:]; routingMappings = [:]; stateMappings = [:]; nativeMappings = [:]
        codeModificationPolicy = []
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, repositoryName, architectureRules, componentMappings
        case tokenMappings, assetMappings, routingMappings, stateMappings
        case nativeMappings, codeModificationPolicy
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try values.decode(Int.self, forKey: .formatVersion)
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
    }
}

public struct IntegrationPlan: Codable {
    public var contract: IntegrationContract
    public var unresolvedMappings: [String]
    public var resolutionIssues: [IntegrationResolutionIssue]
    public var blockedOutputs: [SemanticOutputKey]
    public var needsResolution: Bool { !resolutionIssues.isEmpty }
}

public enum ContractError: Error { case missingScreen, invalidDocument([Diagnostic]) }

public enum IntegrationContracts {
    public static func make(screenID: EntityID, document: Document) throws -> IntegrationContract {
        let diagnostics = DocumentValidator.validate(document)
        if diagnostics.contains(where: { $0.severity == .error }) { throw ContractError.invalidDocument(diagnostics) }
        guard let screen = document.screens.first(where: { $0.id == screenID }) else { throw ContractError.missingScreen }
        var inputs = Set<String>()
        var events = Set<String>()
        var tokens = Set<EntityID>()
        var assets = Set<EntityID>()
        var native = Set<String>()
        var labels = Set<String>()
        func collect(_ layer: Layer) throws {
            if let value = layer.textBinding { inputs.insert(value) }
            if let value = layer.emittedEvent { events.insert(value) }
            if let value = layer.layout.spacingTokenID { tokens.insert(value) }
            for effect in layer.effects { tokens.insert(effect.tokenID) }
            if let value = layer.assetID { assets.insert(value) }
            if let value = layer.nativeIntent { native.insert(value) }
            if let value = layer.accessibilityLabel { labels.insert(value) }
            for child in layer.children { try collect(child) }
            if let instance = layer.component, let definition = document.components.first(where: { $0.id == instance.definitionID }) {
                try collect(ComponentResolver.resolve(instance, definition: definition))
            }
        }
        try collect(screen.root)
        if let navigation = screen.navigation {
            switch navigation {
            case .system(let system):
                native.insert("navigation.system")
                for item in system.toolbarItems { events.insert(item.emittedEvent) }
            case .custom:
                native.insert("navigation.custom")
            }
        }
        return IntegrationContract(screenID: screen.id, name: screen.name, architectureScopeID: screen.scopeID, inputs: inputs.sorted(), events: events.sorted(), tokenIDs: tokens.sorted { $0.rawValue < $1.rawValue }, assetIDs: assets.sorted { $0.rawValue < $1.rawValue }, nativeIntents: native.sorted(), accessibilityLabels: labels.sorted())
    }

    public static func plan(_ contract: IntegrationContract, profile: IntegrationProfile) -> IntegrationPlan {
        IntegrationPlanner.plan(contract, assessments: IntegrationPlanner.assessments(for: contract, profile: profile))
    }
}
