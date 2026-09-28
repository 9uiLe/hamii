import Foundation

public struct EntityID: Codable, Hashable, Identifiable, CustomStringConvertible, Sendable {
    public let rawValue: String
    public var id: String { rawValue }
    public var description: String { rawValue }

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static func new(_ kind: String) -> EntityID {
        EntityID("\(kind)_\(UUID().uuidString.lowercased())")
    }
}

public struct FormatVersions: Codable, Equatable {
    public var document: Int
    public var authoringHarness: Int
    public var integrationProfile: Int

    public init(document: Int = 1, authoringHarness: Int = 1, integrationProfile: Int = 1) {
        self.document = document
        self.authoringHarness = authoringHarness
        self.integrationProfile = integrationProfile
    }
}

public struct Document: Codable, Equatable {
    public var id: EntityID
    public var name: String
    public var revision: Int
    public var versions: FormatVersions
    public var pages: [Page]
    public var screens: [Screen]
    public var scopes: [ArchitectureScope]
    public var components: [ComponentDefinition]
    public var tokens: [DesignToken]
    public var assets: [Asset]
    public var interactions: [Interaction]
    public var motions: [Motion]
    public var fixtures: [PreviewFixture]
    public var targets: [Target]
    public var capabilityDeclarations: [CapabilityDeclaration]
    public var tokenTemplate: TokenTemplateProvenance?
    public var authoringHarness: AuthoringHarness

    public init(name: String) {
        id = .new("doc")
        self.name = name
        revision = 0
        versions = FormatVersions()
        pages = []
        screens = []
        scopes = [ArchitectureScope(id: .new("scope"), name: "App", parentID: nil)]
        components = []
        tokens = []
        assets = []
        interactions = []
        motions = []
        fixtures = []
        targets = []
        capabilityDeclarations = []
        tokenTemplate = nil
        authoringHarness = AuthoringHarness()
    }
}

public struct ArchitectureScope: Codable, Equatable, Identifiable {
    public var id: EntityID
    public var name: String
    public var parentID: EntityID?
    public init(id: EntityID, name: String, parentID: EntityID?) {
        self.id = id; self.name = name; self.parentID = parentID
    }
}

public struct Page: Codable, Equatable, Identifiable {
    public var id: EntityID
    public var name: String
    public var surfaces: [AppSurface]
    public init(id: EntityID, name: String, surfaces: [AppSurface] = []) {
        self.id = id; self.name = name; self.surfaces = surfaces
    }
}

public struct Screen: Codable, Equatable, Identifiable {
    public var id: EntityID
    public var name: String
    public var scopeID: EntityID
    public var root: Layer
    public var navigation: NavigationConfiguration?
    public init(id: EntityID, name: String, scopeID: EntityID, root: Layer) {
        self.id = id; self.name = name; self.scopeID = scopeID; self.root = root
        self.navigation = nil
    }
}

public struct SystemToolbarItem: Codable, Equatable, Identifiable {
    public var id: EntityID
    public var title: String
    public var emittedEvent: String
    public init(id: EntityID, title: String, emittedEvent: String) {
        self.id = id; self.title = title; self.emittedEvent = emittedEvent
    }
}

public struct SystemNavigation: Codable, Equatable {
    public var title: String?
    public var toolbarItems: [SystemToolbarItem]
    public init(title: String? = nil, toolbarItems: [SystemToolbarItem] = []) {
        self.title = title; self.toolbarItems = toolbarItems
    }
}

public enum NavigationConfiguration: Codable, Equatable {
    case system(SystemNavigation)
    case custom(layerID: EntityID)
}

public enum Platform: String, Codable { case iOS, macOS, android }
public enum Framework: String, Codable { case swiftUI, uiKit, jetpackCompose, composeMultiplatform }

public struct Target: Codable, Equatable, Identifiable {
    public var id: EntityID
    public var platform: Platform
    public var framework: Framework
    public init(id: EntityID, platform: Platform, framework: Framework) {
        self.id = id; self.platform = platform; self.framework = framework
    }
}

