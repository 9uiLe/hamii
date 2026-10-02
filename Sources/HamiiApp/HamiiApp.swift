import AppKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
import HamiiCore
import HamiiApplication
import HamiiFormat
import HamiiNativeRuntime
import HamiiPreviewProtocol

@MainActor @Observable
final class EditorSession {
    var document: HamiiCore.Document?
    var statePrecondition: ClientPrecondition?
    var errorMessage: String?
    var selectedScreenID: EntityID?
    var selectedLayerID: EntityID?
    var selectedSurfaceID: EntityID?
    var surfaceCapabilityAssessment: SurfaceCapabilityAssessment?
    var surfaceAssessmentError: String?
    var componentAvailability: [ComponentAvailabilityItem] = []
    var availableAssets: [Asset] = []
    var availableSpacingTokens: [DesignToken] = []
    var previewSession: NativePreviewSession?
    private var service: ProjectService?
    private(set) var projectRoot: URL?

    func openProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(at: url)
    }

    func openProject(at url: URL) {
        do {
            let service = ProjectService(repository: CanonicalRepository(root: url))
            let observed = try service.observe()
            let document = observed.document
            self.service = service
            self.projectRoot = url
            self.document = document
            self.statePrecondition = observed.statePrecondition
            selectedScreenID = document.screens.first?.id
            selectedLayerID = nil
            refreshSurfaceAssessment()
            previewSession = makePreviewSession(document, statePrecondition: observed.statePrecondition)
            errorMessage = nil
            refreshComponentAvailability()
        } catch { errorMessage = String(describing: error) }
    }
    func selectScreen(_ id: EntityID) {
        selectedScreenID = id
        selectedLayerID = nil
        refreshSurfaceAssessment()
        if let document, let statePrecondition {
            previewSession = makePreviewSession(document, statePrecondition: statePrecondition)
        }
        refreshComponentAvailability()
    }

    var eligibleSurfaces: [AppSurface] {
        guard let document, let selectedScreenID else { return [] }
        return document.pages.flatMap(\.surfaces).filter { surface in
            surface.screenID == selectedScreenID && document.targets.contains {
                $0.id == surface.targetID && $0.platform == .macOS && $0.framework == .swiftUI
            }
        }
    }

    func selectSurface(_ id: EntityID) {
        guard eligibleSurfaces.contains(where: { $0.id == id }) else { return }
        selectedSurfaceID = id
        refreshSurfaceAssessment()
        if let document, let statePrecondition {
            previewSession = makePreviewSession(document, statePrecondition: statePrecondition)
        }
    }

    private func refreshSurfaceAssessment() {
        let surfaces = eligibleSurfaces
        if !surfaces.contains(where: { $0.id == selectedSurfaceID }) {
            selectedSurfaceID = surfaces.first?.id
        }
        surfaceCapabilityAssessment = nil
        surfaceAssessmentError = nil
        guard let document, let selectedSurfaceID else { return }
        do {
            surfaceCapabilityAssessment = try SurfaceCapabilityAssessmentService.assess(
                document: document, surfaceID: selectedSurfaceID
            )
        } catch {
            surfaceAssessmentError = String(describing: error)
        }
    }

    func createPage() { perform(.createPage(name: "New Page")) }
    func createScreen() {
        guard let scopeID = document?.scopes.first(where: { $0.parentID == nil })?.id else { return }
        perform(.createScreen(name: "New Screen", scopeID: scopeID))
        if let id = document?.screens.last?.id { selectScreen(id) }
    }
    func addText() {
        guard let screen = document?.screens.first(where: { $0.id == selectedScreenID }) else { return }
        perform(.addLayer(screenID: screen.id, parentID: screen.root.id, kind: .text, name: "Text", text: "Text"))
    }
    func addButton() {
        guard let screen = document?.screens.first(where: { $0.id == selectedScreenID }) else { return }
        perform(.addLayer(screenID: screen.id, parentID: screen.root.id, kind: .button, name: "Button", text: "Button"))
    }
    func instantiate(_ definitionID: EntityID) {
        guard let screen = document?.screens.first(where: { $0.id == selectedScreenID }) else { return }
        perform(.instantiate(screenID: screen.id, parentID: screen.root.id, definitionID: definitionID))
    }
    func addImage(_ assetID: EntityID) {
        guard let screen = document?.screens.first(where: { $0.id == selectedScreenID }),
              let asset = availableAssets.first(where: { $0.id == assetID }) else { return }
        perform(.addImageLayer(screenID: screen.id, parentID: screen.root.id, assetID: asset.id, name: asset.name))
    }
    func setText(_ value: String) {
        guard let screenID = selectedScreenID, let layerID = selectedLayerID else { return }
        perform(.setText(screenID: screenID, layerID: layerID, text: value))
    }
    func setComponentVariant(screenID: EntityID, layerID: EntityID, observedState: ClientPrecondition,
                             axis: String, value: String) {
        guard variantPickerIsCurrent(screenID: screenID, layerID: layerID, observedState: observedState) else { return }
        perform(.setComponentVariant(screenID: screenID, layerID: layerID, axis: axis, value: value))
    }
    func unsetComponentVariant(screenID: EntityID, layerID: EntityID, observedState: ClientPrecondition,
                               axis: String) {
        guard variantPickerIsCurrent(screenID: screenID, layerID: layerID, observedState: observedState) else { return }
        perform(.unsetComponentVariant(screenID: screenID, layerID: layerID, axis: axis))
    }
    private func variantPickerIsCurrent(screenID: EntityID, layerID: EntityID,
                                        observedState: ClientPrecondition) -> Bool {
        guard selectedScreenID == screenID, selectedLayerID == layerID else {
            errorMessage = "Selected Layer changed. Choose a Variant in the current Inspector."
            return false
        }
        guard statePrecondition == observedState else {
            errorMessage = AuthoringError.staleState.description
            return false
        }
        return true
    }
    func createSpacingToken(name: String, value: String) {
        guard let scopeID = document?.screens.first(where: { $0.id == selectedScreenID })?.scopeID else { return }
        perform(.createToken(name: name, kind: .spacing, scopeID: scopeID, value: .literal(value)))
    }
    func setLayoutToken(_ property: LayoutTokenProperty, tokenID: EntityID?) {
        guard let screenID = selectedScreenID, let layerID = selectedLayerID else { return }
        perform(.setLayoutToken(screenID: screenID, layerID: layerID, property: property, tokenID: tokenID))
    }
    func importAsset() {
        guard let document, let projectRoot else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let scopeID = document.screens.first(where: { $0.id == selectedScreenID })?.scopeID
                ?? document.scopes.first(where: { $0.parentID == nil })?.id
            guard let scopeID else { return }
            let mediaType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            performMutation { service, state in
                try service.importRepositoryAsset(data, name: url.lastPathComponent, scopeID: scopeID, mediaType: mediaType, expectedState: state, author: .human, blobs: CanonicalBlobStore(root: projectRoot))
            }
        } catch { errorMessage = String(describing: error) }
    }
    private func perform(_ intent: AuthoringIntent) {
        performMutation { service, state in
            try service.mutate(intent, expectedState: state, author: .human)
        }
    }

    private func performMutation(_ operation: (ProjectService, ClientPrecondition) throws -> MutationResult) {
        guard let service, let priorState = statePrecondition else { return }
        do {
            let result = try operation(service, priorState)
            let observed = try service.observe()
            let updated = observed.document
            document = updated
            statePrecondition = observed.statePrecondition
            refreshSurfaceAssessment()
            if let previewSession, result.statePrecondition == observed.statePrecondition,
               previewSession.surface.id == selectedSurfaceID,
               !result.patches.isEmpty, result.patches.allSatisfy({ $0.path == "text" }) {
                let changes = result.patches.compactMap { patch -> PreviewChange? in
                    guard let value = patch.newValue else { return nil }
                    return PreviewChange(layerID: patch.entityID, path: patch.path, value: value)
                }
                let patch = PreviewPatch(documentID: updated.id, surfaceID: previewSession.surface.id, baseRevision: result.revision - 1, revision: result.revision, baseState: priorState, newState: observed.statePrecondition, boundary: .instantPatch, changes: changes)
                if !previewSession.apply(patch).accepted { self.previewSession = makePreviewSession(updated, statePrecondition: observed.statePrecondition) }
            } else {
                previewSession = makePreviewSession(updated, statePrecondition: observed.statePrecondition)
            }
            refreshComponentAvailability()
            errorMessage = nil
        } catch {
            if case AuthoringError.staleState = error, let observed = try? service.observe() {
                document = observed.document
                statePrecondition = observed.statePrecondition
                refreshSurfaceAssessment()
                previewSession = makePreviewSession(observed.document, statePrecondition: observed.statePrecondition)
                refreshComponentAvailability()
            }
            errorMessage = String(describing: error)
        }
    }

    private func makePreviewSession(_ document: HamiiCore.Document, statePrecondition: ClientPrecondition) -> NativePreviewSession? {
        guard let surface = eligibleSurfaces.first(where: { $0.id == selectedSurfaceID }) else { return nil }
        return try? NativePreviewSession(document: document, surface: surface, statePrecondition: statePrecondition)
    }

    private func refreshComponentAvailability() {
        guard let service, let document, let statePrecondition,
              let screen = document.screens.first(where: { $0.id == selectedScreenID }) else {
            componentAvailability = []
            availableAssets = []
            availableSpacingTokens = []
            return
        }
        do {
            componentAvailability = try service.componentAvailability(for: screen.scopeID,
                expectedState: statePrecondition, includeNonOwned: false)
                .sorted { $0.name == $1.name ? $0.id.rawValue < $1.id.rawValue : $0.name < $1.name }
        } catch {
            componentAvailability = []
            errorMessage = String(describing: error)
        }
        availableAssets = (try? service.availableAssets(for: screen.scopeID)) ?? []
        availableSpacingTokens = (try? service.availableTokens(for: screen.scopeID, kind: .spacing)) ?? []
    }

    func componentAvailabilityExplanation(_ item: ComponentAvailabilityItem) -> String {
        let reason: String
        switch item.ruleID {
        case "component.denied": reason = "Denied for this ArchitectureScope"
        case "component.notAllowed": reason = "This ArchitectureScope is not in the allow list"
        case "scope.notAncestor": reason = "A nested component is outside this ArchitectureScope"
        case "component.missing": reason = "A nested component is missing"
        case "component.cycle": reason = "Component dependency cycle"
        default: reason = "Component is unavailable"
        }
        guard let blocker = item.blockingComponentID else { return reason }
        let name = document?.components.first { $0.id == blocker }?.name ?? blocker.rawValue
        return "\(reason) (\(name), \(item.ruleID ?? "unknown"))"
    }
}

