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

/// Only semantics lowered by this generator. Target declarations are evaluated separately.
public enum SwiftUIGeneratorCapabilityCatalog {
    public static let supportedKeys: Set<CapabilityKey> = [
        CapabilityKeys.stackContainer, CapabilityKeys.overlayVisual, CapabilityKeys.scrollContainer,
        CapabilityKeys.textVisual, CapabilityKeys.buttonVisual, CapabilityKeys.imageVisual,
        CapabilityKeys.systemAssetMapping, CapabilityKeys.componentInstance, CapabilityKeys.paddingEffect
    ]
    public static let catalog = CapabilityCatalog(supportedKeys: supportedKeys, legacyAliases: CapabilityRegistry.aliases(for: supportedKeys))
}

public enum SwiftUIGenerator {
    public static func generate(document: Document, screenID: EntityID, targetID: EntityID) throws -> GeneratedSource {
        let diagnostics = DocumentValidator.validate(document)
        if diagnostics.contains(where: { $0.severity == .error }) { throw GenerationError.invalidDocument(diagnostics) }
        guard let screen = document.screens.first(where: { $0.id == screenID }) else { throw GenerationError.missingScreen }
        guard let target = document.targets.first(where: { $0.id == targetID }) else { throw GenerationError.missingTarget }
        guard target.framework == .swiftUI, target.platform == .iOS || target.platform == .macOS else {
            throw GenerationError.unsupported(screen.id, "SwiftUI generator supports iOS and macOS targets")
        }
        let extraction = SemanticRequirementExtractor.extract(screen: screen, document: document)
        if let diagnostic = extraction.diagnostics.first(where: { $0.severity == .error }) {
            throw GenerationError.unsupported(diagnostic.entityID ?? screen.id, diagnostic.message)
        }
        let report = CapabilityEvaluator.evaluate(
            requirements: extraction.requirements,
            profile: CapabilityProfile(target: target),
            declarations: document.capabilityDeclarations,
            catalog: SwiftUIGeneratorCapabilityCatalog.catalog
        )
        if let blocked = report.items.first(where: { !$0.allowed }) {
            let reason = blocked.requirement.key == CapabilityKeys.fixtureBinding
                ? "Runtime binding requires product integration" : "Capability \(blocked.requirement.key): \(blocked.reason)"
            throw GenerationError.unsupported(blocked.requirement.sourceEntityID, reason)
        }
        let typeName = "HamiiScreen_" + screen.id.rawValue.replacingOccurrences(of: "-", with: "_")
        let body = try render(screen.root, document: document, indent: 2)
        let source = "import SwiftUI\n\nstruct \(typeName): View {\n    var body: some View {\n\(body)\n    }\n}\n"
        return GeneratedSource(targetID: targetID, screenID: screenID, source: source)
    }

    private static func render(_ layer: Layer, document: Document, indent: Int) throws -> String {
        var source = try renderBase(layer, document: document, indent: indent)
        let prefix = String(repeating: "    ", count: indent)
        for effect in layer.effects {
            switch effect {
            case .padding(let tokenID):
                guard let value = TokenResolver.spacing(tokenID, in: document.tokens) else {
                    throw GenerationError.unsupported(layer.id, "Padding token does not resolve to spacing")
                }
                source += "\n" + prefix + "    .padding(\(value))"
            }
        }
        return source
    }

    private static func renderBase(_ layer: Layer, document: Document, indent: Int) throws -> String {
        let prefix = String(repeating: "    ", count: indent)
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