public struct AppSurface: Codable, Equatable, Identifiable {
    public var id: EntityID
    public var targetID: EntityID
    public var device: String
    public var runtime: String
    public var buildEnvironment: String
    public var environment: [String: String]
    public var screenID: EntityID
    public var fixtureID: EntityID?
    public var architectureScopeID: EntityID
    public var previewConfiguration: [String: String]

    public init(id: EntityID, targetID: EntityID, device: String, runtime: String, buildEnvironment: String, screenID: EntityID, architectureScopeID: EntityID, fixtureID: EntityID? = nil) {
        self.id = id; self.targetID = targetID; self.device = device; self.runtime = runtime
        self.buildEnvironment = buildEnvironment; self.environment = [:]; self.screenID = screenID
        self.fixtureID = fixtureID; self.architectureScopeID = architectureScopeID
        self.previewConfiguration = [:]
    }
}

public enum LayerKind: String, Codable { case stack, text, image, button, componentInstance, scroll, overlay }
public enum LayoutAxis: String, Codable { case vertical, horizontal }

public struct Layout: Codable, Equatable {
    public var axis: LayoutAxis?
    public var spacingTokenID: EntityID?
    public var paddingTokenID: EntityID?
    public init(axis: LayoutAxis? = nil, spacingTokenID: EntityID? = nil, paddingTokenID: EntityID? = nil) {
        self.axis = axis; self.spacingTokenID = spacingTokenID; self.paddingTokenID = paddingTokenID
    }
}

public struct ComponentInstance: Codable, Equatable {
    public var definitionID: EntityID
    public var variantSelection: [String: String]
    public var propertyValues: [String: String]
    public var slotContent: [String: [Layer]]
    public var allowedOverrides: [String: String]
    public init(definitionID: EntityID, variantSelection: [String: String] = [:], propertyValues: [String: String] = [:], slotContent: [String: [Layer]] = [:], allowedOverrides: [String: String] = [:]) {
        self.definitionID = definitionID; self.variantSelection = variantSelection
        self.propertyValues = propertyValues; self.slotContent = slotContent
        self.allowedOverrides = allowedOverrides
    }
}

public struct TextLayerPayload: Equatable {
    public var value: String?
    public var binding: String?
    public init(value: String? = nil, binding: String? = nil) {
        self.value = value; self.binding = binding
    }
}

public struct ButtonLayerPayload: Equatable {
    public var label: String?
    public var binding: String?
    public var emittedEvent: String?
    public init(label: String? = nil, binding: String? = nil, emittedEvent: String? = nil) {
        self.label = label; self.binding = binding; self.emittedEvent = emittedEvent
    }
}

public struct ImageLayerPayload: Equatable {
    public var assetID: EntityID?
    public init(assetID: EntityID? = nil) { self.assetID = assetID }
}

public struct ComponentInstanceLayerPayload: Equatable {
    public var instance: ComponentInstance?
    public init(instance: ComponentInstance? = nil) { self.instance = instance }
}

/// Runtime node meaning. Format v1 continues to encode the established flat Layer keys.
public enum LayerPayload: Equatable {
    case stack
    case overlay
    case scroll
    case text(TextLayerPayload)
    case image(ImageLayerPayload)
    case button(ButtonLayerPayload)
    case componentInstance(ComponentInstanceLayerPayload)

    public var kind: LayerKind {
        switch self {
        case .stack: .stack
        case .overlay: .overlay
        case .scroll: .scroll
        case .text: .text
        case .image: .image
        case .button: .button
        case .componentInstance: .componentInstance
        }
    }
}

/// Format v1 permits fields on unrelated kinds. Preserve those exact persisted values
/// without treating them as supported semantics for the typed node.
private struct FormatV1Residual: Equatable {
    var text: String?
    var textBinding: String?
    var emittedEvent: String?
    var assetID: EntityID?
    var component: ComponentInstance?
}

