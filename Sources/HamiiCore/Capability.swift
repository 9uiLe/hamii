import Foundation

public struct CapabilityKey: Codable, Hashable, CustomStringConvertible, Sendable {
    public var rawValue: String
    public var description: String { rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// Stable names for capabilities represented by the current IR. The persisted key is still a string.
public enum CapabilityKeys {
    public static let stackContainer = CapabilityKey("layout.stack.container")
    public static let overlayVisual = CapabilityKey("layout.overlay.visual")
    public static let scrollContainer = CapabilityKey("layout.scroll.container")
    public static let textVisual = CapabilityKey("component.text.visual")
    public static let buttonVisual = CapabilityKey("component.button.visual")
    public static let buttonEventEmit = CapabilityKey("component.button.eventEmit")
    public static let imageVisual = CapabilityKey("component.image.visual")
    public static let componentInstance = CapabilityKey("component.instance.resolve")
    public static let fixtureBinding = CapabilityKey("content.fixtureBinding")
    public static let bindingFallback = CapabilityKey("content.bindingFallback")
    public static let spacingToken = CapabilityKey("layout.spacingToken")
    public static let paddingEffect = CapabilityKey("effect.padding")
    public static let systemAssetMapping = CapabilityKey("asset.systemMapping")
    public static let repositoryAssetRendering = CapabilityKey("asset.repositoryRendering")
    public static let remoteAssetFetch = CapabilityKey("asset.remoteFetch")
    public static let runtimeAssetBinding = CapabilityKey("asset.runtimeBinding")
    public static let generatedAssetRendering = CapabilityKey("asset.generatedRendering")
    public static let systemNavigation = CapabilityKey("navigation.system.container")
    public static let navigationTitle = CapabilityKey("navigation.system.title")
    public static let systemToolbar = CapabilityKey("navigation.toolbar.systemOwnership")
    public static let toolbarEventEmit = CapabilityKey("navigation.toolbar.eventEmit")
    public static let customNavigation = CapabilityKey("navigation.custom.container")
    public static let interactionRuntime = CapabilityKey("interaction.runtime")
    public static let nativeIntent = CapabilityKey("native.intent")
    public static let targetOverride = CapabilityKey("native.targetOverride")

    // Basic node declarations cover their original visual meaning only.
    public static let legacyStack = CapabilityKey("layout.stack")
    public static let legacyOverlay = CapabilityKey("layout.overlay")
    public static let legacyScroll = CapabilityKey("layout.scroll")
    public static let legacyText = CapabilityKey("component.text")
    public static let legacyButton = CapabilityKey("component.button")
    public static let legacyImage = CapabilityKey("component.image")
    public static let legacyInstance = CapabilityKey("component.instance")
    public static let legacySpacing = CapabilityKey("token.spacing")
    public static let legacySystemNavigation = CapabilityKey("navigation.system")
    public static let legacyCustomNavigation = CapabilityKey("navigation.custom")
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

public struct SemanticRequirement: Codable, Equatable {
    public var key: CapabilityKey
    public var sourceEntityID: EntityID
    public init(key: CapabilityKey, sourceEntityID: EntityID) {
        self.key = key; self.sourceEntityID = sourceEntityID
    }
}

/// A generator has no AppSurface and therefore no observed runtime.
public struct CapabilityProfile: Codable, Equatable {
    public var targetID: EntityID
    public var platform: Platform
    public var framework: Framework
    public var runtime: String?
    public init(target: Target, surface: AppSurface) {
        targetID = target.id; platform = target.platform; framework = target.framework; runtime = surface.runtime
    }
    public init(target: Target) {
        targetID = target.id; platform = target.platform; framework = target.framework; runtime = nil
    }
}

public enum CapabilityLossKind: String, Codable {
    case none, approvedApproximation, approvalRequired, unsupported, externalIntegration
}

public struct CapabilityLoss: Codable, Equatable {
    public var requirement: SemanticRequirement
    public var support: CapabilitySupport
    public var allowed: Bool
    public var loss: CapabilityLossKind
    public var reason: String
}

public struct CapabilityLossReport: Codable, Equatable {
    public var profile: CapabilityProfile
    public var items: [CapabilityLoss]
    public var allowed: Bool { items.allSatisfy(\.allowed) }

    private enum CodingKeys: String, CodingKey { case profile, items, allowed }
    public init(profile: CapabilityProfile, items: [CapabilityLoss]) {
        self.profile = profile; self.items = items
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        profile = try values.decode(CapabilityProfile.self, forKey: .profile)
        items = try values.decode([CapabilityLoss].self, forKey: .items)
        let recorded = try values.decode(Bool.self, forKey: .allowed)
        guard recorded == allowed else {
            throw DecodingError.dataCorruptedError(forKey: .allowed, in: values, debugDescription: "Capability report allowance disagrees with item results")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(profile, forKey: .profile)
        try values.encode(items, forKey: .items)
        try values.encode(allowed, forKey: .allowed)
    }
}

public struct SemanticExtraction {
    public var requirements: [SemanticRequirement]
    public var diagnostics: [Diagnostic]
    public var bindings: [SemanticBinding]
}

public struct SemanticBinding {
    public var sourceEntityID: EntityID
    public var path: String
    public var hasFallback: Bool
}

/// Reads current IR meaning only. Framework and target support decisions belong to the evaluator.
public enum SemanticRequirementExtractor {
    public static func extract(screen: Screen, document: Document) -> SemanticExtraction {
        var requirements: [SemanticRequirement] = []
        var diagnostics: [Diagnostic] = []
        var bindings: [SemanticBinding] = []
        let assets = Dictionary(document.assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let components = Dictionary(document.components.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        func append(_ key: CapabilityKey, _ id: EntityID) {
            requirements.append(SemanticRequirement(key: key, sourceEntityID: id))
        }
        func visit(_ layer: Layer) {
            switch layer.payload {
            case .stack: append(CapabilityKeys.stackContainer, layer.id)
            case .overlay: append(CapabilityKeys.overlayVisual, layer.id)
            case .scroll: append(CapabilityKeys.scrollContainer, layer.id)
            case .text: append(CapabilityKeys.textVisual, layer.id)
            case .button(let payload):
                append(CapabilityKeys.buttonVisual, layer.id)
                if payload.emittedEvent != nil { append(CapabilityKeys.buttonEventEmit, layer.id) }
            case .image(let payload):
                append(CapabilityKeys.imageVisual, layer.id)
                if let id = payload.assetID, let asset = assets[id] {
                    switch asset.source {
                    case .system: append(CapabilityKeys.systemAssetMapping, layer.id)
                    case .repository: append(CapabilityKeys.repositoryAssetRendering, layer.id)
                    case .remote: append(CapabilityKeys.remoteAssetFetch, layer.id)
                    case .runtime: append(CapabilityKeys.runtimeAssetBinding, layer.id)
                    case .generated: append(CapabilityKeys.generatedAssetRendering, layer.id)
                    }
                }
            case .componentInstance(let payload):
                append(CapabilityKeys.componentInstance, layer.id)
                if let instance = payload.instance, let definition = components[instance.definitionID] {
                    if let resolved = try? ComponentResolver.resolve(instance, definition: definition) {
                        visit(resolved)
                    } else {
                        diagnostics.append(Diagnostic("semantic.component", "Component cannot be resolved", entityID: layer.id))
                    }
                } else {
                    diagnostics.append(Diagnostic("semantic.component", "Component cannot be resolved", entityID: layer.id))
                }
            }
            if layer.layout.spacingTokenID != nil { append(CapabilityKeys.spacingToken, layer.id) }
            for effect in layer.effects {
                switch effect { case .padding: append(CapabilityKeys.paddingEffect, layer.id) }
            }
            if let binding = layer.textBinding {
                if layer.kind == .text || layer.kind == .button {
                    append(CapabilityKeys.fixtureBinding, layer.id)
                    if layer.text != nil { append(CapabilityKeys.bindingFallback, layer.id) }
                    bindings.append(SemanticBinding(sourceEntityID: layer.id, path: binding, hasFallback: layer.text != nil))
                } else {
                    diagnostics.append(Diagnostic("semantic.binding", "Binding is unavailable for this Layer kind", entityID: layer.id))
                }
            }
            if layer.emittedEvent != nil && layer.kind != .button {
                diagnostics.append(Diagnostic("semantic.event", "Event emission is unavailable for this Layer kind", entityID: layer.id))
            }
            if layer.interactionID != nil { append(CapabilityKeys.interactionRuntime, layer.id) }
            if layer.nativeIntent != nil { append(CapabilityKeys.nativeIntent, layer.id) }
            if !layer.targetOverrides.isEmpty { append(CapabilityKeys.targetOverride, layer.id) }
            layer.children.forEach(visit)
        }
        visit(screen.root)
        if let navigation = screen.navigation {
            switch navigation {
            case .system(let system):
                append(CapabilityKeys.systemNavigation, screen.id)
                if system.title != nil { append(CapabilityKeys.navigationTitle, screen.id) }
                for item in system.toolbarItems {
                    append(CapabilityKeys.systemToolbar, item.id)
                    append(CapabilityKeys.toolbarEventEmit, item.id)
                }
            case .custom:
                append(CapabilityKeys.customNavigation, screen.id)
            }
        }
        return SemanticExtraction(requirements: requirements, diagnostics: diagnostics, bindings: bindings)
    }
}

/// The evaluator consumes this declared support surface without knowing which consumer owns it.
public struct CapabilityCatalog: Sendable {
    public var supportedKeys: Set<CapabilityKey>
    public var legacyAliases: [CapabilityKey: CapabilityKey]
    /// A runtime-sensitive requirement is never allowed by a profile without an observed runtime.
    public var runtimeSensitiveKeys: Set<CapabilityKey>
    public init(supportedKeys: Set<CapabilityKey>, legacyAliases: [CapabilityKey: CapabilityKey] = [:], runtimeSensitiveKeys: Set<CapabilityKey> = []) {
        self.supportedKeys = supportedKeys
        self.legacyAliases = legacyAliases
        self.runtimeSensitiveKeys = runtimeSensitiveKeys
    }
}

/// Basic node declarations cover only the corresponding visual meaning.
public enum BasicCapabilityAliases {
    public static let map: [CapabilityKey: CapabilityKey] = [
        CapabilityKeys.stackContainer: CapabilityKeys.legacyStack,
        CapabilityKeys.overlayVisual: CapabilityKeys.legacyOverlay,
        CapabilityKeys.scrollContainer: CapabilityKeys.legacyScroll,
        CapabilityKeys.textVisual: CapabilityKeys.legacyText,
        CapabilityKeys.buttonVisual: CapabilityKeys.legacyButton,
        CapabilityKeys.imageVisual: CapabilityKeys.legacyImage,
        CapabilityKeys.componentInstance: CapabilityKeys.legacyInstance,
        CapabilityKeys.spacingToken: CapabilityKeys.legacySpacing,
        CapabilityKeys.systemNavigation: CapabilityKeys.legacySystemNavigation,
        CapabilityKeys.customNavigation: CapabilityKeys.legacyCustomNavigation
    ]
}

/// This subset describes the implemented Preview semantics. It is not an API coverage claim for every target OS.
public enum NativePreviewCapabilityCatalog {
    public static let supportedKeys: Set<CapabilityKey> = [
        CapabilityKeys.stackContainer, CapabilityKeys.overlayVisual, CapabilityKeys.scrollContainer,
        CapabilityKeys.textVisual, CapabilityKeys.buttonVisual, CapabilityKeys.buttonEventEmit,
        CapabilityKeys.imageVisual, CapabilityKeys.componentInstance, CapabilityKeys.fixtureBinding,
        CapabilityKeys.bindingFallback, CapabilityKeys.spacingToken, CapabilityKeys.paddingEffect,
        CapabilityKeys.systemAssetMapping, CapabilityKeys.systemNavigation, CapabilityKeys.navigationTitle,
        CapabilityKeys.systemToolbar, CapabilityKeys.toolbarEventEmit, CapabilityKeys.customNavigation
    ]

    public static let catalog = CapabilityCatalog(supportedKeys: supportedKeys, legacyAliases: BasicCapabilityAliases.map)
}

/// Evaluates requirements without inspecting a Layer tree. Missing and ambiguous declarations fail closed.
public enum CapabilityEvaluator {
    public static func evaluate(
        requirements: [SemanticRequirement], profile: CapabilityProfile,
        declarations: [CapabilityDeclaration], approvedApproximationKeys: Set<CapabilityKey> = [],
        catalog: CapabilityCatalog
    ) -> CapabilityLossReport {
        let targetDeclarations = Dictionary(grouping: declarations.filter { $0.targetID == profile.targetID }, by: \.key)
        let items = requirements.map { requirement -> CapabilityLoss in
            // An exact semantic declaration takes precedence over its basic node alias.
            let aliases = [requirement.key, catalog.legacyAliases[requirement.key]].compactMap { $0 }
            let matching = aliases.lazy.compactMap { targetDeclarations[$0] }.first ?? []
            let declaration = matching.count == 1 ? matching[0] : nil
            let support: CapabilitySupport
            let reason: String
            if catalog.runtimeSensitiveKeys.contains(requirement.key) && (profile.runtime?.isEmpty != false) {
                support = .unsupported
                reason = "An observed runtime is required for this semantic capability"
            } else if !catalog.supportedKeys.contains(requirement.key) {
                support = .unsupported
                reason = "This consumer does not implement this semantic requirement"
            } else if matching.count > 1 {
                support = .unsupported
                reason = "Ambiguous capability declarations"
            } else {
                support = declaration?.support ?? .unsupported
                if let declaredReason = declaration?.reason, !declaredReason.isEmpty {
                    reason = declaredReason
                } else if declaration == nil {
                    reason = "Capability is not declared for this target"
                } else {
                    switch support {
                    case .exact, .portable, .targetSpecific: reason = "Supported by target declaration"
                    case .approximate: reason = "Approximation requires explicit approval"
                    case .unsupported: reason = "Target declares this capability unsupported"
                    case .externalIntegrationRequired: reason = "Product integration is required"
                    }
                }
            }
            let approved = approvedApproximationKeys.contains(requirement.key) || declaration.map { approvedApproximationKeys.contains($0.key) } == true
            let allowed: Bool
            let loss: CapabilityLossKind
            switch support {
            case .exact, .portable, .targetSpecific: allowed = true; loss = .none
            case .approximate:
                allowed = approved
                loss = approved ? .approvedApproximation : .approvalRequired
            case .unsupported: allowed = false; loss = .unsupported
            case .externalIntegrationRequired: allowed = false; loss = .externalIntegration
            }
            return CapabilityLoss(requirement: requirement, support: support, allowed: allowed, loss: loss, reason: reason)
        }
        return CapabilityLossReport(profile: profile, items: items)
    }
}

public enum NativePreviewCapabilityAnalysis {
    public static func report(screen: Screen, document: Document, surface: AppSurface, target: Target, approvedApproximationKeys: Set<CapabilityKey> = []) -> CapabilityLossReport {
        let extraction = SemanticRequirementExtractor.extract(screen: screen, document: document)
        return CapabilityEvaluator.evaluate(
            requirements: extraction.requirements,
            profile: CapabilityProfile(target: target, surface: surface),
            declarations: document.capabilityDeclarations,
            approvedApproximationKeys: approvedApproximationKeys,
            catalog: NativePreviewCapabilityCatalog.catalog
        )
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
        guard let target = document.targets.first(where: { $0.id == surface.targetID }) else {
            return TargetPlan(surfaceID: surface.id, targetID: surface.targetID, screenID: surface.screenID, diagnostics: [Diagnostic("surface.target", "Target is missing", entityID: surface.id)])
        }
        let extraction = SemanticRequirementExtractor.extract(screen: screen, document: document)
        diagnostics += extraction.diagnostics.map { diagnostic in
            Diagnostic(diagnostic.rule.replacingOccurrences(of: "semantic.", with: "preview."),
                       diagnostic.message, entityID: diagnostic.entityID, severity: diagnostic.severity)
        }
        let fixture = document.fixtures.first { $0.id == surface.fixtureID }
        diagnostics += extraction.bindings.filter { !$0.hasFallback && fixture?.values[$0.path] == nil }.map {
            Diagnostic("preview.fixture", "Text binding has no fixture value or fallback", entityID: $0.sourceEntityID)
        }
        let report = CapabilityEvaluator.evaluate(
            requirements: extraction.requirements,
            profile: CapabilityProfile(target: target, surface: surface),
            declarations: document.capabilityDeclarations,
            approvedApproximationKeys: approvedApproximationKeys,
            catalog: NativePreviewCapabilityCatalog.catalog
        )
        diagnostics += report.items.filter { !$0.allowed }.map { loss in
            let key = loss.requirement.key
            let rule: String
            if key == CapabilityKeys.interactionRuntime { rule = "preview.interaction" }
            else if key == CapabilityKeys.nativeIntent || key == CapabilityKeys.targetOverride { rule = "preview.nativeSemantics" }
            else if [CapabilityKeys.repositoryAssetRendering, CapabilityKeys.remoteAssetFetch, CapabilityKeys.runtimeAssetBinding, CapabilityKeys.generatedAssetRendering].contains(key) { rule = "preview.asset" }
            else if key == CapabilityKeys.systemNavigation || key == CapabilityKeys.customNavigation { rule = "capability.navigation" }
            else if loss.loss == .approvalRequired { rule = "capability.approvalRequired" }
            else if loss.loss == .externalIntegration { rule = "capability.externalIntegration" }
            else { rule = "capability.unsupported" }
            return Diagnostic(rule, "Capability \(key): \(loss.reason)", entityID: loss.requirement.sourceEntityID)
        }
        return TargetPlan(surfaceID: surface.id, targetID: surface.targetID, screenID: screen.id, diagnostics: diagnostics)
    }
}
