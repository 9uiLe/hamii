import Foundation

public enum ComponentResolutionError: Error, CustomStringConvertible {
    case unknownVariant(String, String)
    case conflictingVariants(String)
    case forbiddenOverride(String)
    case unknownPath(String)
    case unknownProperty(String)
    case unknownSlot(String)

    public var description: String {
        switch self {
        case .unknownVariant(let axis, let value): return "Unknown variant \(axis)=\(value)"
        case .conflictingVariants(let path): return "Variants both write \(path)"
        case .forbiddenOverride(let path): return "Override is not public API: \(path)"
        case .unknownPath(let path): return "Unknown property path: \(path)"
        case .unknownProperty(let name): return "Unknown component property: \(name)"
        case .unknownSlot(let name): return "Unknown component slot: \(name)"
        }
    }
}

public enum ComponentResolver {
    public static func resolve(_ instance: ComponentInstance, definition: ComponentDefinition) throws -> Layer {
        var resolved = definition.root
        var variantPaths = Set<String>()
        for axis in instance.variantSelection.keys.sorted() {
            let value = instance.variantSelection[axis]!
            guard let variant = definition.variants.first(where: { $0.axis == axis && $0.value == value }) else {
                throw ComponentResolutionError.unknownVariant(axis, value)
            }
            for (path, text) in variant.propertyOverrides.sorted(by: { $0.key < $1.key }) {
                guard variantPaths.insert(path).inserted else { throw ComponentResolutionError.conflictingVariants(path) }
                guard apply(text, at: path, in: &resolved) else { throw ComponentResolutionError.unknownPath(path) }
            }
        }
        for (name, value) in instance.propertyValues.sorted(by: { $0.key < $1.key }) {
            guard let property = definition.api.properties.first(where: { $0.name == name }) else {
                throw ComponentResolutionError.unknownProperty(name)
            }
            guard property.kind == .text, apply(value, at: property.targetPath, in: &resolved) else {
                throw ComponentResolutionError.unknownPath(property.targetPath)
            }
        }
        for (name, children) in instance.slotContent.sorted(by: { $0.key < $1.key }) {
            guard let slot = definition.api.slots.first(where: { $0.name == name }) else {
                throw ComponentResolutionError.unknownSlot(name)
            }
            guard replaceChildren(children, at: slot.targetLayerID, in: &resolved) else {
                throw ComponentResolutionError.unknownSlot(name)
            }
        }
        for (path, text) in instance.allowedOverrides.sorted(by: { $0.key < $1.key }) {
            guard definition.api.overridablePaths.contains(path) else { throw ComponentResolutionError.forbiddenOverride(path) }
            guard apply(text, at: path, in: &resolved) else { throw ComponentResolutionError.unknownPath(path) }
        }
        return resolved
    }

    private static func replaceChildren(_ children: [Layer], at id: EntityID, in layer: inout Layer) -> Bool {
        if layer.id == id {
            guard layer.kind == .stack || layer.kind == .overlay || layer.kind == .scroll else { return false }
            layer.children = children
            return true
        }
        for index in layer.children.indices {
            if replaceChildren(children, at: id, in: &layer.children[index]) { return true }
        }
        return false
    }

    private static func apply(_ text: String, at path: String, in layer: inout Layer) -> Bool {
        let parts = path.split(separator: ".").map(String.init)
        guard parts.count == 2, parts[1] == "text" else { return false }
        if layer.id.rawValue == parts[0] {
            guard layer.kind == .text || layer.kind == .button else { return false }
            layer.text = text
            return true
        }
        for index in layer.children.indices {
            if apply(text, at: path, in: &layer.children[index]) { return true }
        }
        return false
    }
}