public struct Layer: Codable, Equatable, Identifiable {
    public var id: EntityID
    public var name: String
    public var children: [Layer]
    public var layout: Layout
    public var payload: LayerPayload
    public var interactionID: EntityID?
    public var accessibilityLabel: String?
    public var nativeIntent: String?
    public var targetOverrides: [String: String]
    private var formatV1Residual = FormatV1Residual()

    public var kind: LayerKind { payload.kind }

    public var text: String? {
        get {
            switch payload {
            case .text(let value): value.value
            case .button(let value): value.label
            default: formatV1Residual.text
            }
        }
        set {
            switch payload {
            case .text(var value): value.value = newValue; payload = .text(value)
            case .button(var value): value.label = newValue; payload = .button(value)
            default: formatV1Residual.text = newValue
            }
        }
    }

    public var textBinding: String? {
        get {
            switch payload {
            case .text(let value): value.binding
            case .button(let value): value.binding
            default: formatV1Residual.textBinding
            }
        }
        set {
            switch payload {
            case .text(var value): value.binding = newValue; payload = .text(value)
            case .button(var value): value.binding = newValue; payload = .button(value)
            default: formatV1Residual.textBinding = newValue
            }
        }
    }

    public var emittedEvent: String? {
        get {
            if case .button(let value) = payload { return value.emittedEvent }
            return formatV1Residual.emittedEvent
        }
        set {
            if case .button(var value) = payload { value.emittedEvent = newValue; payload = .button(value) }
            else { formatV1Residual.emittedEvent = newValue }
        }
    }

    public var assetID: EntityID? {
        get {
            if case .image(let value) = payload { return value.assetID }
            return formatV1Residual.assetID
        }
        set {
            if case .image(var value) = payload { value.assetID = newValue; payload = .image(value) }
            else { formatV1Residual.assetID = newValue }
        }
    }

    public var component: ComponentInstance? {
        get {
            if case .componentInstance(let value) = payload { return value.instance }
            return formatV1Residual.component
        }
        set {
            if case .componentInstance(var value) = payload { value.instance = newValue; payload = .componentInstance(value) }
            else { formatV1Residual.component = newValue }
        }
    }

    public init(id: EntityID, name: String, payload: LayerPayload, children: [Layer] = [], layout: Layout = Layout()) {
        self.id = id; self.name = name; self.payload = payload; self.children = children; self.layout = layout
        interactionID = nil; accessibilityLabel = nil; nativeIntent = nil; targetOverrides = [:]
    }

