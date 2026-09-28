import Foundation

public struct CapabilityKey: Codable, Hashable, CustomStringConvertible {
    public var rawValue: String
    public var description: String { rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public enum CapabilitySupport: String, Codable {
    case exact, portable, targetSpecific, approximate, unsupported, externalIntegrationRequired
}

public struct CapabilityDeclaration: Codable, Equatable {
    public var targetID: EntityID
    public var key: CapabilityKey
    public var support: CapabilitySupport
    public var reason: String
    public init(targetID: EntityID, key: CapabilityKey, support: CapabilitySupport, reason: String = "") {
        self.targetID = targetID; self.key = key; self.support = support; self.reason = reason
    }
}

public struct TargetPlan: Codable {
    public var surfaceID: EntityID
    public var targetID: EntityID
    public var screenID: EntityID
    public var diagnostics: [Diagnostic]
    public var canPreview: Bool { !diagnostics.contains(where: { $0.severity == .error }) }
}

public enum TargetPlanner {
    public static func plan(surface: AppSurface, document: Document, approvedApproximationKeys: Set<CapabilityKey> = []) -> TargetPlan {
        var diagnostics = DocumentValidator.validate(document)
        guard let screen = document.screens.first(where: { $0.id == surface.screenID }) else {
            return TargetPlan(surfaceID: surface.id, targetID: surface.targetID, screenID: surface.screenID, diagnostics: [Diagnostic("surface.screen", "Screen is missing", entityID: surface.id)])
        }
        guard document.targets.contains(where: { $0.id == surface.targetID }) else {
            return TargetPlan(surfaceID: surface.id, targetID: surface.targetID, screenID: surface.screenID, diagnostics: [Diagnostic("surface.target", "Target is missing", entityID: surface.id)])
        }
        func require(_ key: CapabilityKey, for id: EntityID) {
            let declarations = document.capabilityDeclarations.filter { $0.targetID == surface.targetID && $0.key == key }
            let support = declarations.first?.support ?? .unsupported
            switch support {
            case .exact, .portable, .targetSpecific: break
            case .approximate:
                if !approvedApproximationKeys.contains(key) {
                    diagnostics.append(Diagnostic("capability.approvalRequired", "Approximate capability requires explicit approval: \(key)", entityID: id))
                }
            case .unsupported:
                diagnostics.append(Diagnostic("capability.unsupported", "Unsupported capability: \(key)", entityID: id))
            case .externalIntegrationRequired:
                diagnostics.append(Diagnostic("capability.externalIntegration", "Capability requires product integration: \(key)", entityID: id))
            }
        }
        func check(_ layer: Layer) {
            let key: CapabilityKey
            switch layer.payload {
            case .stack: key = CapabilityKey("layout.stack")
            case .overlay: key = CapabilityKey("layout.overlay")
            case .scroll: key = CapabilityKey("layout.scroll")
            case .text: key = CapabilityKey("component.text")
            case .image: key = CapabilityKey("component.image")
            case .button: key = CapabilityKey("component.button")
            case .componentInstance: key = CapabilityKey("component.instance")
            }
            require(key, for: layer.id)
            if layer.layout.spacingTokenID != nil || layer.layout.paddingTokenID != nil {
                require(CapabilityKey("token.spacing"), for: layer.id)
            }
            if layer.interactionID != nil {
                diagnostics.append(Diagnostic("preview.interaction", "Interaction runtime is unavailable", entityID: layer.id))
            }
            if layer.nativeIntent != nil || !layer.targetOverrides.isEmpty {
                diagnostics.append(Diagnostic("preview.nativeSemantics", "Native intent or target override is not mapped", entityID: layer.id))
            }
            if let binding = layer.textBinding {
                let fixture = document.fixtures.first(where: { $0.id == surface.fixtureID })
                if fixture?.values[binding] == nil && layer.text == nil {
                    diagnostics.append(Diagnostic("preview.fixture", "Text binding has no fixture value or fallback", entityID: layer.id))
                }
            }
            if let assetID = layer.assetID,
               let asset = document.assets.first(where: { $0.id == assetID }) {
                if case .system = asset.source {} else {
                    diagnostics.append(Diagnostic("preview.asset", "Only system assets are available in this runtime", entityID: layer.id))
                }
            }
            if layer.emittedEvent != nil && layer.kind != .button {
                diagnostics.append(Diagnostic("preview.event", "Event emission is unavailable for this Layer kind", entityID: layer.id))
            }
            if let instance = layer.component,
               let definition = document.components.first(where: { $0.id == instance.definitionID }) {
                if let resolved = try? ComponentResolver.resolve(instance, definition: definition) { check(resolved) }
                else { diagnostics.append(Diagnostic("preview.component", "Component cannot be resolved", entityID: layer.id)) }
            }
            layer.children.forEach(check)
        }
        check(screen.root)
        if let navigation = screen.navigation {
            let key: CapabilityKey = {
                switch navigation {
                case .system: return CapabilityKey("navigation.system")
                case .custom: return CapabilityKey("navigation.custom")
                }
            }()
            let support = document.capabilityDeclarations.first(where: { $0.targetID == surface.targetID && $0.key == key })?.support ?? .unsupported
            if support == .unsupported || support == .externalIntegrationRequired || (support == .approximate && !approvedApproximationKeys.contains(key)) {
                diagnostics.append(Diagnostic("capability.navigation", "Navigation capability cannot be previewed: \(key)", entityID: screen.id))
            }
        }
        return TargetPlan(surfaceID: surface.id, targetID: surface.targetID, screenID: screen.id, diagnostics: diagnostics)
    }
}
