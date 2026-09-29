import Foundation
import XCTest
import HamiiCore
import HamiiApplication
import HamiiFormat

/// A test-only context protocol. No production Query or CLI command is defined here.
final class AIContextRetrievalSpikeTests: XCTestCase {
    private typealias ID = EntityID
    private static let checkout = ID("scope_checkout")
    private static let commerce = ID("scope_commerce")
    private static let account = ID("scope_account")
    private static let app = ID("scope_app")
    private static let screen = ID("screen_checkout")
    private static let textLayer = ID("layer_selected_text")
    private static let parentLayer = ID("layer_checkout_parent")
    private static let component = ID("component_price_badge")
    private static let checkoutToken = ID("token_spacing_checkout")
    private static let state = ClientPrecondition("state_context_0")

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private struct Envelope<Payload: Codable>: Codable {
        var documentID: ID
        var revision: Int
        var statePrecondition: ClientPrecondition
        var payload: Payload
    }

    private struct PageSummary: Codable { var id: ID; var name: String }
    private struct ScreenSummary: Codable { var id: ID; var name: String; var scopeID: ID; var targetID: ID? }
    private struct ScopeSummary: Codable { var id: ID; var name: String; var parentID: ID? }
    private struct ContextSummary: Codable {
        var pages: [PageSummary]
        var screens: [ScreenSummary]
        var scopes: [ScopeSummary]
        var selectedScreenID: ID
        var selectedLayerID: ID
    }
    private struct LayerContext: Codable {
        var screenID: ID
        var consumerScopeID: ID
        var id: ID
        var kind: LayerKind
        var currentText: String?
        var currentSpacingTokenID: ID?
        var maximumMutationNodes: Int
    }
    private struct ResourceSummary: Codable {
        var id: ID
        var name: String
        var ownerScopeID: ID
    }
    private struct ResourceList: Codable {
        var consumerScopeID: ID
        var resources: [ResourceSummary]
    }
    private struct ComponentDetail: Codable {
        var id: ID
        var name: String
        var ownerScopeID: ID
        var rootKind: LayerKind
        var dependencyIDs: [ID]
    }
    private struct TokenDetail: Codable {
        var id: ID
        var ownerScopeID: ID
        var value: TokenValue
        var resolvedSpacing: Double?
    }
    private struct ObservationHeader: Codable {
        var documentID: ID
        var revision: Int
        var statePrecondition: ClientPrecondition
        var selectedScreenID: ID
        var selectedLayerID: ID
    }
    private struct MatrixRow: Codable, Equatable {
        var fixtureScale: Int
        var task: String
        var strategy: String
        var queryCount: Int
        var responseBytes: [Int]
        var cumulativeBytes: Int
        var largestResponseBytes: Int
        var fullDocumentBytes: Int
        var payloadRatio: Double
        var returnedEntityCount: Int
        var oracleComplete: Bool
        var mutationVerified: Bool
        var scopeViolations: Int
        var staleOverwrite: Bool
        var missingFacts: [String]
    }
    private struct Matrix: Codable, Equatable {
        var fixtureVersion: Int
        var aiTotalTokens: String
        var rows: [MatrixRow]
    }
    private struct TaskContext {
        var state: ClientPrecondition
        var revision: Int
        var screenID: ID
        var scopeID: ID
        var layer: LayerContext
        var resources: [ResourceSummary]
        var component: ComponentDetail?
        var token: TokenDetail?
    }
    private struct Retrieved {
        var responses: [Data]
        var returnedEntityCount: Int
        var context: TaskContext
    }

    private final class MemoryRepository: ProjectRepository {
        private var document: Document
        private var sequence = 0
        init(_ document: Document) { self.document = document }
        func observe() throws -> ProjectObservation {
            ProjectObservation(document: document,
                statePrecondition: ClientPrecondition("state_context_\(sequence)"))
        }
        func commit(_ document: Document, expected: ProjectObservation) throws -> ProjectObservation {
            guard expected.statePrecondition == (try observe()).statePrecondition else {
                throw AuthoringError.staleState
            }
            self.document = document
            sequence += 1
            return try observe()
        }
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
    private func encoded<T: Encodable>(_ value: T) throws -> Data { try encoder().encode(value) }
    private func canonicalEncoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }
    private func decoded<T: Decodable>(_ type: T.Type, _ bytes: Data) throws -> T {
        try JSONDecoder().decode(type, from: bytes)
    }
    private func envelope<T: Codable>(_ payload: T, in document: Document) -> Envelope<T> {
        Envelope(documentID: document.id, revision: document.revision,
            statePrecondition: Self.state, payload: payload)
    }

