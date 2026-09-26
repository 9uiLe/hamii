import Foundation
import HamiiCore

public enum Author: String, Codable { case human, agent }

public struct HumanHarness {
    public var snapToGrid: Bool
    public var defaultInsertionScopeID: EntityID?
    public init(snapToGrid: Bool = true, defaultInsertionScopeID: EntityID? = nil) {
        self.snapToGrid = snapToGrid; self.defaultInsertionScopeID = defaultInsertionScopeID
    }
}

public struct AgentHarness: Codable, Equatable {
    public var profileName: String
    public var maximumMutations: Int
    public var mayPromoteScope: Bool
    public init(profileName: String, maximumMutations: Int = 100, mayPromoteScope: Bool = false) {
        self.profileName = profileName; self.maximumMutations = maximumMutations
        self.mayPromoteScope = mayPromoteScope
    }
}

public enum AuthoringIntent {
    case createPage(name: String)
    case createScope(name: String, parentID: EntityID)
    case createScreen(name: String, scopeID: EntityID)
    case addTarget(platform: Platform, framework: Framework)
    case addSurface(pageID: EntityID, screenID: EntityID, targetID: EntityID, device: String, runtime: String, buildEnvironment: String)
    case setSurfaceTarget(surfaceID: EntityID, targetID: EntityID)
    case declareCapability(targetID: EntityID, key: CapabilityKey, support: CapabilitySupport)
    case addLayer(screenID: EntityID, parentID: EntityID, kind: LayerKind, name: String, text: String?)
    case addImageLayer(screenID: EntityID, parentID: EntityID, assetID: EntityID, name: String)
    case createRepositoryAsset(name: String, scopeID: EntityID, mediaType: String, path: String, contentHash: String)
    case setText(screenID: EntityID, layerID: EntityID, text: String)
    case createToken(name: String, kind: TokenKind, scopeID: EntityID, value: TokenValue)
    case setLayoutToken(screenID: EntityID, layerID: EntityID, property: LayoutTokenProperty, tokenID: EntityID?)
    case createComponent(name: String, scopeID: EntityID)
    case instantiate(screenID: EntityID, parentID: EntityID, definitionID: EntityID)
    case promoteComponent(definitionID: EntityID, newOwnerID: EntityID)
}

public enum LayoutTokenProperty: String {
    case spacing, padding
}

public struct SemanticPatch: Codable, Equatable {
    public var entityID: EntityID
    public var path: String
    public var oldValue: String?
    public var newValue: String?
    public init(entityID: EntityID, path: String, oldValue: String?, newValue: String?) {
        self.entityID = entityID; self.path = path; self.oldValue = oldValue; self.newValue = newValue
    }
}

public struct MutationResult: Codable {
    public var revision: Int
    public var patches: [SemanticPatch]
    public var diagnostics: [Diagnostic]
    public var statePrecondition: ClientPrecondition?
}

public enum AuthoringError: Error, CustomStringConvertible {
    case staleRevision(expected: Int, actual: Int)
    case staleState
    case notFound(String)
    case approvalRequired(String)
    case validation([Diagnostic])
    case mutationLimit

    public var description: String {
        switch self {
        case .staleRevision(let expected, let actual): return "Expected revision \(expected), found \(actual)"
        case .staleState: return "Client state precondition does not match the current Canonical observation"
        case .notFound(let value): return "Not found: \(value)"
        case .approvalRequired(let value): return "Approval required: \(value)"
        case .validation(let diagnostics): return diagnostics.map { "\($0.rule): \($0.message)" }.joined(separator: "; ")
        case .mutationLimit: return "Mutation limit exceeded"
        }
    }
}

public enum MutationEngine {
    public static func apply(_ intent: AuthoringIntent, to current: Document, expectedRevision: Int, author: Author, agent: AgentHarness? = nil) throws -> (Document, MutationResult) {
        try apply([intent], to: current, expectedRevision: expectedRevision, author: author, agent: agent)
    }

