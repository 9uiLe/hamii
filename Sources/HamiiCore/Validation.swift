import Foundation

public struct Diagnostic: Codable, Equatable, Sendable {
    public enum Severity: String, Codable, Sendable { case error, warning }
    public var rule: String
    public var severity: Severity
    public var entityID: EntityID?
    public var message: String
    public init(_ rule: String, _ message: String, entityID: EntityID? = nil, severity: Severity = .error) {
        self.rule = rule; self.message = message; self.entityID = entityID; self.severity = severity
    }
}

public struct ScopeEvaluator {
    private let scopes: [EntityID: ArchitectureScope]
    public init(_ scopes: [ArchitectureScope]) {
        self.scopes = Dictionary(scopes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func ancestorsIncludingSelf(of id: EntityID) -> [EntityID]? {
        var result: [EntityID] = []
        var next: EntityID? = id
        while let current = next {
            guard let scope = scopes[current], !result.contains(current) else { return nil }
            result.append(current)
            next = scope.parentID
        }
        return result
    }

    public func canUse(owner: EntityID, consumer: EntityID) -> Bool {
        ancestorsIncludingSelf(of: consumer)?.contains(owner) == true
    }

    public func leastCommonAncestor(_ consumers: [EntityID]) -> EntityID? {
        guard let first = consumers.first, let chain = ancestorsIncludingSelf(of: first) else { return nil }
        return chain.first { candidate in
            consumers.dropFirst().allSatisfy { ancestorsIncludingSelf(of: $0)?.contains(candidate) == true }
        }
    }
}

public enum ComponentAvailability {
    public static func reason(_ definition: ComponentDefinition, consumer: EntityID, scopes: ScopeEvaluator, definitions: [EntityID: ComponentDefinition]) -> String? {
        reason(definition, consumer: consumer, scopes: scopes, definitions: definitions, path: [])
    }

    private static func reason(_ definition: ComponentDefinition, consumer: EntityID, scopes: ScopeEvaluator, definitions: [EntityID: ComponentDefinition], path: Set<EntityID>) -> String? {
        guard !path.contains(definition.id) else { return "component.cycle" }
        guard scopes.canUse(owner: definition.ownerScopeID, consumer: consumer) else { return "scope.notAncestor" }
        if definition.availability.denyScopeIDs.contains(consumer) { return "component.denied" }
        if !definition.availability.allowOnlyScopeIDs.isEmpty && !definition.availability.allowOnlyScopeIDs.contains(consumer) {
            return "component.notAllowed"
        }
        for dependencyID in dependencies(in: definition.root) {
            guard let dependency = definitions[dependencyID] else { return "component.missing" }
            if let rule = reason(dependency, consumer: consumer, scopes: scopes, definitions: definitions, path: path.union([definition.id])) {
                return rule
            }
        }
        return nil
    }

    private static func dependencies(in layer: Layer) -> [EntityID] {
        var result = layer.component.map { [$0.definitionID] } ?? []
        for child in layer.children { result += dependencies(in: child) }
        if let instance = layer.component {
            for name in instance.slotContent.keys.sorted() {
                for child in instance.slotContent[name] ?? [] { result += dependencies(in: child) }
            }
        }
        return result
    }
}

public enum DocumentValidator {
    public static func validate(_ document: Document) -> [Diagnostic] {
        var errors: [Diagnostic] = []
        var ids = Set<EntityID>()
        func checkID(_ id: EntityID) {
            if id.rawValue.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) == nil {
                errors.append(Diagnostic("identity.invalid", "Stable ID contains unsupported characters", entityID: id))
            }
            if !ids.insert(id).inserted { errors.append(Diagnostic("identity.duplicate", "Duplicate stable ID", entityID: id)) }
        }
        checkID(document.id)
        let scopes = ScopeEvaluator(document.scopes)
        let scopeIDs = Set(document.scopes.map(\.id))
        let tokenMap = Dictionary(document.tokens.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let assetMap = Dictionary(document.assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let componentMap = Dictionary(document.components.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let interactionIDs = Set(document.interactions.map(\.id))

        for scope in document.scopes {
            checkID(scope.id)
            if scopes.ancestorsIncludingSelf(of: scope.id) == nil {
                errors.append(Diagnostic("scope.invalidTree", "Scope parent is missing or cyclic", entityID: scope.id))
            }
        }
        if document.scopes.filter({ $0.parentID == nil }).count != 1 {
            errors.append(Diagnostic("scope.root", "Exactly one root ArchitectureScope is required"))
        }

        func checkLayer(_ layer: Layer, consumer: EntityID) {
            checkID(layer.id)
            switch layer.payload {
            case .text(let payload) where payload.value == nil:
                errors.append(Diagnostic("layer.textRequired", "Text and button layers require text", entityID: layer.id))
            case .button(let payload) where payload.label == nil:
                errors.append(Diagnostic("layer.textRequired", "Text and button layers require text", entityID: layer.id))
            case .image(let payload) where payload.assetID == nil:
                errors.append(Diagnostic("layer.assetRequired", "Image layers require an asset reference", entityID: layer.id))
            case .componentInstance(let payload) where payload.instance == nil:
                errors.append(Diagnostic("component.instanceRequired", "Component instance data is required", entityID: layer.id))
            default: break
            }
            if layer.textBinding == "" { errors.append(Diagnostic("binding.empty", "Text binding path is empty", entityID: layer.id)) }
            if layer.emittedEvent == "" { errors.append(Diagnostic("event.empty", "Emitted event name is empty", entityID: layer.id)) }
            if document.authoringHarness.requireAccessibleControls && layer.kind == .button && (layer.accessibilityLabel ?? layer.text ?? "").isEmpty {
                errors.append(Diagnostic("accessibility.controlLabel", "Button requires an accessible label", entityID: layer.id))
            }
            if document.authoringHarness.requireTokenSpacing && layer.layout.axis != nil && layer.layout.spacingTokenID == nil {
                errors.append(Diagnostic("token.spacingRequired", "Stack spacing must reference a token", entityID: layer.id))
            }
            if layer.layout.spacingTokenID != nil && layer.kind != .stack {
                errors.append(Diagnostic("layout.spacingKind", "Stack spacing is unavailable for this Layer kind", entityID: layer.id))
            }
            let effectTokenIDs = layer.effects.map(\.tokenID)
            for tokenID in [layer.layout.spacingTokenID].compactMap({ $0 }) + effectTokenIDs {
                guard let token = tokenMap[tokenID] else {
                    errors.append(Diagnostic("token.missing", "Token reference is missing", entityID: layer.id)); continue
                }
                if token.kind != .spacing || TokenResolver.spacing(tokenID, in: document.tokens) == nil {
                    errors.append(Diagnostic("token.layoutValue", "Layout token must resolve to a nonnegative spacing value", entityID: layer.id))
                }
                if !scopes.canUse(owner: token.ownerScopeID, consumer: consumer) {
                    errors.append(Diagnostic("scope.token", "Token owner is outside consumer ancestors", entityID: layer.id))
                }
            }
            if let assetID = layer.assetID {
                if let asset = assetMap[assetID] {
                    if !scopes.canUse(owner: asset.ownerScopeID, consumer: consumer) {
                        errors.append(Diagnostic("scope.asset", "Asset owner is outside consumer ancestors", entityID: layer.id))
                    }
                } else {
                    errors.append(Diagnostic("asset.missing", "Asset reference is missing", entityID: layer.id))
                }
            }
            if let instance = layer.component {
                if let definition = componentMap[instance.definitionID] {
                    if let rule = ComponentAvailability.reason(definition, consumer: consumer, scopes: scopes, definitions: componentMap) {
                        errors.append(Diagnostic(rule, "Component is unavailable to this ArchitectureScope", entityID: layer.id))
                    }
                    let variants = Set(definition.variants.map { "\($0.axis)=\($0.value)" })
                    for (axis, value) in instance.variantSelection where !variants.contains("\(axis)=\(value)") {
                        errors.append(Diagnostic("component.variant", "Unknown variant selection", entityID: layer.id))
                    }
                    for key in instance.propertyValues.keys where !definition.api.properties.contains(where: { $0.name == key }) {
                        errors.append(Diagnostic("component.property", "Unknown component property", entityID: layer.id))
                    }
                    for key in instance.slotContent.keys where !definition.api.slots.contains(where: { $0.name == key }) {
                        errors.append(Diagnostic("component.slot", "Unknown component slot", entityID: layer.id))
                    }
                    for key in instance.allowedOverrides.keys where !definition.api.overridablePaths.contains(key) {
                        errors.append(Diagnostic("component.override", "Override path is not public API", entityID: layer.id))
                    }
                    do { _ = try ComponentResolver.resolve(instance, definition: definition) }
                    catch { errors.append(Diagnostic("component.resolution", String(describing: error), entityID: layer.id)) }
                } else {
                    errors.append(Diagnostic("component.missing", "Component definition is missing", entityID: layer.id))
                }
                for name in instance.slotContent.keys.sorted() {
                    for child in instance.slotContent[name] ?? [] { checkLayer(child, consumer: consumer) }
                }
            }
            if let interactionID = layer.interactionID, !interactionIDs.contains(interactionID) {
                errors.append(Diagnostic("interaction.missing", "Interaction reference is missing", entityID: layer.id))
            }
            layer.children.forEach { checkLayer($0, consumer: consumer) }
        }

        for page in document.pages {
            checkID(page.id)
            for surface in page.surfaces {
                checkID(surface.id)
                if surface.device.isEmpty || surface.runtime.isEmpty || surface.buildEnvironment.isEmpty {
                    errors.append(Diagnostic("surface.environment", "Device, Runtime and BuildEnvironment are required", entityID: surface.id))
                }
                if !document.targets.contains(where: { $0.id == surface.targetID }) { errors.append(Diagnostic("surface.target", "Target is missing", entityID: surface.id)) }
                if let target = document.targets.first(where: { $0.id == surface.targetID }),
                   !surface.runtime.hasPrefix(target.platform.rawValue + " ") {
                    errors.append(Diagnostic("surface.runtimePlatform", "Runtime platform does not match the Target", entityID: surface.id))
                }
                if !document.screens.contains(where: { $0.id == surface.screenID }) { errors.append(Diagnostic("surface.screen", "Screen is missing", entityID: surface.id)) }
                if !scopeIDs.contains(surface.architectureScopeID) { errors.append(Diagnostic("surface.scope", "ArchitectureScope is missing", entityID: surface.id)) }
                if let screen = document.screens.first(where: { $0.id == surface.screenID }), screen.scopeID != surface.architectureScopeID {
                    errors.append(Diagnostic("surface.scopeMismatch", "AppSurface and Screen must use the same ArchitectureScope", entityID: surface.id))
                }
                if let fixtureID = surface.fixtureID, !document.fixtures.contains(where: { $0.id == fixtureID }) { errors.append(Diagnostic("surface.fixture", "Fixture is missing", entityID: surface.id)) }
            }
        }
        for screen in document.screens {
            checkID(screen.id)
            if !scopeIDs.contains(screen.scopeID) { errors.append(Diagnostic("screen.scope", "ArchitectureScope is missing", entityID: screen.id)) }
            checkLayer(screen.root, consumer: screen.scopeID)
            if let navigation = screen.navigation {
                switch navigation {
                case .system(let system):
                    for item in system.toolbarItems {
                        checkID(item.id)
                        if item.title.isEmpty || item.emittedEvent.isEmpty {
                            errors.append(Diagnostic("navigation.toolbar", "System toolbar item requires title and event", entityID: item.id))
                        }
                    }
                case .custom(let layerID):
                    func contains(_ root: Layer) -> Bool {
                        root.id == layerID || root.children.contains(where: contains)
                    }
                    if !contains(screen.root) {
                        errors.append(Diagnostic("navigation.customLayer", "Custom navigation layer is missing", entityID: screen.id))
                    }
                }
            }
        }
        for definition in document.components {
            checkID(definition.id)
            if !scopeIDs.contains(definition.ownerScopeID) { errors.append(Diagnostic("component.scope", "ArchitectureScope is missing", entityID: definition.id)) }
            let denied = Set(definition.availability.denyScopeIDs)
            let allowed = Set(definition.availability.allowOnlyScopeIDs)
            if denied.count != definition.availability.denyScopeIDs.count || allowed.count != definition.availability.allowOnlyScopeIDs.count {
                errors.append(Diagnostic("component.availabilityDuplicate", "AvailabilityPolicy has duplicate ArchitectureScope IDs", entityID: definition.id))
            }
            for scopeID in denied.union(allowed) where !scopeIDs.contains(scopeID) {
                errors.append(Diagnostic("component.availabilityScope", "AvailabilityPolicy references a missing ArchitectureScope", entityID: definition.id))
            }
            if !denied.isDisjoint(with: allowed) {
                errors.append(Diagnostic("component.availabilityConflict", "ArchitectureScope cannot be both allowed and denied", entityID: definition.id))
            }
            definition.variants.forEach { checkID($0.id) }
            var variantKeys = Set<String>()
            func findLayer(_ id: EntityID, in layer: Layer) -> Layer? {
                if layer.id == id { return layer }
                for child in layer.children { if let found = findLayer(id, in: child) { return found } }
                return nil
            }
            func isTextPath(_ path: String) -> Bool {
                let parts = path.split(separator: ".").map(String.init)
                guard parts.count == 2, parts[1] == "text",
                      let target = findLayer(EntityID(parts[0]), in: definition.root) else { return false }
                return target.kind == .text || target.kind == .button
            }
            var propertyNames = Set<String>()
            for property in definition.api.properties {
                if !propertyNames.insert(property.name).inserted { errors.append(Diagnostic("component.duplicateProperty", "Duplicate component property", entityID: definition.id)) }
                if property.kind != .text || !isTextPath(property.targetPath) {
                    errors.append(Diagnostic("component.propertyPath", "Property target path is unsupported", entityID: definition.id))
                }
            }
            for path in definition.api.overridablePaths where !isTextPath(path) {
                errors.append(Diagnostic("component.overridePath", "Public override path is unsupported", entityID: definition.id))
            }
            var slotNames = Set<String>()
            for slot in definition.api.slots {
                if !slotNames.insert(slot.name).inserted { errors.append(Diagnostic("component.duplicateSlot", "Duplicate component slot", entityID: definition.id)) }
                guard let target = findLayer(slot.targetLayerID, in: definition.root), [.stack, .overlay, .scroll].contains(target.kind) else {
                    errors.append(Diagnostic("component.slotTarget", "Slot target must be a container layer", entityID: definition.id)); continue
                }
            }
            for variant in definition.variants {
                let key = "\(variant.axis)=\(variant.value)"
                if !variantKeys.insert(key).inserted {
                    errors.append(Diagnostic("component.duplicateVariant", "Duplicate variant axis and value", entityID: definition.id))
                }
                for path in variant.propertyOverrides.keys {
                    if !isTextPath(path) {
                        errors.append(Diagnostic("component.variantPath", "Variant override path is unsupported", entityID: variant.id))
                    }
                }
            }
            checkLayer(definition.root, consumer: definition.ownerScopeID)
        }
        for token in document.tokens {
            checkID(token.id)
            if !scopeIDs.contains(token.ownerScopeID) { errors.append(Diagnostic("token.scope", "ArchitectureScope is missing", entityID: token.id)) }
            if token.name.isEmpty { errors.append(Diagnostic("token.name", "Token name is empty", entityID: token.id)) }
            if token.kind == .spacing, TokenResolver.spacing(token.id, in: document.tokens) == nil {
                errors.append(Diagnostic("token.spacingValue", "Spacing token must resolve to a nonnegative finite number", entityID: token.id))
            }
            if case .reference(let reference) = token.value {
                if let target = tokenMap[reference] {
                    if target.kind != token.kind { errors.append(Diagnostic("token.type", "Token alias kind differs", entityID: token.id)) }
                    if !scopes.canUse(owner: target.ownerScopeID, consumer: token.ownerScopeID) { errors.append(Diagnostic("scope.token", "Token alias crosses Scope boundary", entityID: token.id)) }
                } else { errors.append(Diagnostic("token.missing", "Token alias target is missing", entityID: token.id)) }
            }
            var seen = Set<EntityID>()
            var next: EntityID? = token.id
            while let current = next, let item = tokenMap[current] {
                if !seen.insert(current).inserted { errors.append(Diagnostic("token.cycle", "Token alias cycle", entityID: token.id)); break }
                if case .reference(let target) = item.value { next = target } else { next = nil }
            }
        }
        for asset in document.assets {
            checkID(asset.id)
            if !scopeIDs.contains(asset.ownerScopeID) { errors.append(Diagnostic("asset.scope", "ArchitectureScope is missing", entityID: asset.id)) }
            switch asset.source {
            case .remote(let url):
                guard let parsed = URLComponents(string: url), parsed.scheme?.lowercased() == "https", parsed.host != nil, parsed.user == nil, parsed.password == nil else {
                    errors.append(Diagnostic("asset.remoteURL", "Remote assets require an HTTPS URL without credentials", entityID: asset.id)); break
                }
                let secretKeys = Set(["token", "api_key", "apikey", "secret", "signature"])
                if parsed.queryItems?.contains(where: { secretKeys.contains($0.name.lowercased()) }) == true {
                    errors.append(Diagnostic("asset.secretURL", "Remote asset URL contains a credential parameter", entityID: asset.id))
                }
            case .repository(let path), .generated(let path, _):
                if path.isEmpty || path.hasPrefix("/") || path.split(separator: "/").contains("..") {
                    errors.append(Diagnostic("asset.path", "Asset storage path must be project-relative", entityID: asset.id))
                }
                if let hash = asset.contentHash, hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) == nil {
                    errors.append(Diagnostic("asset.contentHash", "Content hash must be a lowercase SHA-256 digest", entityID: asset.id))
                }
            case .runtime(let binding):
                if binding.isEmpty { errors.append(Diagnostic("asset.binding", "Runtime asset binding is empty", entityID: asset.id)) }
            case .system(let name):
                if name.isEmpty { errors.append(Diagnostic("asset.systemName", "System asset name is empty", entityID: asset.id)) }
            }
        }
        for interaction in document.interactions {
            checkID(interaction.id)
            var eventKeys = Set<String>()
            for transition in interaction.transitions {
                if transition.event.isEmpty { errors.append(Diagnostic("interaction.event", "Transition event is empty", entityID: interaction.id)) }
                if !interaction.states.contains(transition.from) || !interaction.states.contains(transition.to) { errors.append(Diagnostic("interaction.state", "Transition state is missing", entityID: interaction.id)) }
                if let motionID = transition.motionID, !document.motions.contains(where: { $0.id == motionID }) { errors.append(Diagnostic("motion.missing", "Motion reference is missing", entityID: interaction.id)) }
                if !eventKeys.insert("\(transition.from):\(transition.event)").inserted {
                    errors.append(Diagnostic("interaction.ambiguous", "Multiple transitions for one state and event", entityID: interaction.id))
                }
            }
        }
        document.motions.forEach { checkID($0.id) }
        document.fixtures.forEach { checkID($0.id) }
        document.targets.forEach { checkID($0.id) }
        var declarations = Set<String>()
        for declaration in document.capabilityDeclarations {
            if !document.targets.contains(where: { $0.id == declaration.targetID }) {
                errors.append(Diagnostic("capability.target", "Capability target is missing", entityID: declaration.targetID))
            }
            let key = "\(declaration.targetID.rawValue):\(declaration.key.rawValue)"
            if !declarations.insert(key).inserted {
                errors.append(Diagnostic("capability.duplicate", "Duplicate capability declaration", entityID: declaration.targetID))
            }
        }
        return errors
    }
}