    public init(id: EntityID, kind: LayerKind, name: String, children: [Layer] = [], layout: Layout = Layout(), text: String? = nil, assetID: EntityID? = nil, component: ComponentInstance? = nil) {
        let payload: LayerPayload
        switch kind {
        case .stack: payload = .stack
        case .overlay: payload = .overlay
        case .scroll: payload = .scroll
        case .text: payload = .text(TextLayerPayload(value: text))
        case .image: payload = .image(ImageLayerPayload(assetID: assetID))
        case .button: payload = .button(ButtonLayerPayload(label: text))
        case .componentInstance: payload = .componentInstance(ComponentInstanceLayerPayload(instance: component))
        }
        self.init(id: id, name: name, payload: payload, children: children, layout: layout)
        if kind != .text && kind != .button { self.text = text }
        if kind != .image { self.assetID = assetID }
        if kind != .componentInstance { self.component = component }
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, children, layout, text, textBinding, emittedEvent, assetID
        case component, interactionID, accessibilityLabel, nativeIntent, targetOverrides
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(EntityID.self, forKey: .id),
            kind: try values.decode(LayerKind.self, forKey: .kind),
            name: try values.decode(String.self, forKey: .name),
            children: try values.decode([Layer].self, forKey: .children),
            layout: try values.decode(Layout.self, forKey: .layout),
            text: try values.decodeIfPresent(String.self, forKey: .text),
            assetID: try values.decodeIfPresent(EntityID.self, forKey: .assetID),
            component: try values.decodeIfPresent(ComponentInstance.self, forKey: .component)
        )
        textBinding = try values.decodeIfPresent(String.self, forKey: .textBinding)
        emittedEvent = try values.decodeIfPresent(String.self, forKey: .emittedEvent)
        interactionID = try values.decodeIfPresent(EntityID.self, forKey: .interactionID)
        accessibilityLabel = try values.decodeIfPresent(String.self, forKey: .accessibilityLabel)
        nativeIntent = try values.decodeIfPresent(String.self, forKey: .nativeIntent)
        targetOverrides = try values.decode([String: String].self, forKey: .targetOverrides)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(kind, forKey: .kind)
        try values.encode(name, forKey: .name)
        try values.encode(children, forKey: .children)
        try values.encode(layout, forKey: .layout)
        try values.encodeIfPresent(text, forKey: .text)
        try values.encodeIfPresent(textBinding, forKey: .textBinding)
        try values.encodeIfPresent(emittedEvent, forKey: .emittedEvent)
        try values.encodeIfPresent(assetID, forKey: .assetID)
        try values.encodeIfPresent(component, forKey: .component)
        try values.encodeIfPresent(interactionID, forKey: .interactionID)
        try values.encodeIfPresent(accessibilityLabel, forKey: .accessibilityLabel)
        try values.encodeIfPresent(nativeIntent, forKey: .nativeIntent)
        try values.encode(targetOverrides, forKey: .targetOverrides)
    }
}

public struct AvailabilityPolicy: Codable, Equatable {
    public var denyScopeIDs: [EntityID]
    public var allowOnlyScopeIDs: [EntityID]
    public init(denyScopeIDs: [EntityID] = [], allowOnlyScopeIDs: [EntityID] = []) {
        self.denyScopeIDs = denyScopeIDs; self.allowOnlyScopeIDs = allowOnlyScopeIDs
    }
}

public struct ComponentAPI: Codable, Equatable {
    public var properties: [ComponentProperty]
    public var slots: [ComponentSlot]
    public var bindings: [String]
    public var events: [String]
    public var overridablePaths: [String]
    public init(properties: [ComponentProperty] = [], slots: [ComponentSlot] = [], bindings: [String] = [], events: [String] = [], overridablePaths: [String] = []) {
        self.properties = properties; self.slots = slots; self.bindings = bindings
        self.events = events; self.overridablePaths = overridablePaths
    }
}

public enum ComponentPropertyKind: String, Codable { case text, number, boolean, asset, token }
public struct ComponentProperty: Codable, Equatable {
    public var name: String
    public var kind: ComponentPropertyKind
    public var targetPath: String
    public init(name: String, kind: ComponentPropertyKind, targetPath: String) {
        self.name = name; self.kind = kind; self.targetPath = targetPath
    }
}
public struct ComponentSlot: Codable, Equatable {
    public var name: String
    public var targetLayerID: EntityID
    public init(name: String, targetLayerID: EntityID) {
        self.name = name; self.targetLayerID = targetLayerID
    }
}

public struct ComponentVariant: Codable, Equatable, Identifiable {
    public var id: EntityID
    public var axis: String
    public var value: String
    public var propertyOverrides: [String: String]
    public init(id: EntityID, axis: String, value: String, propertyOverrides: [String: String] = [:]) {
        self.id = id; self.axis = axis; self.value = value; self.propertyOverrides = propertyOverrides
    }
}