    private func fixture(_ scale: Int) throws -> Document {
        precondition(scale == 1_000 || scale == 10_000)
        // The sample is only a deterministic Codable scaffold; every modeled
        // field is replaced. The measurement fixture never creates a random ID.
        var document = try CanonicalRepository(root: repositoryRoot.appendingPathComponent("Samples/Starter")).load()
        document.id = ID("doc_context")
        document.name = "Context spike"
        document.revision = 7
        document.versions = FormatVersions()
        document.authoringHarness = AuthoringHarness(requireAccessibleControls: true,
            requireTokenSpacing: false, maximumMutationNodes: 100)
        document.tokenTemplate = nil
        document.capabilityDeclarations = []
        document.interactions = []
        document.motions = []
        document.fixtures = []
        document.scopes = [
            ArchitectureScope(id: Self.app, name: "App", parentID: nil),
            ArchitectureScope(id: Self.commerce, name: "Commerce", parentID: Self.app),
            ArchitectureScope(id: Self.checkout, name: "Checkout", parentID: Self.commerce),
            ArchitectureScope(id: Self.account, name: "Account", parentID: Self.app)
        ]
        document.tokens = [
            DesignToken(id: ID("token_spacing_app"), name: "AppSpacing", kind: .spacing,
                ownerScopeID: Self.app, value: .literal("8")),
            DesignToken(id: ID("token_spacing_commerce"), name: "CommerceSpacing", kind: .spacing,
                ownerScopeID: Self.commerce, value: .literal("12")),
            DesignToken(id: Self.checkoutToken, name: "CheckoutSpacing", kind: .spacing,
                ownerScopeID: Self.checkout, value: .reference(ID("token_spacing_commerce"))),
            DesignToken(id: ID("token_spacing_account"), name: "AccountSpacing", kind: .spacing,
                ownerScopeID: Self.account, value: .literal("16"))
        ]
        document.assets = [
            Asset(id: ID("asset_app_symbol"), name: "App Symbol", ownerScopeID: Self.app,
                mediaType: "image/system", source: .system(name: "star"))
        ]
        let base = ComponentDefinition(id: ID("component_app_base"), name: "AppBase",
            ownerScopeID: Self.app,
            root: Layer(id: ID("layer_component_app_base"), kind: .text, name: "Base", text: "Base"))
        var priceRoot = Layer(id: ID("layer_component_price_root"), kind: .stack, name: "Price root")
        priceRoot.children = [
            Layer(id: ID("layer_component_price_dependency"), kind: .componentInstance,
                name: "Base", component: ComponentInstance(definitionID: base.id))
        ]
        let price = ComponentDefinition(id: Self.component, name: "PriceBadge",
            ownerScopeID: Self.commerce, root: priceRoot)
        let local = ComponentDefinition(id: ID("component_checkout_local"), name: "LocalBadge",
            ownerScopeID: Self.checkout,
            root: Layer(id: ID("layer_component_checkout_local"), kind: .text, name: "Local", text: "Local"))
        let sibling = ComponentDefinition(id: ID("component_account_private"), name: "AccountPrivate",
            ownerScopeID: Self.account,
            root: Layer(id: ID("layer_component_account_private"), kind: .text, name: "Private", text: "Private"))
        var denied = ComponentDefinition(id: ID("component_app_denied"), name: "DeniedBadge",
            ownerScopeID: Self.app,
            root: Layer(id: ID("layer_component_app_denied"), kind: .text, name: "Denied", text: "Denied"))
        denied.availability = AvailabilityPolicy(denyScopeIDs: [Self.checkout])
        document.components = [base, price, local, sibling, denied]
        document.targets = [Target(id: ID("target_macos"), platform: .macOS, framework: .swiftUI)]

        var root = Layer(id: ID("layer_checkout_root"), kind: .stack, name: "Checkout root")
        let selected = Layer(id: Self.textLayer, kind: .text, name: "Order summary", text: "Order summary")
        var parent = Layer(id: Self.parentLayer, kind: .stack, name: "Checkout content",
            layout: Layout(axis: .vertical, spacingTokenID: ID("token_spacing_commerce")))
        parent.children = [
            Layer(id: ID("layer_checkout_instance"), kind: .componentInstance,
                name: "PriceBadge", component: ComponentInstance(definitionID: Self.component))
        ]
        let image = Layer(id: ID("layer_checkout_image"), kind: .image,
            name: "App symbol", assetID: ID("asset_app_symbol"))
        root.children = [selected, parent, image] + (0..<59).map {
            Layer(id: ID("layer_checkout_filler_\($0)"), kind: .text,
                name: "Checkout label \($0)", text: "label \($0)")
        }
        document.screens = [Screen(id: Self.screen, name: "Checkout", scopeID: Self.checkout, root: root)]
        let remaining = scale - 64
        for screenIndex in 0..<7 {
            let size = remaining / 7 + (screenIndex < remaining % 7 ? 1 : 0)
            let scope = screenIndex.isMultiple(of: 2) ? Self.account : Self.commerce
            var extraRoot = Layer(id: ID("layer_extra_root_\(screenIndex)"),
                kind: .stack, name: "Extra root \(screenIndex)")
            extraRoot.children = (0..<(size - 1)).map { layerIndex in
                Layer(id: ID("layer_extra_\(screenIndex)_\(layerIndex)"),
                    kind: .text, name: "Extra \(layerIndex)", text: "extra \(layerIndex)")
            }
            document.screens.append(Screen(id: ID("screen_extra_\(screenIndex)"),
                name: "Extra screen \(screenIndex)", scopeID: scope, root: extraRoot))
        }
        document.pages = (0..<3).map { pageIndex in
            let assigned = document.screens.enumerated().filter { $0.offset % 3 == pageIndex }
            let surfaces = assigned.map { index, screen in
                AppSurface(id: ID("surface_\(index)"), targetID: ID("target_macos"),
                    device: "Mac", runtime: "macOS 15", buildEnvironment: "SDK 15",
                    screenID: screen.id, architectureScopeID: screen.scopeID)
            }
            return Page(id: ID("page_\(pageIndex)"), name: "Page \(pageIndex)", surfaces: surfaces)
        }
        return document
    }

