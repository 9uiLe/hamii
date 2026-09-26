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
    var document: Document?
    var errorMessage: String?
    var selectedScreenID: EntityID?
    var selectedLayerID: EntityID?
    var availableComponents: [ComponentDefinition] = []
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
            let document = try service.document()
            self.service = service
            self.projectRoot = url
            self.document = document
            selectedScreenID = document.screens.first?.id
            selectedLayerID = nil
            previewSession = makePreviewSession(document)
            refreshAvailableComponents()
            errorMessage = nil
        } catch { errorMessage = String(describing: error) }
    }
    func selectScreen(_ id: EntityID) {
        selectedScreenID = id
        selectedLayerID = nil
        refreshAvailableComponents()
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
            performMutation { service, revision in
                try service.importRepositoryAsset(data, name: url.lastPathComponent, scopeID: scopeID, mediaType: mediaType, expectedRevision: revision, author: .human, blobs: CanonicalBlobStore(root: projectRoot))
            }
        } catch { errorMessage = String(describing: error) }
    }
    private func perform(_ intent: AuthoringIntent) {
        performMutation { service, revision in
            try service.mutate(intent, expectedRevision: revision, author: .human)
        }
    }

    private func performMutation(_ operation: (ProjectService, Int) throws -> MutationResult) {
        guard let service, let revision = document?.revision else { return }
        do {
            let result = try operation(service, revision)
            let updated = try service.document()
            if let previewSession, !result.patches.isEmpty, result.patches.allSatisfy({ $0.path == "text" }) {
                let changes = result.patches.compactMap { patch -> PreviewChange? in
                    guard let value = patch.newValue else { return nil }
                    return PreviewChange(layerID: patch.entityID, path: patch.path, value: value)
                }
                let patch = PreviewPatch(documentID: updated.id, surfaceID: previewSession.surface.id, revision: result.revision, boundary: .instantPatch, changes: changes)
                if !previewSession.apply(patch).accepted { self.previewSession = makePreviewSession(updated) }
            } else {
                previewSession = makePreviewSession(updated)
            }
            document = updated
            refreshAvailableComponents()
            errorMessage = nil
        } catch { errorMessage = String(describing: error) }
    }

    private func makePreviewSession(_ document: Document) -> NativePreviewSession? {
        let surface = document.pages.flatMap(\.surfaces).first { surface in
            document.targets.contains { $0.id == surface.targetID && $0.platform == .macOS && $0.framework == .swiftUI }
        }
        guard let surface else { return nil }
        return try? NativePreviewSession(document: document, surface: surface)
    }

    private func refreshAvailableComponents() {
        guard let service, let document,
              let screen = document.screens.first(where: { $0.id == selectedScreenID }) else {
            availableComponents = []
            availableAssets = []
            availableSpacingTokens = []
            return
        }
        availableComponents = (try? service.availableComponents(for: screen.scopeID)) ?? []
        availableAssets = (try? service.availableAssets(for: screen.scopeID)) ?? []
        availableSpacingTokens = (try? service.availableTokens(for: screen.scopeID, kind: .spacing)) ?? []
    }
}

struct LayerCanvas: View {
    let layer: Layer
    let document: Document
    let projectRoot: URL?
    let select: (EntityID) -> Void

    var body: some View {
        Group {
            switch layer.kind {
            case .stack:
                if layer.layout.axis == .horizontal {
                    HStack(alignment: .top, spacing: layer.layout.spacingTokenID.flatMap { TokenResolver.spacing($0, in: document.tokens) }.map { CGFloat($0) }) { children }
                } else { VStack(alignment: .leading, spacing: layer.layout.spacingTokenID.flatMap { TokenResolver.spacing($0, in: document.tokens) }.map { CGFloat($0) }) { children } }
            case .overlay: ZStack { children }
            case .scroll: ScrollView { children }
            case .text:
                Button { select(layer.id) } label: { Text(layer.text ?? "") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Select \(layer.name)")
            case .button: Button(layer.text ?? "Button") { select(layer.id) }
            case .image:
                Button { select(layer.id) } label: { imageContent }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Select \(layer.name)")
            case .componentInstance:
                if let instance = layer.component,
                   let definition = document.components.first(where: { $0.id == instance.definitionID }),
                   let resolved = try? ComponentResolver.resolve(instance, definition: definition) {
                    LayerCanvas(layer: resolved, document: document, projectRoot: projectRoot) { _ in select(layer.id) }
                } else {
                    Text(layer.name).padding(8).overlay { RoundedRectangle(cornerRadius: 4).stroke(.red) }
                }
            }
        }
        .padding(layer.layout.paddingTokenID.flatMap { TokenResolver.spacing($0, in: document.tokens) }.map { CGFloat($0) } ?? 0)
    }

    @ViewBuilder private var imageContent: some View {
        if let id = layer.assetID, let asset = document.assets.first(where: { $0.id == id }) {
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
                        ForEach(session.availableComponents) { component in
                            Button(component.name) { session.instantiate(component.id) }
                                .disabled(selectedScreen == nil)
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
                VStack(alignment: .leading, spacing: 12) {
                    Text("Inspector").font(.headline)
                    if let layer = selectedLayer {
                        Text(layer.name)
                        if layer.kind == .text || layer.kind == .button {
                            TextField("Text", text: $draftText)
                                .onSubmit { session.setText(draftText) }
                        }
                        if layer.kind == .stack {
                            tokenPicker("Spacing", selected: layer.layout.spacingTokenID, property: .spacing)
                        }
                        if [.stack, .overlay, .scroll].contains(layer.kind) {
                            tokenPicker("Padding", selected: layer.layout.paddingTokenID, property: .padding)
                        }
                    }
                    Spacer()
                }
                .padding()
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
