import Foundation
import Observation
import SwiftUI
import HamiiCore
import HamiiPreviewProtocol

public enum NativePreviewError: Error {
    case unsupportedTarget
    case runtimeMismatch(expected: String, actualMajorVersion: Int)
    case invalidPlan([Diagnostic])
}

@MainActor @Observable
public final class NativePreviewSession {
    public private(set) var document: Document
    public let surface: AppSurface
    public private(set) var appliedRevision: Int
    public private(set) var emittedEvents: [String] = []

    public init(document: Document, surface: AppSurface) throws {
        guard let target = document.targets.first(where: { $0.id == surface.targetID }), target.framework == .swiftUI else {
            throw NativePreviewError.unsupportedTarget
        }
        #if os(macOS)
        guard target.platform == .macOS else { throw NativePreviewError.unsupportedTarget }
        #elseif os(iOS)
        guard target.platform == .iOS else { throw NativePreviewError.unsupportedTarget }
        #endif
        let actualMajorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let requestedMajorVersion = surface.runtime.split(separator: " ").last.flatMap { Int($0.split(separator: ".").first ?? "") }
        guard surface.runtime.hasPrefix(target.platform.rawValue + " "), requestedMajorVersion == actualMajorVersion else {
            throw NativePreviewError.runtimeMismatch(expected: surface.runtime, actualMajorVersion: actualMajorVersion)
        }
        let plan = TargetPlanner.plan(surface: surface, document: document)
        guard plan.canPreview else { throw NativePreviewError.invalidPlan(plan.diagnostics) }
        self.document = document
        self.surface = surface
        appliedRevision = document.revision
    }

    public func apply(_ patch: PreviewPatch) -> PreviewAcknowledgement {
        guard patch.documentID == document.id, patch.surfaceID == surface.id else {
            return PreviewAcknowledgement(revision: appliedRevision, accepted: false, diagnostics: [Diagnostic("preview.identity", "Patch belongs to another Document or Surface")])
        }
        let gate = PreviewRevisionGate.accept(patch, after: appliedRevision)
        guard gate.accepted else { return gate }
        guard let screenIndex = document.screens.firstIndex(where: { $0.id == surface.screenID }) else {
            return PreviewAcknowledgement(revision: appliedRevision, accepted: false, diagnostics: [Diagnostic("preview.screen", "Screen is missing")])
        }
        var next = document
        for change in patch.changes {
            guard change.path == "text", setText(change.value, id: change.layerID, in: &next.screens[screenIndex].root) else {
                return PreviewAcknowledgement(revision: appliedRevision, accepted: false, diagnostics: [Diagnostic("preview.path", "Unsupported patch path or Layer ID", entityID: change.layerID)])
            }
        }
        next.revision = patch.revision
        let plan = TargetPlanner.plan(surface: surface, document: next)
        guard plan.canPreview else {
            return PreviewAcknowledgement(revision: appliedRevision, accepted: false, diagnostics: plan.diagnostics)
        }
        document = next
        appliedRevision = patch.revision
        return PreviewAcknowledgement(revision: patch.revision, accepted: true)
    }

    public func recordEvent(_ name: String) { emittedEvents.append(name) }

    private func setText(_ value: String, id: EntityID, in layer: inout Layer) -> Bool {
        if layer.id == id {
            guard layer.kind == .text || layer.kind == .button else { return false }
            layer.text = value
            return true
        }
        for index in layer.children.indices {
            if setText(value, id: id, in: &layer.children[index]) { return true }
        }
        return false
    }
}

public struct NativePreviewView: View {
    public let session: NativePreviewSession
    public init(session: NativePreviewSession) { self.session = session }

    public var body: some View {
        if let screen = session.document.screens.first(where: { $0.id == session.surface.screenID }) {
            if case .system(let navigation) = screen.navigation {
                NavigationStack {
                    NativeLayerView(layer: screen.root, session: session)
                        .navigationTitle(navigation.title ?? "")
                        .toolbar {
                            ToolbarItemGroup(placement: .automatic) {
                                ForEach(navigation.toolbarItems) { item in
                                    Button(item.title) { session.recordEvent(item.emittedEvent) }
                                }
                            }
                        }
                }
            } else {
                NativeLayerView(layer: screen.root, session: session)
            }
        }
    }
}

private struct NativeLayerView: View {
    let layer: Layer
    let session: NativePreviewSession

    var body: some View {
        Group {
            switch layer.kind {
            case .stack:
                if layer.layout.axis == .horizontal { HStack(spacing: spacing) { children } }
                else { VStack(alignment: .leading, spacing: spacing) { children } }
            case .overlay: ZStack { children }
            case .scroll: ScrollView { children }
            case .text:
                Text(displayText)
                    .accessibilityLabel(layer.accessibilityLabel ?? displayText)
            case .button:
                Button(displayText) {
                    if let event = layer.emittedEvent { session.recordEvent(event) }
                }
                .accessibilityLabel(layer.accessibilityLabel ?? displayText)
            case .image:
                if let id = layer.assetID,
                   let asset = session.document.assets.first(where: { $0.id == id }),
                   case .system(let name) = asset.source {
                    Image(systemName: name)
                        .accessibilityLabel(layer.accessibilityLabel ?? asset.name)
                }
            case .componentInstance:
                if let instance = layer.component,
                   let definition = session.document.components.first(where: { $0.id == instance.definitionID }),
                   let resolved = try? ComponentResolver.resolve(instance, definition: definition) {
                    NativeLayerView(layer: resolved, session: session)
                }
            }
        }
        .padding(layer.layout.paddingTokenID.flatMap { TokenResolver.spacing($0, in: session.document.tokens) }.map { CGFloat($0) } ?? 0)
    }

    private var spacing: CGFloat? {
        layer.layout.spacingTokenID.flatMap { TokenResolver.spacing($0, in: session.document.tokens) }.map { CGFloat($0) }
    }

    private var displayText: String {
        guard let path = layer.textBinding else { return layer.text ?? "" }
        let fixture = session.document.fixtures.first(where: { $0.id == session.surface.fixtureID })
        return fixture?.values[path] ?? layer.text ?? ""
    }

    @ViewBuilder private var children: some View {
        ForEach(layer.children) { child in NativeLayerView(layer: child, session: session) }
    }
}
