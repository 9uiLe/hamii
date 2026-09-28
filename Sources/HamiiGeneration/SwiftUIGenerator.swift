import Foundation
import HamiiCore

public enum GenerationError: Error, CustomStringConvertible {
    case invalidDocument([Diagnostic])
    case missingScreen
    case missingTarget
    case unsupported(EntityID, String)

    public var description: String {
        switch self {
        case .invalidDocument(let diagnostics): return diagnostics.map(\.rule).joined(separator: ", ")
        case .missingScreen: return "Screen not found"
        case .missingTarget: return "Target not found"
        case .unsupported(let id, let reason): return "Unsupported at \(id): \(reason)"
        }
    }
}

public struct GeneratedSource: Codable {
    public var targetID: EntityID
    public var screenID: EntityID
    public var source: String
}

public enum SwiftUIGenerator {
    public static func generate(document: Document, screenID: EntityID, targetID: EntityID) throws -> GeneratedSource {
        let diagnostics = DocumentValidator.validate(document)
        if diagnostics.contains(where: { $0.severity == .error }) { throw GenerationError.invalidDocument(diagnostics) }
        guard let screen = document.screens.first(where: { $0.id == screenID }) else { throw GenerationError.missingScreen }
        guard let target = document.targets.first(where: { $0.id == targetID }) else { throw GenerationError.missingTarget }
        if screen.navigation != nil { throw GenerationError.unsupported(screen.id, "Navigation lowering is not available") }
        guard target.framework == .swiftUI, target.platform == .iOS || target.platform == .macOS else {
            throw GenerationError.unsupported(screen.id, "SwiftUI generator supports iOS and macOS targets")
        }
        let typeName = "HamiiScreen_" + screen.id.rawValue.replacingOccurrences(of: "-", with: "_")
        let body = try render(screen.root, document: document, indent: 2)
        let source = "import SwiftUI\n\nstruct \(typeName): View {\n    var body: some View {\n\(body)\n    }\n}\n"
        return GeneratedSource(targetID: targetID, screenID: screenID, source: source)
    }

    private static func render(_ layer: Layer, document: Document, indent: Int) throws -> String {
        let prefix = String(repeating: "    ", count: indent)
        if layer.textBinding != nil { throw GenerationError.unsupported(layer.id, "Runtime binding requires product integration") }
        if layer.interactionID != nil || layer.emittedEvent != nil { throw GenerationError.unsupported(layer.id, "Interaction lowering is not available") }
        if layer.layout.spacingTokenID != nil || layer.layout.paddingTokenID != nil { throw GenerationError.unsupported(layer.id, "Token lowering is not available") }
        if layer.nativeIntent != nil || !layer.targetOverrides.isEmpty { throw GenerationError.unsupported(layer.id, "Native semantics or target override is not mapped") }
        switch layer.payload {
        case .text(let payload):
            return prefix + "Text(\(String(reflecting: payload.value ?? "")))"
        case .button(let payload):
            return prefix + "Button(\(String(reflecting: payload.label ?? "Button"))) { }"
        case .image(let payload):
            guard let id = payload.assetID, let asset = document.assets.first(where: { $0.id == id }), case .system(let name) = asset.source else {
                throw GenerationError.unsupported(layer.id, "Only system image assets can be generated")
            }
            return prefix + "Image(systemName: \(String(reflecting: name)))"
        case .stack, .overlay, .scroll:
            let open: String
            if case .overlay = layer.payload { open = "ZStack {" }
            else if case .scroll = layer.payload { open = "ScrollView {" }
            else { open = layer.layout.axis == .horizontal ? "HStack {" : "VStack {" }
            let children = try layer.children.map { try render($0, document: document, indent: indent + 1) }.joined(separator: "\n")
            return prefix + open + "\n" + children + "\n" + prefix + "}"
        case .componentInstance(let payload):
            guard let instance = payload.instance, let definition = document.components.first(where: { $0.id == instance.definitionID }) else {
                throw GenerationError.unsupported(layer.id, "Component definition is missing")
            }
            let resolved = try ComponentResolver.resolve(instance, definition: definition)
            return try render(resolved, document: document, indent: indent)
        }
    }
}