struct LayerCanvas: View {
    let layer: Layer
    let document: HamiiCore.Document
    let projectRoot: URL?
    let select: (EntityID) -> Void

    var body: some View {
        Group {
            switch layer.payload {
            case .stack:
                if layer.layout.axis == .horizontal {
                    HStack(alignment: .top, spacing: layer.layout.spacingTokenID.flatMap { TokenResolver.spacing($0, in: document.tokens) }.map { CGFloat($0) }) { children }
                } else { VStack(alignment: .leading, spacing: layer.layout.spacingTokenID.flatMap { TokenResolver.spacing($0, in: document.tokens) }.map { CGFloat($0) }) { children } }
            case .overlay: ZStack { children }
            case .scroll: ScrollView { children }
            case .text(let payload):
                Button { select(layer.id) } label: { Text(payload.value ?? "") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Select \(layer.name)")
            case .button(let payload): Button(payload.label ?? "Button") { select(layer.id) }
            case .image:
                Button { select(layer.id) } label: { imageContent }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Select \(layer.name)")
            case .componentInstance(let payload):
                if let instance = payload.instance,
                   let definition = document.components.first(where: { $0.id == instance.definitionID }),
                   let resolved = try? ComponentResolver.resolve(instance, definition: definition) {
                    LayerCanvas(layer: resolved, document: document, projectRoot: projectRoot) { _ in select(layer.id) }
                } else {
                    Text(layer.name).padding(8).overlay { RoundedRectangle(cornerRadius: 4).stroke(.red) }
                }
            }
        }
        .modifier(CanvasLayerEffects(effects: layer.effects, tokens: document.tokens))
    }

    @ViewBuilder private var imageContent: some View {
        if case .image(let payload) = layer.payload,
           let id = payload.assetID, let asset = document.assets.first(where: { $0.id == id }) {
            switch asset.source {
            case .system(let name):
                Image(systemName: name).accessibilityLabel(layer.accessibilityLabel ?? asset.name)
            case .repository(let path):
                if let projectRoot, let image = NSImage(contentsOf: projectRoot.appendingPathComponent(path)) {
                    Image(nsImage: image).resizable().scaledToFit()
                        .accessibilityLabel(layer.accessibilityLabel ?? asset.name)
                } else {
                    Label("Image unavailable: \(asset.name)", systemImage: "exclamationmark.triangle")
                }
            case .remote, .runtime, .generated:
                Label("Preview fixture needed: \(asset.name)", systemImage: "photo")
            }
        } else {
            Label("Image reference missing", systemImage: "exclamationmark.triangle")
        }
    }

    @ViewBuilder private var children: some View {
        ForEach(layer.children) { child in LayerCanvas(layer: child, document: document, projectRoot: projectRoot, select: select) }
    }
}

private struct CanvasLayerEffects: ViewModifier {
    let effects: [LayerEffect]
    let tokens: [DesignToken]
    func body(content: Content) -> some View {
        effects.reduce(AnyView(content)) { view, effect in
            switch effect {
            case .padding(let tokenID):
                return AnyView(view.padding(CGFloat(TokenResolver.spacing(tokenID, in: tokens) ?? 0)))
            }
        }
    }
}

struct LayerRow: View {
    let layer: Layer
    let select: (EntityID) -> Void