    private func layerCount(_ layer: Layer) -> Int {
        1 + layer.children.reduce(0) { $0 + layerCount($1) }
    }
    private func layer(_ id: ID, in root: Layer) -> Layer? {
        if root.id == id { return root }
        for child in root.children {
            if let found = layer(id, in: child) { return found }
        }
        return nil
    }
    private func selectedLayerID(_ task: String) -> ID {
        ["T2", "T3", "N"].contains(task) ? Self.parentLayer : Self.textLayer
    }
    private func summary(_ document: Document, task: String) -> ContextSummary {
        ContextSummary(pages: document.pages.map { PageSummary(id: $0.id, name: $0.name) },
            screens: document.screens.map { screen in
                ScreenSummary(id: screen.id, name: screen.name, scopeID: screen.scopeID,
                    targetID: document.pages.flatMap(\.surfaces).first(where: { $0.screenID == screen.id })?.targetID)
            },
            scopes: document.scopes.map { ScopeSummary(id: $0.id, name: $0.name, parentID: $0.parentID) },
            selectedScreenID: Self.screen, selectedLayerID: selectedLayerID(task))
    }
    private func layerContext(_ document: Document, task: String) throws -> LayerContext {
        let screen = try XCTUnwrap(document.screens.first(where: { $0.id == Self.screen }))
        let value = try XCTUnwrap(layer(selectedLayerID(task), in: screen.root))
        return LayerContext(screenID: screen.id, consumerScopeID: screen.scopeID,
            id: value.id, kind: value.kind, currentText: value.text,
            currentSpacingTokenID: value.layout.spacingTokenID,
            maximumMutationNodes: document.authoringHarness.maximumMutationNodes)
    }
    private func availableComponents(_ document: Document) -> [ComponentDefinition] {
        let scopes = ScopeEvaluator(document.scopes)
        let definitions = Dictionary(uniqueKeysWithValues: document.components.map { ($0.id, $0) })
        return document.components.filter {
            ComponentAvailability.reason($0, consumer: Self.checkout,
                scopes: scopes, definitions: definitions) == nil
        }
    }
    private func availableTokens(_ document: Document) -> [DesignToken] {
        let scopes = ScopeEvaluator(document.scopes)
        return document.tokens.filter {
            $0.kind == .spacing && scopes.canUse(owner: $0.ownerScopeID, consumer: Self.checkout)
        }
    }
    private func resources(_ document: Document, task: String) -> [ResourceSummary] {
        switch task {
        case "T2", "N":
            return availableComponents(document).map {
                ResourceSummary(id: $0.id, name: $0.name, ownerScopeID: $0.ownerScopeID)
            }
        case "T3":
            return availableTokens(document).map {
                ResourceSummary(id: $0.id, name: $0.name, ownerScopeID: $0.ownerScopeID)
            }
        default: return []
        }
    }
    private func componentDetail(_ document: Document) -> ComponentDetail? {
        guard let value = document.components.first(where: { $0.id == Self.component }) else { return nil }
        let dependencies = value.root.children.compactMap { $0.component?.definitionID }
        return ComponentDetail(id: value.id, name: value.name, ownerScopeID: value.ownerScopeID,
            rootKind: value.root.kind, dependencyIDs: dependencies)
    }
    private func tokenDetail(_ document: Document) -> TokenDetail? {
        guard let value = document.tokens.first(where: { $0.id == Self.checkoutToken }) else { return nil }
        return TokenDetail(id: value.id, ownerScopeID: value.ownerScopeID, value: value.value,
            resolvedSpacing: TokenResolver.spacing(value.id, in: document.tokens))
    }

