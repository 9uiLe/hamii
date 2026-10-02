import Foundation

public enum ComponentResolutionError: Error, Equatable, CustomStringConvertible {
    case unknownVariant(String, String)
    case conflictingVariants(String)
    case overlappingSlots([String])
    case slotWriteConflict(path: String, slotName: String)
    case forbiddenOverride(String)
    case unknownPath(String)
    case unknownProperty(String)
    case unknownSlot(String)

    public var description: String {
        switch self {
        case .unknownVariant(let axis, let value): return "Unknown variant \(axis)=\(value)"
        case .conflictingVariants(let path): return "Variants both write \(path)"
        case .overlappingSlots(let names): return "Selected slots overlap: \(names.joined(separator: ", "))"
        case .slotWriteConflict(let path, let slotName):
            return "Selected write \(path) is removed by slot \(slotName)"
        case .forbiddenOverride(let path): return "Override is not public API: \(path)"
        case .unknownPath(let path): return "Unknown property path: \(path)"
        case .unknownProperty(let name): return "Unknown component property: \(name)"
        case .unknownSlot(let name): return "Unknown component slot: \(name)"
        }
    }
}

public enum ComponentResolver {
    public static func resolve(_ instance: ComponentInstance, definition: ComponentDefinition) throws -> Layer {
        let selectedVariants = try preflight(instance, definition: definition)
        var resolved = definition.root
        for variant in selectedVariants {
            for (path, text) in variant.propertyOverrides.sorted(by: { $0.key < $1.key }) {
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

    private struct SelectedSlot {
        let name: String
        let targetID: EntityID
    }

    /// Resolve the instance API and cross-stage conflicts before changing any
    /// Layer. Empty slot contents still select a replacement.
    private static func preflight(_ instance: ComponentInstance,
                                  definition: ComponentDefinition) throws -> [ComponentVariant] {
        var variants: [ComponentVariant] = []
        var variantPaths: [String] = []
        for (axis, value) in instance.variantSelection.sorted(by: { $0.key < $1.key }) {
            guard let variant = definition.variants.first(where: { $0.axis == axis && $0.value == value }) else {
                throw ComponentResolutionError.unknownVariant(axis, value)
            }
            for path in variant.propertyOverrides.keys.sorted() {
                variantPaths.append(path)
            }
            variants.append(variant)
        }

        var propertyPaths: [String] = []
        for name in instance.propertyValues.keys.sorted() {
            guard let property = definition.api.properties.first(where: { $0.name == name }) else {
                throw ComponentResolutionError.unknownProperty(name)
            }
            if property.kind == .text { propertyPaths.append(property.targetPath) }
        }

        var slots: [SelectedSlot] = []
        for name in instance.slotContent.keys.sorted() {
            guard let slot = definition.api.slots.first(where: { $0.name == name }) else {
                throw ComponentResolutionError.unknownSlot(name)
            }
            // A malformed Definition target remains an actual-resolution error.
            // It cannot establish ancestry for the cross-stage preflight.
            if let target = find(slot.targetLayerID, in: definition.root),
               [.stack, .overlay, .scroll].contains(target.kind) {
                slots.append(SelectedSlot(name: name, targetID: slot.targetLayerID))
            }
        }
        for path in instance.allowedOverrides.keys.sorted() where !definition.api.overridablePaths.contains(path) {
            throw ComponentResolutionError.forbiddenOverride(path)
        }

        var seenPaths = Set<String>()
        for path in variantPaths {
            if !seenPaths.insert(path).inserted {
                throw ComponentResolutionError.conflictingVariants(path)
            }
        }

        var overlapping = Set<String>()
        for first in slots.indices {
            for second in slots.indices where second > first {
                let a = slots[first], b = slots[second]
                if a.targetID == b.targetID ||
                    strictlyContains(b.targetID, below: a.targetID, in: definition.root) ||
                    strictlyContains(a.targetID, below: b.targetID, in: definition.root) {
                    overlapping.insert(a.name)
                    overlapping.insert(b.name)
                }
            }
        }
        if !overlapping.isEmpty { throw ComponentResolutionError.overlappingSlots(overlapping.sorted()) }

        for path in Set(variantPaths + propertyPaths).sorted() {
            guard supportsTextPath(path, in: definition.root) else { continue }
            let pieces = path.split(separator: ".").map(String.init)
            let writeID = EntityID(pieces[0])
            for slot in slots where strictlyContains(writeID, below: slot.targetID, in: definition.root) {
                throw ComponentResolutionError.slotWriteConflict(path: path, slotName: slot.name)
            }
        }
        return variants
    }

    private static func find(_ id: EntityID, in layer: Layer) -> Layer? {
        if layer.id == id { return layer }
        for child in layer.children {
            if let found = find(id, in: child) { return found }
        }
        return nil
    }

    private static func supportsTextPath(_ path: String, in root: Layer) -> Bool {
        let pieces = path.split(separator: ".").map(String.init)
        guard pieces.count == 2, pieces[1] == "text",
              let target = find(EntityID(pieces[0]), in: root) else { return false }
        return target.kind == .text || target.kind == .button
    }

    private static func strictlyContains(_ descendantID: EntityID, below ancestorID: EntityID,
                                         in root: Layer) -> Bool {
        guard let ancestor = find(ancestorID, in: root) else { return false }
        func contains(_ layer: Layer) -> Bool {
            layer.id == descendantID || layer.children.contains(where: contains)
        }
        return ancestor.children.contains(where: contains)
    }

    private static func replaceChildren(_ children: [Layer], at id: EntityID, in layer: inout Layer) -> Bool {
        if layer.id == id {
            switch layer.payload {
            case .stack, .overlay, .scroll: break
            default: return false
            }
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
            switch layer.payload {
            case .text(var payload): payload.value = text; layer.payload = .text(payload)
            case .button(var payload): payload.label = text; layer.payload = .button(payload)
            default: return false
            }
            return true
        }
        for index in layer.children.indices {
            if apply(text, at: path, in: &layer.children[index]) { return true }
        }
        return false
    }
}