    public static func apply(_ intents: [AuthoringIntent], to current: Document, expectedRevision: Int, author: Author, agent: AgentHarness? = nil) throws -> (Document, MutationResult) {
        guard current.revision == expectedRevision else {
            throw AuthoringError.staleRevision(expected: expectedRevision, actual: current.revision)
        }
        guard !intents.isEmpty, intents.count <= current.authoringHarness.maximumMutationNodes else { throw AuthoringError.mutationLimit }
        if author == .agent, (agent?.maximumMutations ?? 0) < intents.count { throw AuthoringError.mutationLimit }
        var document = current
        var patches: [SemanticPatch] = []
        for intent in intents {
        switch intent {
        case .createPage(let name):
            let page = Page(id: .new("page"), name: name)
            document.pages.append(page)
            patches.append(SemanticPatch(entityID: page.id, path: "pages", oldValue: nil, newValue: name))
        case .createScope(let name, let parentID):
            guard document.scopes.contains(where: { $0.id == parentID }) else { throw AuthoringError.notFound(parentID.rawValue) }
            let scope = ArchitectureScope(id: .new("scope"), name: name, parentID: parentID)
            document.scopes.append(scope)
            patches.append(SemanticPatch(entityID: scope.id, path: "scopes", oldValue: nil, newValue: name))
        case .createScreen(let name, let scopeID):
            guard document.scopes.contains(where: { $0.id == scopeID }) else { throw AuthoringError.notFound(scopeID.rawValue) }
            let root = Layer(id: .new("layer"), kind: .stack, name: "Root", layout: Layout(axis: .vertical))
            let screen = Screen(id: .new("screen"), name: name, scopeID: scopeID, root: root)
            document.screens.append(screen)
            patches.append(SemanticPatch(entityID: screen.id, path: "screens", oldValue: nil, newValue: name))
        case .addTarget(let platform, let framework):
            let target = Target(id: .new("target"), platform: platform, framework: framework)
            document.targets.append(target)
            patches.append(SemanticPatch(entityID: target.id, path: "targets", oldValue: nil, newValue: "\(platform.rawValue).\(framework.rawValue)"))
        case .addSurface(let pageID, let screenID, let targetID, let device, let runtime, let buildEnvironment):
            guard let pageIndex = document.pages.firstIndex(where: { $0.id == pageID }) else { throw AuthoringError.notFound(pageID.rawValue) }
            guard let screen = document.screens.first(where: { $0.id == screenID }) else { throw AuthoringError.notFound(screenID.rawValue) }
            guard document.targets.contains(where: { $0.id == targetID }) else { throw AuthoringError.notFound(targetID.rawValue) }
            let surface = AppSurface(id: .new("surface"), targetID: targetID, device: device, runtime: runtime, buildEnvironment: buildEnvironment, screenID: screenID, architectureScopeID: screen.scopeID)
            document.pages[pageIndex].surfaces.append(surface)
            patches.append(SemanticPatch(entityID: surface.id, path: "pages.surfaces", oldValue: nil, newValue: screenID.rawValue))
        case .setSurfaceTarget(let surfaceID, let targetID):
            guard document.targets.contains(where: { $0.id == targetID }) else { throw AuthoringError.notFound(targetID.rawValue) }
            guard let pageIndex = document.pages.firstIndex(where: { $0.surfaces.contains(where: { $0.id == surfaceID }) }),
                  let surfaceIndex = document.pages[pageIndex].surfaces.firstIndex(where: { $0.id == surfaceID }) else {
                throw AuthoringError.notFound(surfaceID.rawValue)
            }
            let old = document.pages[pageIndex].surfaces[surfaceIndex].targetID
            document.pages[pageIndex].surfaces[surfaceIndex].targetID = targetID
            patches.append(SemanticPatch(entityID: surfaceID, path: "targetID", oldValue: old.rawValue, newValue: targetID.rawValue))
        case .declareCapability(let targetID, let key, let support):
            guard document.targets.contains(where: { $0.id == targetID }) else { throw AuthoringError.notFound(targetID.rawValue) }
            let index = document.capabilityDeclarations.firstIndex(where: { $0.targetID == targetID && $0.key == key })
            let old = index.map { document.capabilityDeclarations[$0].support.rawValue }
            let declaration = CapabilityDeclaration(targetID: targetID, key: key, support: support)
            if let index { document.capabilityDeclarations[index] = declaration }
            else { document.capabilityDeclarations.append(declaration) }
            patches.append(SemanticPatch(entityID: targetID, path: "capabilities.\(key.rawValue)", oldValue: old, newValue: support.rawValue))
        case .addLayer(let screenID, let parentID, let kind, let name, let text):
            guard let screenIndex = document.screens.firstIndex(where: { $0.id == screenID }) else { throw AuthoringError.notFound(screenID.rawValue) }
            var layer = Layer(id: .new("layer"), kind: kind, name: name, text: text)
            if kind == .stack { layer.layout.axis = .vertical }
            guard append(layer, to: &document.screens[screenIndex].root, parentID: parentID) else { throw AuthoringError.notFound(parentID.rawValue) }
            patches.append(SemanticPatch(entityID: layer.id, path: "children", oldValue: nil, newValue: kind.rawValue))
        case .addImageLayer(let screenID, let parentID, let assetID, let name):
            guard let screenIndex = document.screens.firstIndex(where: { $0.id == screenID }) else { throw AuthoringError.notFound(screenID.rawValue) }
            let layer = Layer(id: .new("layer"), kind: .image, name: name, assetID: assetID)
            guard append(layer, to: &document.screens[screenIndex].root, parentID: parentID) else { throw AuthoringError.notFound(parentID.rawValue) }
            patches.append(SemanticPatch(entityID: layer.id, path: "assetID", oldValue: nil, newValue: assetID.rawValue))
        case .createRepositoryAsset(let name, let scopeID, let mediaType, let path, let contentHash):
            guard document.scopes.contains(where: { $0.id == scopeID }) else { throw AuthoringError.notFound(scopeID.rawValue) }
            let asset = Asset(id: .new("asset"), name: name, ownerScopeID: scopeID, mediaType: mediaType, source: .repository(path: path), contentHash: contentHash)
            document.assets.append(asset)
            patches.append(SemanticPatch(entityID: asset.id, path: "assets", oldValue: nil, newValue: path))
        case .setText(let screenID, let layerID, let text):
            guard let screenIndex = document.screens.firstIndex(where: { $0.id == screenID }) else { throw AuthoringError.notFound(screenID.rawValue) }
            guard let old = setText(text, in: &document.screens[screenIndex].root, id: layerID) else { throw AuthoringError.notFound(layerID.rawValue) }
            patches.append(SemanticPatch(entityID: layerID, path: "text", oldValue: old, newValue: text))
        case .createToken(let name, let kind, let scopeID, let value):
            guard document.scopes.contains(where: { $0.id == scopeID }) else { throw AuthoringError.notFound(scopeID.rawValue) }
            let token = DesignToken(id: .new("token"), name: name, kind: kind, ownerScopeID: scopeID, value: value)
            document.tokens.append(token)
            patches.append(SemanticPatch(entityID: token.id, path: "tokens", oldValue: nil, newValue: name))
        case .setLayoutToken(let screenID, let layerID, let property, let tokenID):
            guard let screenIndex = document.screens.firstIndex(where: { $0.id == screenID }) else { throw AuthoringError.notFound(screenID.rawValue) }
            guard let old = setLayoutToken(tokenID, property: property, in: &document.screens[screenIndex].root, id: layerID) else {
                throw AuthoringError.notFound(layerID.rawValue)
            }
            patches.append(SemanticPatch(entityID: layerID, path: "layout.\(property.rawValue)TokenID", oldValue: old?.rawValue, newValue: tokenID?.rawValue))
        case .createComponent(let name, let scopeID):
            guard document.scopes.contains(where: { $0.id == scopeID }) else { throw AuthoringError.notFound(scopeID.rawValue) }
            let root = Layer(id: .new("layer"), kind: .stack, name: "Root", layout: Layout(axis: .vertical))
            let definition = ComponentDefinition(id: .new("component"), name: name, ownerScopeID: scopeID, root: root)
            document.components.append(definition)
            patches.append(SemanticPatch(entityID: definition.id, path: "components", oldValue: nil, newValue: name))
        case .instantiate(let screenID, let parentID, let definitionID):
            guard let screenIndex = document.screens.firstIndex(where: { $0.id == screenID }) else { throw AuthoringError.notFound(screenID.rawValue) }
            guard let definition = document.components.first(where: { $0.id == definitionID }) else { throw AuthoringError.notFound(definitionID.rawValue) }
            let layer = Layer(id: .new("layer"), kind: .componentInstance, name: definition.name, component: ComponentInstance(definitionID: definitionID))
            guard append(layer, to: &document.screens[screenIndex].root, parentID: parentID) else { throw AuthoringError.notFound(parentID.rawValue) }
            patches.append(SemanticPatch(entityID: layer.id, path: "component.definitionID", oldValue: nil, newValue: definitionID.rawValue))
        case .promoteComponent(let definitionID, let newOwnerID):
            guard author == .human || agent?.mayPromoteScope == true else { throw AuthoringError.approvalRequired("component scope promotion") }
            guard let index = document.components.firstIndex(where: { $0.id == definitionID }) else { throw AuthoringError.notFound(definitionID.rawValue) }
            guard document.scopes.contains(where: { $0.id == newOwnerID }) else { throw AuthoringError.notFound(newOwnerID.rawValue) }
            let old = document.components[index].ownerScopeID
            guard ScopeEvaluator(document.scopes).canUse(owner: newOwnerID, consumer: old) else {
                throw AuthoringError.validation([Diagnostic("component.promotionDirection", "New owner must be an ancestor of the current owner", entityID: definitionID)])
            }
            document.components[index].ownerScopeID = newOwnerID
            patches.append(SemanticPatch(entityID: definitionID, path: "ownerScopeID", oldValue: old.rawValue, newValue: newOwnerID.rawValue))
        }
        }
        let diagnostics = DocumentValidator.validate(document)
        if diagnostics.contains(where: { $0.severity == .error }) { throw AuthoringError.validation(diagnostics) }
        if document == current {
            return (current, MutationResult(revision: current.revision, patches: [], diagnostics: diagnostics))
        }
        document.revision += 1
        return (document, MutationResult(revision: document.revision, patches: patches, diagnostics: diagnostics))
    }

