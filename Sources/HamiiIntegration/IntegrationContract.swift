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
    public var codeModificationPolicy: [String]
    public init(repositoryName: String) {
        formatVersion = 1; self.repositoryName = repositoryName
        architectureRules = []; componentMappings = [:]; tokenMappings = [:]
        assetMappings = [:]; routingMappings = [:]; stateMappings = [:]
        codeModificationPolicy = []
    }
}

public struct IntegrationPlan: Codable {
    public var contract: IntegrationContract
    public var unresolvedMappings: [String]
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
        var unresolved: [String] = []
        for token in contract.tokenIDs where profile.tokenMappings[token] == nil { unresolved.append("token:\(token.rawValue)") }
        for asset in contract.assetIDs where profile.assetMappings[asset] == nil { unresolved.append("asset:\(asset.rawValue)") }
        for event in contract.events where profile.routingMappings[event] == nil { unresolved.append("event:\(event)") }
        for input in contract.inputs where profile.stateMappings[input] == nil { unresolved.append("input:\(input)") }
        return IntegrationPlan(contract: contract, unresolvedMappings: unresolved.sorted())
    }
}