    private struct RawManifest: Codable {
        var id: ID
        var revision: Int
        var authoringHarness: AuthoringHarness
    }
    private struct CanonicalManifest: Encodable {
        var formatVersion: Int
        var id: ID
        var name: String
        var revision: Int
        var versions: FormatVersions
        var authoringHarness: AuthoringHarness
        var capabilityDeclarations: [CapabilityDeclaration]
        var tokenTemplate: TokenTemplateProvenance?
    }

    private func canonicalFiles(_ document: Document) throws -> [String: Data] {
        var files: [String: Data] = [
            "hamii.json": try canonicalEncoded(CanonicalManifest(formatVersion: 2,
                id: document.id, name: document.name, revision: document.revision,
                versions: document.versions, authoringHarness: document.authoringHarness,
                capabilityDeclarations: document.capabilityDeclarations,
                tokenTemplate: document.tokenTemplate))
        ]
        func add<T: Encodable & Identifiable>(_ folder: String, _ values: [T]) throws where T.ID == ID {
            for value in values {
                files["\(folder)/\(value.id.rawValue).json"] = try canonicalEncoded(value)
            }
        }
        try add("pages", document.pages)
        try add("screens", document.screens)
        try add("scopes", document.scopes)
        try add("components", document.components)
        try add("tokens", document.tokens)
        try add("assets", document.assets)
        try add("interactions", document.interactions)
        try add("motions", document.motions)
        try add("fixtures", document.fixtures)
        try add("targets", document.targets)
        return files
    }