    private static func append(_ child: Layer, to root: inout Layer, parentID: EntityID) -> Bool {
        if root.id == parentID { root.children.append(child); return true }
        for index in root.children.indices {
            if append(child, to: &root.children[index], parentID: parentID) { return true }
        }
        return false
    }

    private static func setText(_ value: String, in root: inout Layer, id: EntityID) -> String? {
        if root.id == id {
            guard root.kind == .text || root.kind == .button else { return nil }
            let old = root.text ?? ""
            root.text = value
            return old
        }
        for index in root.children.indices {
            if let old = setText(value, in: &root.children[index], id: id) { return old }
        }
        return nil
    }

    private static func setLayoutToken(_ tokenID: EntityID?, property: LayoutTokenProperty, in root: inout Layer, id: EntityID) -> EntityID?? {
        if root.id == id {
            guard [.stack, .overlay, .scroll].contains(root.kind) else { return nil }
            switch property {
            case .spacing:
                guard root.kind == .stack else { return nil }
                let old = root.layout.spacingTokenID
                root.layout.spacingTokenID = tokenID
                return .some(old)
            case .padding:
                let old = root.layout.paddingTokenID
                root.layout.paddingTokenID = tokenID
                return .some(old)
            }
        }
        for index in root.children.indices {
            if let old = setLayoutToken(tokenID, property: property, in: &root.children[index], id: id) { return old }
        }
        return nil
    }
}
