import Foundation

/// Resolves Screen-owned semantic outputs against both definition ownership and
/// the actual Component tree. A resolved Layer ID alone cannot establish
/// ownership: slot content can replace a definition subtree with the same IDs.
enum ScreenSemanticsValidator {
    static func validate(_ screen: Screen, in document: Document) -> [Diagnostic] {
        let semantics = screen.semantics
        var diagnostics: [Diagnostic] = []
        func issue(_ rule: String, _ message: String) {
            diagnostics.append(Diagnostic(rule, message, entityID: screen.id))
        }
        func validKey(_ value: String) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let sources = Dictionary(grouping: semantics.sources, by: \.key)
        let outputs = Dictionary(grouping: semantics.outputs, by: \.key)
        let relations = Dictionary(grouping: semantics.relations, by: \.output)
        for (key, declarations) in sources {
            if !validKey(key.rawValue) { issue("semantics.sourceKey", "Semantic source key must be nonblank and unpadded") }
            if declarations.count != 1 { issue("semantics.duplicateSource", "Semantic source key is duplicated") }
        }
        for (key, declarations) in outputs {
            if !validKey(key.rawValue) { issue("semantics.outputKey", "Semantic output key must be nonblank and unpadded") }
            if declarations.count != 1 { issue("semantics.duplicateOutput", "Semantic output key is duplicated") }
        }

        var physicalAnchors = Set<SemanticOutputAnchor>()
        for output in semantics.outputs {
            if !physicalAnchors.insert(output.anchor).inserted {
                issue("semantics.duplicateAnchor", "Multiple semantic outputs address the same physical Layer property")
            }
            if !validKey(output.binding) {
                issue("semantics.binding", "Semantic output binding must be nonblank and unpadded")
            }
            guard let layer = resolve(output.anchor, screen: screen, in: document) else {
                issue("semantics.anchor", "Semantic output anchor does not address a definition-owned Layer property")
                continue
            }
            if layer.textBinding != output.binding {
                issue("semantics.binding", "Semantic output binding differs from its Layer binding")
            }
        }

        for output in semantics.outputs where relations[output.key]?.count != 1 {
            issue("semantics.relationCount", "Every declared output requires exactly one relation")
        }
        for relation in semantics.relations {
            if outputs[relation.output]?.count != 1 {
                issue("semantics.relationOutput", "Relation references a missing or duplicate output")
            }
            if sources[relation.source]?.count != 1 {
                issue("semantics.relationSource", "Relation references a missing or duplicate source")
            }
            if case .booleanEquals(let key, _) = relation.visibleWhen {
                guard let declarations = sources[key], declarations.count == 1 else {
                    issue("semantics.visibilitySource", "Visibility references a missing or duplicate source")
                    continue
                }
                if declarations[0].valueKind != .boolean {
                    issue("semantics.visibilityType", "Visibility condition requires a Boolean source")
                }
            }
            if relation.transform == .identity,
               let declarations = sources[relation.source], declarations.count == 1,
               declarations[0].valueKind != .text {
                issue("semantics.sourceType", "Identity text output requires a text source")
            }
            if !validKey(relation.transform.rawValue) {
                issue("semantics.transform", "Transform key must be nonblank and unpadded")
            }
        }
        return diagnostics
    }

    private static func paths(to id: EntityID, in root: Layer) -> [[EntityID]] {
        func visit(_ layer: Layer, _ prefix: [EntityID]) -> [[EntityID]] {
            let path = prefix + [layer.id]
            return (layer.id == id ? [path] : []) + layer.children.flatMap { visit($0, path) }
        }
        return visit(root, [])
    }

    private static func layer(at path: [EntityID], in root: Layer) -> Layer? {
        guard path.first == root.id else { return nil }
        var current = root
        for id in path.dropFirst() {
            let matches = current.children.filter { $0.id == id }
            guard matches.count == 1 else { return nil }
            current = matches[0]
        }
        return current
    }

    private static func resolve(_ anchor: SemanticOutputAnchor, screen: Screen, in document: Document) -> Layer? {
        var resolved = screen.root
        var raw = screen.root
        var replacedSlotIDs = Set<EntityID>()
        let targetID: EntityID
        let property: SemanticOutputProperty
        switch anchor {
        case .direct(let id, let field):
            targetID = id
            property = field
        case .component(let frames, let id, let field):
            guard !frames.isEmpty else { return nil }
            targetID = id
            property = field
            for frame in frames {
                guard paths(to: frame.instanceLayerID, in: raw) == [frame.layerPath],
                      paths(to: frame.instanceLayerID, in: resolved) == [frame.layerPath],
                      !frame.layerPath.contains(where: replacedSlotIDs.contains),
                      let instance = layer(at: frame.layerPath, in: resolved)?.component,
                      instance.definitionID == frame.expectedDefinitionID,
                      let definition = document.components.first(where: { $0.id == frame.expectedDefinitionID }),
                      document.components.filter({ $0.id == frame.expectedDefinitionID }).count == 1,
                      let next = try? ComponentResolver.resolve(instance, definition: definition) else { return nil }
                raw = definition.root
                resolved = next
                replacedSlotIDs = Set(definition.api.slots.filter { instance.slotContent[$0.name] != nil }.map(\.targetLayerID))
            }
        }
        guard property == .text,
              let path = paths(to: targetID, in: resolved).only,
              paths(to: targetID, in: raw) == [path],
              !path.contains(where: replacedSlotIDs.contains),
              let target = layer(at: path, in: resolved),
              target.kind == .text || target.kind == .button else { return nil }
        return target
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