    var body: some View {
        if layer.children.isEmpty {
            Button(layer.name) { select(layer.id) }
        } else {
            DisclosureGroup {
                ForEach(layer.children) { child in LayerRow(layer: child, select: select) }
            } label: {
                Button(layer.name) { select(layer.id) }
            }
        }
    }
}

private struct SurfaceCapabilityPanel: View {
    let assessment: SurfaceCapabilityAssessment

    private struct LossRow: Identifiable {
        let id: String
        let loss: CapabilityLoss
    }

    private struct DiagnosticRow: Identifiable {
        let id: String
        let diagnostic: Diagnostic
    }

    private var lossRows: [LossRow] {
        var occurrences: [String: Int] = [:]
        return assessment.lossReport.items.filter { $0.loss != .none }.map { loss in
            let key = "\(loss.requirement.sourceEntityID.rawValue):\(loss.requirement.key.rawValue)"
            let occurrence = occurrences[key, default: 0]
            occurrences[key] = occurrence + 1
            return LossRow(id: "\(key):\(occurrence)", loss: loss)
        }
    }

    private var diagnosticRows: [DiagnosticRow] {
        var occurrences: [String: Int] = [:]
        return assessment.previewPlan.diagnostics.map { diagnostic in
            let key = "\(diagnostic.entityID?.rawValue ?? "document"):\(diagnostic.rule):\(diagnostic.message)"
            let occurrence = occurrences[key, default: 0]
            occurrences[key] = occurrence + 1
            return DiagnosticRow(id: "\(key):\(occurrence)", diagnostic: diagnostic)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let profile = assessment.lossReport.profile
            Text("Surface: \(assessment.surfaceID.rawValue)")
            Text("Target: \(assessment.targetID.rawValue)")
            Text("\(profile.platform.rawValue) / \(profile.framework.rawValue) / \(profile.runtime ?? "Runtime unknown")")
                .font(.caption)
            Text(lossRows.isEmpty ? "No capability loss" : "\(lossRows.count) capability losses")
                .font(.subheadline.weight(.semibold))
            ForEach(lossRows) { row in
                let loss = row.loss
                VStack(alignment: .leading, spacing: 2) {
                    Text(loss.requirement.key.rawValue).font(.caption.weight(.semibold))
                    Text("\(loss.support.rawValue) · \(loss.loss.rawValue)").font(.caption)
                    Text("Source: \(loss.requirement.sourceEntityID.rawValue)").font(.caption)
                    Text(loss.reason).font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
                .accessibilityElement(children: .combine)
            }
            Divider()
            Text(assessment.previewPlan.canPreview ? "Preview Plan: Ready" : "Preview Plan: Blocked")
                .font(.subheadline.weight(.semibold))
            if !assessment.previewPlan.canPreview {
                ForEach(diagnosticRows) { row in
                    let diagnostic = row.diagnostic
                    VStack(alignment: .leading, spacing: 2) {
                        Text(diagnostic.rule).font(.caption.weight(.semibold))
                        Text("Entity: \(diagnostic.entityID?.rawValue ?? "document")").font(.caption)
                        Text(diagnostic.message).font(.caption)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            Text("Capability and plan assessment does not prove that a native host is available or launchable.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct EditorView: View {
    @State private var session = EditorSession()
    @State private var draftText = ""
    @State private var draftTokenName = ""
    @State private var draftTokenValue = "8"
    @State private var showNativePreview = false
    @State private var didOpenInitialProject = false

    private var selectedScreen: Screen? {
        session.document?.screens.first(where: { $0.id == session.selectedScreenID })
    }
    private var selectedLayer: Layer? {
        guard let root = selectedScreen?.root, let id = session.selectedLayerID else { return nil }
        return find(id, in: root)
    }
    private struct VariantAxis: Identifiable {
        let id: String
        let values: [String]
    }
    private var selectedVariantAxes: [VariantAxis] {
        guard let instance = selectedLayer?.component,
              let definition = session.document?.components.first(where: { $0.id == instance.definitionID }) else {
            return []
        }
        let grouped = Dictionary(grouping: definition.variants, by: \.axis)
        return grouped.map { axis, variants in
            VariantAxis(id: axis, values: Array(Set(variants.map(\.value))).sorted())
        }.sorted { $0.id < $1.id }
    }

    var body: some View {
        NavigationSplitView {
            List {
                if let document = session.document {
                    Section("Pages") {
                        ForEach(document.pages) { page in Text(page.name) }
                    }
                    Section("Screens") {
                        ForEach(document.screens) { screen in
                            Button(screen.name) { session.selectScreen(screen.id) }
                        }
                    }
                    if let screen = selectedScreen {
                        Section("Layers") {
                            LayerRow(layer: screen.root) { id in
                                session.selectedLayerID = id
                                draftText = selectedLayer?.text ?? ""
                            }
                        }
                    }
                    Section("Components") {
                        ForEach(session.componentAvailability, id: \.id) { item in
                            Button {
                                session.instantiate(item.id)
                            } label: {
                                VStack(alignment: .leading) {
                                    HStack {
                                        Text(item.name)
                                        if !item.available { Image(systemName: "lock.fill") }
                                    }
                                    if !item.available {
                                        Text(session.componentAvailabilityExplanation(item))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .disabled(selectedScreen == nil || !item.available)
                            .help(item.available ? "Available" : session.componentAvailabilityExplanation(item))
                        }
                    }
                    Section("Assets") {
                        ForEach(session.availableAssets) { asset in
                            Button(asset.name) { session.addImage(asset.id) }
                                .disabled(selectedScreen == nil)
                        }
                    }
                    Section("Spacing Tokens") {
                        ForEach(session.availableSpacingTokens) { token in
                            Text(token.name)
                        }
                        TextField("Token name", text: $draftTokenName)
                        TextField("Points", text: $draftTokenValue)
                        Button("Create Spacing Token") {
                            session.createSpacingToken(name: draftTokenName, value: draftTokenValue)
                            draftTokenName = ""
                        }
                        .disabled(selectedScreen == nil || draftTokenName.isEmpty)
                    }
                }
            }
            .navigationTitle("hamii")
        } detail: {
            HStack(spacing: 0) {
                VStack {
                    if showNativePreview, let preview = session.previewSession {
                        NativePreviewView(session: preview)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if showNativePreview {
                        ContentUnavailableView("Native Preview unavailable", systemImage: "iphone", description: Text("Open a project with a supported macOS SwiftUI AppSurface and declared capabilities."))
                    } else if let screen = selectedScreen, let document = session.document {
                        Text(screen.name).font(.headline)
                        ScrollView {
                            LayerCanvas(layer: screen.root, document: document, projectRoot: session.projectRoot) { id in
                                session.selectedLayerID = id
                                draftText = selectedLayer?.text ?? ""
                            }
                            .padding(32)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    } else {
                        ContentUnavailableView("Open a hamii project", systemImage: "square.stack.3d.up", description: Text("Choose a project directory to edit its semantic UI model."))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Inspector").font(.headline)
                        if let layer = selectedLayer {
                            Text(layer.name)
                            if let screenID = session.selectedScreenID,
                               let observedState = session.statePrecondition {
                                ForEach(selectedVariantAxes) { axis in
                                    componentVariantPicker(axis, screenID: screenID, layerID: layer.id,
                                                           observedState: observedState)
                                }
                            }
                            if layer.kind == .text || layer.kind == .button {
                                TextField("Text", text: $draftText)
                                    .onSubmit { session.setText(draftText) }
                            }
                            if layer.kind == .stack {
                                tokenPicker("Spacing", selected: layer.layout.spacingTokenID, property: .spacing)
                            }
                            if [.stack, .overlay, .scroll].contains(layer.kind) {
                                tokenPicker("Padding", selected: layer.effects.compactMap { effect -> EntityID? in
                                    if case .padding(let tokenID) = effect { return tokenID }
                                    return nil
                                }.first, property: .padding)
                            }
                        }
                        if selectedScreen != nil {
                            Divider()
                            Text("Target Support").font(.headline)
                            if session.eligibleSurfaces.count > 1 {
                                Picker("AppSurface", selection: Binding(
                                    get: { session.selectedSurfaceID?.rawValue ?? "" },
                                    set: { session.selectSurface(EntityID($0)) }
                                )) {
                                    ForEach(session.eligibleSurfaces) { surface in
                                        Text("\(surface.device) · \(surface.runtime) · \(surface.id.rawValue)")
                                            .tag(surface.id.rawValue)
                                    }
                                }
                            }
                            if let assessment = session.surfaceCapabilityAssessment {
                                SurfaceCapabilityPanel(assessment: assessment)
                            } else if let error = session.surfaceAssessmentError {
                                Text("Capability assessment unavailable: \(error)")
                            } else {
                                Text("No macOS SwiftUI AppSurface is available for this Screen. Other framework and host coverage is not evaluated here.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .frame(width: 240)
                .frame(maxHeight: .infinity, alignment: .topLeading)
            }
            .toolbar {
                Button("Open", systemImage: "folder") { session.openProject() }
                Button("Page", systemImage: "plus.rectangle") { session.createPage() }.disabled(session.document == nil)
                Button("Screen", systemImage: "plus.app") { session.createScreen() }.disabled(session.document == nil)
                Button("Text", systemImage: "textformat") { session.addText() }.disabled(selectedScreen == nil)
                Button("Button", systemImage: "button.programmable") { session.addButton() }.disabled(selectedScreen == nil)
                Button("Import Asset to Git", systemImage: "photo.badge.plus") { session.importAsset() }.disabled(session.document == nil)
                Button(showNativePreview ? "Canvas" : "Native Preview", systemImage: "play.rectangle") { showNativePreview.toggle() }
                    .disabled(session.document == nil)
            }
            .alert("hamii", isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
                Button("OK") { session.errorMessage = nil }
            } message: { Text(session.errorMessage ?? "") }
        }
        .onAppear {
            guard !didOpenInitialProject else { return }
            didOpenInitialProject = true
            let arguments = CommandLine.arguments
            if let index = arguments.firstIndex(of: "--project"), arguments.indices.contains(index + 1) {
                session.openProject(at: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
            }
        }
    }

    private func find(_ id: EntityID, in root: Layer) -> Layer? {
        if root.id == id { return root }
        for child in root.children { if let found = find(id, in: child) { return found } }
        return nil
    }

    private func componentVariantPicker(_ axis: VariantAxis, screenID: EntityID, layerID: EntityID,
                                        observedState: ClientPrecondition) -> some View {
        Picker("Variant \(String(reflecting: axis.id))", selection: Binding<String?>(
            get: {
                guard session.selectedScreenID == screenID, session.selectedLayerID == layerID,
                      session.statePrecondition == observedState else { return nil }
                return selectedLayer?.component?.variantSelection[axis.id]
            },
            set: { value in
                if let value {
                    session.setComponentVariant(screenID: screenID, layerID: layerID,
                                                observedState: observedState, axis: axis.id, value: value)
                } else {
                    session.unsetComponentVariant(screenID: screenID, layerID: layerID,
                                                  observedState: observedState, axis: axis.id)
                }
            }
        )) {
            Text("Unselected").tag(Optional<String>.none)
            ForEach(axis.values, id: \.self) { value in
                Text(String(reflecting: value)).tag(Optional.some(value))
            }
        }
    }

    private func tokenPicker(_ title: String, selected: EntityID?, property: LayoutTokenProperty) -> some View {
        Picker(title, selection: Binding(
            get: { selected?.rawValue ?? "" },
            set: { session.setLayoutToken(property, tokenID: $0.isEmpty ? nil : EntityID($0)) }
        )) {
            Text("None").tag("")
            ForEach(session.availableSpacingTokens) { token in
                Text(token.name).tag(token.id.rawValue)
            }
        }
    }
}

struct HamiiApp: App {
    var body: some Scene {
        WindowGroup { EditorView().frame(minWidth: 850, minHeight: 550) }
    }
}

HamiiApp.main()