    private func temporaryCanonicalRepository(_ document: Document) throws -> URL {
        let files = try canonicalFiles(document)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hamii-context-spike-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, bytes) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
        let profile = repositoryRoot.appendingPathComponent("Samples/Starter/hamii-agent-profiles.json")
        try FileManager.default.copyItem(at: profile,
            to: root.appendingPathComponent("hamii-agent-profiles.json"))
        return root
    }

    private func componentDetail(_ components: [ComponentDefinition]) -> ComponentDetail? {
        guard let value = components.first(where: { $0.id == Self.component }) else { return nil }
        return ComponentDetail(id: value.id, name: value.name, ownerScopeID: value.ownerScopeID,
            rootKind: value.root.kind,
            dependencyIDs: value.root.children.compactMap { $0.component?.definitionID })
    }
    private func tokenDetail(_ tokens: [DesignToken]) -> TokenDetail? {
        guard let value = tokens.first(where: { $0.id == Self.checkoutToken }) else { return nil }
        return TokenDetail(id: value.id, ownerScopeID: value.ownerScopeID, value: value.value,
            resolvedSpacing: TokenResolver.spacing(value.id, in: tokens))
    }
    private func summaries(_ components: [ComponentDefinition], scopes: [ArchitectureScope]) -> [ResourceSummary] {
        let evaluator = ScopeEvaluator(scopes)
        let definitions = Dictionary(uniqueKeysWithValues: components.map { ($0.id, $0) })
        return components.filter {
            ComponentAvailability.reason($0, consumer: Self.checkout,
                scopes: evaluator, definitions: definitions) == nil
        }.map { ResourceSummary(id: $0.id, name: $0.name, ownerScopeID: $0.ownerScopeID) }
    }
    private func summaries(_ tokens: [DesignToken], scopes: [ArchitectureScope]) -> [ResourceSummary] {
        let evaluator = ScopeEvaluator(scopes)
        return tokens.filter {
            $0.kind == .spacing && evaluator.canUse(owner: $0.ownerScopeID, consumer: Self.checkout)
        }.map { ResourceSummary(id: $0.id, name: $0.name, ownerScopeID: $0.ownerScopeID) }
    }

    private func retrieve(_ strategy: String, task: String, document: Document,
                          files: [String: Data]) throws -> Retrieved {
        if strategy == "FULL" {
            let bytes = try encoded(envelope(document, in: document))
            let returned = try decoded(Envelope<Document>.self, bytes)
            let value = returned.payload
            let context = TaskContext(state: returned.statePrecondition, revision: returned.revision,
                screenID: Self.screen, scopeID: Self.checkout,
                layer: try layerContext(value, task: task), resources: resources(value, task: task),
                component: componentDetail(value), token: tokenDetail(value))
            let count = value.pages.count + value.screens.count + value.scopes.count
                + value.components.count + value.tokens.count + value.assets.count
                + value.screens.reduce(0) { $0 + layerCount($1.root) }
            return Retrieved(responses: [bytes], returnedEntityCount: count, context: context)
        }
        if strategy == "STAGED" {
            let summaryBytes = try encoded(envelope(summary(document, task: task), in: document))
            let layerBytes = try encoded(envelope(layerContext(document, task: task), in: document))
            let selectedSummary = try decoded(Envelope<ContextSummary>.self, summaryBytes)
            let selectedLayer = try decoded(Envelope<LayerContext>.self, layerBytes)
            guard selectedSummary.payload.selectedScreenID == selectedLayer.payload.screenID,
                  selectedSummary.payload.selectedLayerID == selectedLayer.payload.id else {
                throw SpikeFailure.inconsistentResponse
            }
            var responses = [summaryBytes, layerBytes]
            var resourceSummaries: [ResourceSummary] = []
            var selectedComponent: ComponentDetail?
            var selectedToken: TokenDetail?
            if ["T2", "T3", "N"].contains(task) {
                let listBytes = try encoded(envelope(ResourceList(
                    consumerScopeID: Self.checkout, resources: resources(document, task: task)), in: document))
                let list = try decoded(Envelope<ResourceList>.self, listBytes)
                resourceSummaries = list.payload.resources
                responses.append(listBytes)
            }
            if task == "T2", let detail = componentDetail(document) {
                let bytes = try encoded(envelope(detail, in: document))
                selectedComponent = try decoded(Envelope<ComponentDetail>.self, bytes).payload
                responses.append(bytes)
            }
            if task == "T3", let detail = tokenDetail(document) {
                let bytes = try encoded(envelope(detail, in: document))
                selectedToken = try decoded(Envelope<TokenDetail>.self, bytes).payload
                responses.append(bytes)
            }
            let s = selectedSummary.payload
            let count = s.pages.count + s.screens.count + s.scopes.count
                + 1 + resourceSummaries.count + (selectedComponent == nil ? 0 : 1)
                + (selectedToken == nil ? 0 : 1)
            return Retrieved(responses: responses, returnedEntityCount: count,
                context: TaskContext(state: selectedSummary.statePrecondition,
                    revision: selectedSummary.revision, screenID: selectedLayer.payload.screenID,
                    scopeID: selectedLayer.payload.consumerScopeID,
                    layer: selectedLayer.payload, resources: resourceSummaries,
                    component: selectedComponent, token: selectedToken))
        }
        guard strategy == "RAW" else { throw SpikeFailure.inconsistentResponse }
        let header = ObservationHeader(documentID: document.id, revision: document.revision,
            statePrecondition: Self.state, selectedScreenID: Self.screen,
            selectedLayerID: selectedLayerID(task))
        var responses = [try encoded(header)]
        let scopePaths = document.scopes.map { "scopes/\($0.id.rawValue).json" }
        var paths = ["hamii.json", "screens/\(Self.screen.rawValue).json"] + scopePaths
        if ["T2", "N"].contains(task) {
            paths += document.components.map { "components/\($0.id.rawValue).json" }
        }
        if task == "T3" {
            paths += document.tokens.map { "tokens/\($0.id.rawValue).json" }
        }
        for path in paths { responses.append(try XCTUnwrap(files[path])) }
        let returnedHeader = try decoded(ObservationHeader.self, responses[0])
        let manifest = try decoded(RawManifest.self, responses[1])
        let selectedScreen = try decoded(Screen.self, responses[2])
        let scopes = try responses[3..<(3 + scopePaths.count)].map {
            try decoded(ArchitectureScope.self, $0)
        }
        let resourceStart = 3 + scopePaths.count
        let components: [ComponentDefinition] = ["T2", "N"].contains(task)
            ? try responses[resourceStart...].map { try decoded(ComponentDefinition.self, $0) } : []
        let tokens: [DesignToken] = task == "T3"
            ? try responses[resourceStart...].map { try decoded(DesignToken.self, $0) } : []
        guard returnedHeader.documentID == manifest.id, returnedHeader.revision == manifest.revision,
              returnedHeader.selectedScreenID == selectedScreen.id,
              let selected = layer(returnedHeader.selectedLayerID, in: selectedScreen.root) else {
            throw SpikeFailure.inconsistentResponse
        }
        let list = ["T2", "N"].contains(task) ? summaries(components, scopes: scopes)
            : task == "T3" ? summaries(tokens, scopes: scopes) : []
        let context = TaskContext(state: returnedHeader.statePrecondition,
            revision: returnedHeader.revision, screenID: selectedScreen.id,
            scopeID: selectedScreen.scopeID,
            layer: LayerContext(screenID: selectedScreen.id, consumerScopeID: selectedScreen.scopeID,
                id: selected.id, kind: selected.kind, currentText: selected.text,
                currentSpacingTokenID: selected.layout.spacingTokenID,
                maximumMutationNodes: manifest.authoringHarness.maximumMutationNodes),
            resources: list, component: componentDetail(components), token: tokenDetail(tokens))
        return Retrieved(responses: responses,
            returnedEntityCount: layerCount(selectedScreen.root) + scopes.count
                + components.count + tokens.count + 1, context: context)
    }

    private enum SpikeFailure: Error { case inconsistentResponse }

    private func assess(_ retrieved: Retrieved, task: String, document: Document,
                        scale: Int, strategy: String, fullBytes: Int) throws -> MatrixRow {
        let context = retrieved.context
        let availableIDs: Set<ID>
        switch task {
        case "T2", "N": availableIDs = Set(availableComponents(document).map(\.id))
        case "T3": availableIDs = Set(availableTokens(document).map(\.id))
        default: availableIDs = []
        }
        let scopeViolations = context.resources.filter { !availableIDs.contains($0.id) }.count
        var missing: [String] = []
        func require(_ condition: Bool, _ fact: String) {
            if !condition { missing.append(fact) }
        }
        require(context.state == Self.state, "exact observation base")
        require(context.revision == document.revision, "Document revision")
        require(context.screenID == Self.screen, "selected Screen")
        require(context.scopeID == Self.checkout, "consumer ArchitectureScope")
        require(context.layer.maximumMutationNodes >= 1, "Authoring mutation limit")
        var mutationVerified = false
        var staleOverwrite = false
        switch task {
        case "T1", "S":
            require(context.layer.id == Self.textLayer, "selected Text Layer ID")
            require(context.layer.kind == .text, "selected Text Layer kind")
            require(context.layer.currentText == "Order summary", "current Text value")
        case "T2":
            require(context.layer.id == Self.parentLayer, "selected parent Layer ID")
            require(context.layer.kind == .stack, "parent Layer kind")
            require(context.resources.contains(where: { $0.id == Self.component && $0.name == "PriceBadge" }),
                    "available PriceBadge summary")
            require(context.component?.id == Self.component, "selected Component detail")
            require(context.component?.rootKind == .stack, "Component root kind")
            require(context.component?.dependencyIDs == [ID("component_app_base")], "Component dependency")
            require(!context.resources.contains(where: {
                $0.id == ID("component_account_private") || $0.id == ID("component_app_denied")
            }), "unavailable Components absent")
        case "T3":
            require(context.layer.id == Self.parentLayer, "selected parent Layer ID")
            require(context.layer.kind == .stack, "spacing-capable Layer kind")
            require(context.resources.contains(where: { $0.id == Self.checkoutToken }),
                    "available Checkout spacing Token summary")
            require(context.token?.id == Self.checkoutToken, "selected Token detail")
            require(context.token?.resolvedSpacing == 12, "resolved Token alias value")
            if case .reference(let target)? = context.token?.value {
                require(target == ID("token_spacing_commerce"), "Token alias target")
            } else { missing.append("Token alias target") }
            require(!context.resources.contains(where: { $0.id == ID("token_spacing_account") }),
                    "unrelated Scope Token absent")
        case "N":
            require(!context.resources.contains(where: {
                $0.id == ID("component_account_private") || $0.id == ID("component_app_denied")
            }), "Account/denied resource absent as usable")
        default: throw SpikeFailure.inconsistentResponse
        }

        if missing.isEmpty && scopeViolations == 0 {
            let repository = MemoryRepository(document)
            let service = ProjectService(repository: repository)
            let agent = AgentHarness(profileName: "context-spike", maximumMutations: 1)
            switch task {
            case "T1":
                let result = try service.mutate(.setText(screenID: context.screenID,
                    layerID: context.layer.id, text: "Updated order summary"),
                    expectedState: context.state, author: .agent, agent: agent)
                mutationVerified = result.patches.count == 1
                    && result.patches[0].entityID == Self.textLayer
                    && result.patches[0].path == "text"
                    && result.patches[0].oldValue == "Order summary"
                    && result.patches[0].newValue == "Updated order summary"
            case "T2":
                let result = try service.mutate(.instantiate(screenID: context.screenID,
                    parentID: context.layer.id, definitionID: context.component!.id),
                    expectedState: context.state, author: .agent, agent: agent)
                mutationVerified = result.patches.count == 1
                    && result.patches[0].path == "component.definitionID"
                    && result.patches[0].newValue == Self.component.rawValue
            case "T3":
                let result = try service.mutate(.setLayoutToken(screenID: context.screenID,
                    layerID: context.layer.id, property: .spacing, tokenID: context.token!.id),
                    expectedState: context.state, author: .agent, agent: agent)
                mutationVerified = result.patches.count == 1
                    && result.patches[0].entityID == Self.parentLayer
                    && result.patches[0].path == "layout.spacingTokenID"
                    && result.patches[0].newValue == Self.checkoutToken.rawValue
            case "N":
                mutationVerified = !context.resources.contains {
                    $0.id == ID("component_account_private") || $0.id == ID("component_app_denied")
                }
            case "S":
                _ = try service.mutate(.setText(screenID: Self.screen, layerID: Self.textLayer,
                    text: "Concurrent edit"), expectedState: context.state,
                    author: .agent, agent: agent)
                do {
                    _ = try service.mutate(.setText(screenID: context.screenID, layerID: context.layer.id,
                        text: "Updated order summary"), expectedState: context.state,
                        author: .agent, agent: agent)
                    staleOverwrite = true
                } catch AuthoringError.staleState {
                    let current = try service.observe().document
                    let screen = try XCTUnwrap(current.screens.first(where: { $0.id == Self.screen }))
                    mutationVerified = layer(Self.textLayer, in: screen.root)?.text == "Concurrent edit"
                }
            default: break
            }
        }
        let sizes = retrieved.responses.map(\.count)
        let total = sizes.reduce(0, +)
        return MatrixRow(fixtureScale: scale, task: task, strategy: strategy,
            queryCount: sizes.count, responseBytes: sizes, cumulativeBytes: total,
            largestResponseBytes: sizes.max() ?? 0, fullDocumentBytes: fullBytes,
            payloadRatio: Double(total) / Double(fullBytes),
            returnedEntityCount: retrieved.returnedEntityCount,
            oracleComplete: missing.isEmpty, mutationVerified: mutationVerified,
            scopeViolations: scopeViolations, staleOverwrite: staleOverwrite,
            missingFacts: missing)
    }

    private func matrix() throws -> Matrix {
        let tasks = ["T1", "T2", "T3", "N", "S"]
        let strategies = ["FULL", "STAGED", "RAW"]
        var rows: [MatrixRow] = []
        for scale in [1_000, 10_000] {
            let document = try fixture(scale)
            XCTAssertEqual(document.screens.reduce(0) { $0 + layerCount($1.root) }, scale)
            XCTAssertTrue(DocumentValidator.validate(document).isEmpty)
            let files = try canonicalFiles(document)
            let fullBytes = try encoded(envelope(document, in: document)).count
            for task in tasks {
                for strategy in strategies {
                    let value = try retrieve(strategy, task: task, document: document, files: files)
                    rows.append(try assess(value, task: task, document: document,
                        scale: scale, strategy: strategy, fullBytes: fullBytes))
                }
            }
        }
        return Matrix(fixtureVersion: 1, aiTotalTokens: "unmeasured", rows: rows)
    }

    func testContextSufficiencyAndPayloadScaling() throws {
        let first = try matrix()
        XCTAssertEqual(first.rows.count, 30)
        XCTAssertTrue(first.rows.allSatisfy { $0.oracleComplete && $0.mutationVerified
            && $0.scopeViolations == 0 && !$0.staleOverwrite }, "Required facts, Scope and stale safety")
        let original = try encoded(first)
        for _ in 0..<2 {
            XCTAssertEqual(try encoded(matrix()), original, "Repeated fixture and retrieval must be byte-identical")
        }
        for task in ["T1", "T2", "T3"] {
            let small = try XCTUnwrap(first.rows.first {
                $0.task == task && $0.strategy == "STAGED" && $0.fixtureScale == 1_000
            })
            let large = try XCTUnwrap(first.rows.first {
                $0.task == task && $0.strategy == "STAGED" && $0.fixtureScale == 10_000
            })
            XCTAssertLessThanOrEqual(large.cumulativeBytes, 2 * small.cumulativeBytes, task)
            XCTAssertLessThanOrEqual(large.payloadRatio, 0.25, task)
            XCTAssertLessThanOrEqual(large.queryCount, 4, task)
        }
        let summary = try encoded(envelope(summary(fixture(10_000), task: "T1"),
            in: fixture(10_000)))
        XCTAssertLessThanOrEqual(summary.count, 64 * 1024)
        if let path = ProcessInfo.processInfo.environment["HAMII_CONTEXT_SPIKE_RESULT"] {
            let destination = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let artifactEncoder = encoder()
            artifactEncoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            try artifactEncoder.encode(first).write(to: destination, options: .atomic)
        }
    }

    func testCanonicalShardsLoadAndScopeServiceOracle() throws {
        for scale in [1_000, 10_000] {
            let document = try fixture(scale)
            let root = try temporaryCanonicalRepository(document)
            defer { try? FileManager.default.removeItem(at: root) }
            let loaded = try CanonicalRepository(root: root).load()
            XCTAssertEqual(loaded.id, document.id)
            XCTAssertEqual(loaded.revision, document.revision)
            XCTAssertEqual(loaded.name, document.name)
            XCTAssertTrue(try encoded(loaded.pages.sorted { $0.id.rawValue < $1.id.rawValue })
                == encoded(document.pages.sorted { $0.id.rawValue < $1.id.rawValue }), "Page shards")
            XCTAssertTrue(try encoded(loaded.screens.sorted { $0.id.rawValue < $1.id.rawValue })
                == encoded(document.screens.sorted { $0.id.rawValue < $1.id.rawValue }), "Screen shards")
            XCTAssertTrue(try encoded(loaded.scopes.sorted { $0.id.rawValue < $1.id.rawValue })
                == encoded(document.scopes.sorted { $0.id.rawValue < $1.id.rawValue }), "Scope shards")
            XCTAssertTrue(try encoded(loaded.components.sorted { $0.id.rawValue < $1.id.rawValue })
                == encoded(document.components.sorted { $0.id.rawValue < $1.id.rawValue }), "Component shards")
            XCTAssertTrue(try encoded(loaded.tokens.sorted { $0.id.rawValue < $1.id.rawValue })
                == encoded(document.tokens.sorted { $0.id.rawValue < $1.id.rawValue }), "Token shards")
            XCTAssertTrue(try encoded(loaded.assets.sorted { $0.id.rawValue < $1.id.rawValue })
                == encoded(document.assets.sorted { $0.id.rawValue < $1.id.rawValue }), "Asset shards")

            let service = ProjectService(repository: MemoryRepository(document))
            XCTAssertEqual(Set(try service.availableComponents(for: Self.checkout).map(\.id)),
                Set(availableComponents(document).map(\.id)))
            XCTAssertEqual(Set(try service.availableTokens(for: Self.checkout, kind: .spacing).map(\.id)),
                Set(availableTokens(document).map(\.id)))
            XCTAssertEqual(try service.availableAssets(for: Self.checkout).map(\.id),
                document.assets.map(\.id))
        }
    }

    func testOldProjectedBaseFailsAcrossRealCoordinatedRepositories() throws {
        let root = try temporaryCanonicalRepository(fixture(1_000))
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ProjectService(repository: CanonicalRepository(root: root))
        let second = ProjectService(repository: CanonicalRepository(root: root))
        let observed = try first.observe()
        let agent = AgentHarness(profileName: "context-spike", maximumMutations: 1)
        _ = try second.mutate(.setText(screenID: Self.screen, layerID: Self.textLayer,
            text: "Concurrent edit"), expectedState: observed.statePrecondition,
            author: .agent, agent: agent)
        XCTAssertThrowsError(try first.mutate(.setText(screenID: Self.screen,
            layerID: Self.textLayer, text: "Updated order summary"),
            expectedState: observed.statePrecondition, author: .agent, agent: agent)) { error in
                guard case AuthoringError.staleState = error else {
                    return XCTFail("Expected staleState, received \(error)")
                }
        }
        let current = try first.observe().document
        let screen = try XCTUnwrap(current.screens.first(where: { $0.id == Self.screen }))
        XCTAssertEqual(layer(Self.textLayer, in: screen.root)?.text, "Concurrent edit")
    }
}