public struct ComponentDefinition: Codable, Equatable, Identifiable {
    public var id: EntityID
    public var name: String
    public var ownerScopeID: EntityID
    public var visibility: String
    public var availability: AvailabilityPolicy
    public var api: ComponentAPI
    public var variants: [ComponentVariant]
    public var root: Layer
    public var nativeSemantics: [String: String]
    public init(id: EntityID, name: String, ownerScopeID: EntityID, root: Layer) {
        self.id = id; self.name = name; self.ownerScopeID = ownerScopeID
        visibility = "public"; availability = AvailabilityPolicy(); api = ComponentAPI()
        variants = []; self.root = root; nativeSemantics = [:]
    }
}

public enum TokenKind: String, Codable { case color, typography, spacing, radius, border, shadow, opacity, motion }
public enum TokenValue: Codable, Equatable {
    case literal(String)
    case reference(EntityID)
}
public struct DesignToken: Codable, Equatable, Identifiable {
    public var id: EntityID
    public var name: String
    public var kind: TokenKind
    public var ownerScopeID: EntityID
    public var value: TokenValue
    public init(id: EntityID, name: String, kind: TokenKind, ownerScopeID: EntityID, value: TokenValue) {
        self.id = id; self.name = name; self.kind = kind; self.ownerScopeID = ownerScopeID; self.value = value
    }
}

public struct TokenTemplateProvenance: Codable, Equatable {
    public var templateID: String
    public var templateVersion: String
    public var instantiatedAt: String
    public init(templateID: String, templateVersion: String, instantiatedAt: String) {
        self.templateID = templateID; self.templateVersion = templateVersion
        self.instantiatedAt = instantiatedAt
    }
}

public enum AssetSource: Codable, Equatable {
    case repository(path: String)
    case remote(url: String)
    case runtime(binding: String)
    case system(name: String)
    case generated(path: String, provenance: String)
}
public struct Asset: Codable, Equatable, Identifiable {
    public var id: EntityID
    public var name: String
    public var ownerScopeID: EntityID
    public var mediaType: String
    public var source: AssetSource
    public var contentHash: String?
    public var metadata: [String: String]
    public init(id: EntityID, name: String, ownerScopeID: EntityID, mediaType: String, source: AssetSource, contentHash: String? = nil) {
        self.id = id; self.name = name; self.ownerScopeID = ownerScopeID
        self.mediaType = mediaType; self.source = source; self.contentHash = contentHash; metadata = [:]
    }
}

public struct Motion: Codable, Equatable, Identifiable {
    public var id: EntityID
    public var name: String
    public var kind: String
    public var parameters: [String: String]
}
public struct Transition: Codable, Equatable {
    public var from: String
    public var event: String
    public var to: String
    public var motionID: EntityID?
    public var actions: [InteractionAction]
    public init(from: String, event: String, to: String, motionID: EntityID? = nil, actions: [InteractionAction] = []) {
        self.from = from; self.event = event; self.to = to; self.motionID = motionID; self.actions = actions
    }
}
public enum InteractionAction: Codable, Equatable {
    case emitEvent(String)
    case setValue(binding: String, value: String)
    case navigate(destination: String)
    case present(destination: String)
    case dismiss
    case openURL(String)
}
public struct Interaction: Codable, Equatable, Identifiable {
    public var id: EntityID
    public var name: String
    public var states: [String]
    public var transitions: [Transition]
    public init(id: EntityID, name: String, states: [String], transitions: [Transition]) {
        self.id = id; self.name = name; self.states = states; self.transitions = transitions
    }
}
public struct PreviewFixture: Codable, Equatable, Identifiable {
    public var id: EntityID
    public var name: String
    public var values: [String: String]
    public var assetBindings: [String: EntityID]
}

public struct AuthoringHarness: Codable, Equatable {
    public var requireAccessibleControls: Bool
    public var requireTokenSpacing: Bool
    public var maximumMutationNodes: Int
    public init(requireAccessibleControls: Bool = true, requireTokenSpacing: Bool = false, maximumMutationNodes: Int = 100) {
        self.requireAccessibleControls = requireAccessibleControls
        self.requireTokenSpacing = requireTokenSpacing
        self.maximumMutationNodes = maximumMutationNodes
    }
}
