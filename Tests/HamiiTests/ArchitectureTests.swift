import Foundation
import XCTest
import HamiiCore
import HamiiApplication
@testable import HamiiFormat
import HamiiIndex
import HamiiGeneration
import HamiiIntegration
import HamiiMigrations
import HamiiNativeRuntime
import HamiiPreviewProtocol

final class ArchitectureTests: XCTestCase {
    func testCanonicalJournalRecoversCompleteRevisionAfterInterruptedSave() throws {
        struct Stopped: Error {}
        let stops = ["prepared", "ready", "pages/page_new.json", "pages/page_old.json", "screens/screen_new.json", "hamii.json", "complete"]
        for stop in stops {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: path) }
            let repository = CanonicalRepository(root: path)
            var base = try repository.create(name: "Journal")
            let scopeID = try XCTUnwrap(base.scopes.first?.id)
            base.pages = [Page(id: EntityID("page_old"), name: "Old")]
            base.revision = 1
            try repository.save(base, expectedRevision: 0)
            var updated = base
            updated.pages = [Page(id: EntityID("page_new"), name: "New")]
            updated.screens = [Screen(id: EntityID("screen_new"), name: "New", scopeID: scopeID, root: Layer(id: EntityID("layer_new"), kind: .stack, name: "Root"))]
            updated.revision = 2
            let interrupted = CanonicalRepository(root: path) { step in
                switch step {
                case .prepared where stop == "prepared": throw Stopped()
                case .ready where stop == "ready": throw Stopped()
                case .applied(let file) where stop == file: throw Stopped()
                case .complete where stop == "complete": throw Stopped()
                default: break
                }
            }
            XCTAssertThrowsError(try interrupted.save(updated, expectedRevision: 1), "stop: \(stop)")
            if !["prepared", "complete"].contains(stop) {
                XCTAssertEqual(try MigrationPreflight.plan(repository: path).state, "pendingCanonicalTransaction")
            }
            let reopened = CanonicalRepository(root: path)
            let expected = ["hamii.json", "complete"].contains(stop) ? updated : base
            XCTAssertEqual(try reopened.load(), expected, "stop: \(stop)")
            XCTAssertEqual(try reopened.load(), expected, "idempotent: \(stop)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: path.appendingPathComponent(".hamii/transaction.ready").path))
        }
    }

    func testInterruptedProjectCreationCanBeRetried() throws {
        struct Stopped: Error {}
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let interrupted = CanonicalRepository(root: path) { step in
            if case .ready = step { throw Stopped() }
        }
        XCTAssertThrowsError(try interrupted.create(name: "Interrupted"))
        let repository = CanonicalRepository(root: path)
        let created = try repository.create(name: "Recovered")
        XCTAssertEqual(try repository.load().id, created.id)
        XCTAssertEqual(try repository.load().name, "Recovered")
    }

    func testCanonicalJournalPreservesExternalEditAsConflict() throws {
        struct Stopped: Error {}
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let repository = CanonicalRepository(root: path)
        var base = try repository.create(name: "Conflict")
        base.pages = [Page(id: EntityID("page_old"), name: "Old")]
        base.revision = 1
        try repository.save(base, expectedRevision: 0)
        var updated = base
        updated.pages = [Page(id: EntityID("page_new"), name: "New")]
        updated.revision = 2
        let interrupted = CanonicalRepository(root: path) { step in
            if case .ready = step { throw Stopped() }
        }
        XCTAssertThrowsError(try interrupted.save(updated, expectedRevision: 1))
        let externalFile = path.appendingPathComponent("pages/page_old.json")
        let external = Data("external edit".utf8)
        try external.write(to: externalFile)
        XCTAssertThrowsError(try CanonicalRepository(root: path).load()) { error in
            guard case CanonicalError.transactionConflict(let file) = error else { return XCTFail("Wrong error: \(error)") }
            XCTAssertEqual(file, "pages/page_old.json")
        }
        XCTAssertEqual(try Data(contentsOf: externalFile), external)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.appendingPathComponent(".hamii/transaction.ready").path))
    }
    func testRepositoryAssetUsesContentAddressedBlobAndRejectsCorruption() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let repository = CanonicalRepository(root: path)
        let document = try repository.create(name: "Assets")
        let scopeID = try XCTUnwrap(document.scopes.first?.id)
        let service = ProjectService(repository: repository)
        let store = CanonicalBlobStore(root: path)
        let data = Data("image bytes".utf8)
        XCTAssertThrowsError(try service.importRepositoryAsset(data, name: "Denied", scopeID: scopeID, mediaType: "image/png", expectedRevision: 0, author: .agent, agent: AgentHarness(profileName: "reviewer", maximumMutations: 0), blobs: store))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.appendingPathComponent("assets/blobs").path))
        let first = try service.importRepositoryAsset(data, name: "Avatar", scopeID: scopeID, mediaType: "image/png", expectedRevision: 0, author: .human, blobs: store)
        let second = try service.importRepositoryAsset(data, name: "Avatar Copy", scopeID: scopeID, mediaType: "image/png", expectedRevision: 1, author: .human, blobs: store)
        XCTAssertEqual(first.revision, 1)
        XCTAssertEqual(second.revision, 2)
        let assets = try repository.load().assets
        XCTAssertEqual(assets.count, 2)
        XCTAssertEqual(assets[0].contentHash, assets[1].contentHash)
        guard case .repository(let relativePath) = assets[0].source else { return XCTFail("Expected repository asset") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: path.appendingPathComponent("assets/blobs").path).count, 1)
        XCTAssertEqual(try repository.diagnostics(), [])
        try Data("corrupt".utf8).write(to: path.appendingPathComponent(relativePath))
        XCTAssertTrue(try repository.diagnostics().contains(where: { $0.rule == "asset.integrity" }))
        XCTAssertThrowsError(try repository.load())
    }

    func testScopeOwnershipAndPromotionCandidate() {
        let app = ArchitectureScope(id: EntityID("scope_app"), name: "App", parentID: nil)
        let commerce = ArchitectureScope(id: EntityID("scope_commerce"), name: "Commerce", parentID: app.id)
        let product = ArchitectureScope(id: EntityID("scope_product"), name: "Product", parentID: commerce.id)
        let checkout = ArchitectureScope(id: EntityID("scope_checkout"), name: "Checkout", parentID: commerce.id)
        let evaluator = ScopeEvaluator([app, commerce, product, checkout])
        XCTAssertTrue(evaluator.canUse(owner: commerce.id, consumer: checkout.id))
        XCTAssertFalse(evaluator.canUse(owner: product.id, consumer: checkout.id))
        XCTAssertEqual(evaluator.leastCommonAncestor([product.id, checkout.id]), commerce.id)
    }

    func testAppSurfaceCannotClaimAnotherScreensArchitectureScope() throws {
        var document = Document(name: "Scope")
        let appID = try XCTUnwrap(document.scopes.first?.id)
        let other = ArchitectureScope(id: EntityID("scope_other"), name: "Other", parentID: appID)
        document.scopes.append(other)
        let screen = Screen(id: EntityID("screen_main"), name: "Main", scopeID: appID, root: Layer(id: EntityID("layer_root"), kind: .stack, name: "Root"))
        document.screens = [screen]
        let target = Target(id: EntityID("target_main"), platform: .macOS, framework: .swiftUI)
        document.targets = [target]
        let surface = AppSurface(id: EntityID("surface_main"), targetID: target.id, device: "Mac", runtime: "macOS 26", buildEnvironment: "macOS SDK", screenID: screen.id, architectureScopeID: other.id)
        document.pages = [Page(id: EntityID("page_main"), name: "Main", surfaces: [surface])]
        XCTAssertTrue(DocumentValidator.validate(document).contains(where: { $0.rule == "surface.scopeMismatch" }))
        document.pages[0].surfaces[0].architectureScopeID = appID
        document.pages[0].surfaces[0].runtime = "iOS 26"
        XCTAssertTrue(DocumentValidator.validate(document).contains(where: { $0.rule == "surface.runtimePlatform" }))
    }

    func testHumanAndAgentMeetSameScopeValidation() throws {
        var document = Document(name: "Test")
        let appID = try XCTUnwrap(document.scopes.first?.id)
        let product = ArchitectureScope(id: EntityID("scope_product"), name: "Product", parentID: appID)
        let checkout = ArchitectureScope(id: EntityID("scope_checkout"), name: "Checkout", parentID: appID)
        document.scopes += [product, checkout]
        let definition = ComponentDefinition(id: EntityID("component_price"), name: "Price", ownerScopeID: product.id, root: Layer(id: EntityID("layer_definition"), kind: .stack, name: "Root"))
        document.components = [definition]
        let screen = Screen(id: EntityID("screen_checkout"), name: "Checkout", scopeID: checkout.id, root: Layer(id: EntityID("layer_root"), kind: .stack, name: "Root"))
        document.screens = [screen]
        let intent = AuthoringIntent.instantiate(screenID: screen.id, parentID: screen.root.id, definitionID: definition.id)
        for author in [Author.human, .agent] {
            XCTAssertThrowsError(try MutationEngine.apply(intent, to: document, expectedRevision: 0, author: author, agent: AgentHarness(profileName: "test"))) { error in
                guard case AuthoringError.validation(let diagnostics) = error else { return XCTFail("Wrong error") }
                XCTAssertTrue(diagnostics.contains(where: { $0.rule == "scope.notAncestor" }))
            }
        }
    }

    func testNestedComponentAvailabilityMatchesPickerIndexAndMutation() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let repository = CanonicalRepository(root: path)
        var document = try repository.create(name: "Nested availability")
        let appID = try XCTUnwrap(document.scopes.first?.id)
        let checkout = ArchitectureScope(id: EntityID("scope_checkout"), name: "Checkout", parentID: appID)
        document.scopes.append(checkout)
        var inner = ComponentDefinition(id: EntityID("component_inner"), name: "Inner", ownerScopeID: appID, root: Layer(id: EntityID("layer_inner_root"), kind: .stack, name: "Root"))
        inner.availability.denyScopeIDs = [checkout.id]
        let nested = Layer(id: EntityID("layer_nested"), kind: .componentInstance, name: "Inner", component: ComponentInstance(definitionID: inner.id))
        let outer = ComponentDefinition(id: EntityID("component_outer"), name: "Outer", ownerScopeID: appID, root: Layer(id: EntityID("layer_outer_root"), kind: .stack, name: "Root", children: [nested]))
        document.components = [inner, outer]
        let screen = Screen(id: EntityID("screen_checkout"), name: "Checkout", scopeID: checkout.id, root: Layer(id: EntityID("layer_checkout_root"), kind: .stack, name: "Root"))
        document.screens = [screen]
        document.revision = 1
        try repository.save(document, expectedRevision: 0)

        let service = ProjectService(repository: repository)
        XCTAssertEqual(try service.availableComponents(for: checkout.id).count, 0)
        let index = try LocalIndex(projectRoot: path)
        try index.rebuild(from: document)
        XCTAssertEqual(try index.components(matching: "Outer", consumerScopeID: checkout.id, documentID: document.id, revision: 1).count, 0)

        let intent = AuthoringIntent.instantiate(screenID: screen.id, parentID: screen.root.id, definitionID: outer.id)
        for author in [Author.human, .agent] {
            XCTAssertThrowsError(try service.mutate(intent, expectedRevision: 1, author: author, agent: AgentHarness(profileName: "test"))) { error in
                guard case AuthoringError.validation(let diagnostics) = error else { return XCTFail("Wrong error") }
                XCTAssertTrue(diagnostics.contains(where: { $0.rule == "component.denied" }))
            }
        }
    }

    func testAvailabilityPolicyCannotReferenceMissingOrContradictoryScopes() throws {
        var document = Document(name: "Policy")
        let appID = try XCTUnwrap(document.scopes.first?.id)
        var component = ComponentDefinition(id: EntityID("component_action"), name: "Action", ownerScopeID: appID, root: Layer(id: EntityID("layer_action"), kind: .stack, name: "Root"))
        component.availability = AvailabilityPolicy(denyScopeIDs: [appID, EntityID("scope_missing")], allowOnlyScopeIDs: [appID])
        document.components = [component]
        let rules = Set(DocumentValidator.validate(document).map(\.rule))
        XCTAssertTrue(rules.contains("component.availabilityScope"))
        XCTAssertTrue(rules.contains("component.availabilityConflict"))
    }

    func testAssetPickerAndMutationShareArchitectureScopeRule() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let repository = CanonicalRepository(root: path)
        var document = try repository.create(name: "Asset Scope")
        let appID = try XCTUnwrap(document.scopes.first?.id)
        let product = ArchitectureScope(id: EntityID("scope_product"), name: "Product", parentID: appID)
        let checkout = ArchitectureScope(id: EntityID("scope_checkout"), name: "Checkout", parentID: appID)
        document.scopes += [product, checkout]
        let appAsset = Asset(id: EntityID("asset_app"), name: "Shared", ownerScopeID: appID, mediaType: "image/system", source: .system(name: "star"))
        let productAsset = Asset(id: EntityID("asset_product"), name: "Product", ownerScopeID: product.id, mediaType: "image/system", source: .system(name: "heart"))
        document.assets = [appAsset, productAsset]
        let screen = Screen(id: EntityID("screen_checkout"), name: "Checkout", scopeID: checkout.id, root: Layer(id: EntityID("layer_root"), kind: .stack, name: "Root"))
        document.screens = [screen]
        document.revision = 1
        try repository.save(document, expectedRevision: 0)
        let service = ProjectService(repository: repository)
        XCTAssertEqual(try service.availableAssets(for: checkout.id).map(\.id), [appAsset.id])
        let intent = AuthoringIntent.addImageLayer(screenID: screen.id, parentID: screen.root.id, assetID: productAsset.id, name: "Forbidden")
        for author in [Author.human, .agent] {
            XCTAssertThrowsError(try service.mutate(intent, expectedRevision: 1, author: author, agent: AgentHarness(profileName: "builder"))) { error in
                guard case AuthoringError.validation(let diagnostics) = error else { return XCTFail("Wrong error") }
                XCTAssertTrue(diagnostics.contains(where: { $0.rule == "scope.asset" }))
            }
        }
    }

    func testSemanticMutationRoundTripsThroughCanonicalFiles() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let repository = CanonicalRepository(root: path)
        let created = try repository.create(name: "Round Trip")
        let service = ProjectService(repository: repository)
        let scopeID = try XCTUnwrap(created.scopes.first?.id)
        let result = try service.mutate(.createScreen(name: "Profile", scopeID: scopeID), expectedRevision: 0, author: .human)
        XCTAssertEqual(result.revision, 1)
        let screen = try XCTUnwrap(service.document().screens.first)
        XCTAssertThrowsError(try service.mutate(.createPage(name: "Late"), expectedRevision: 0, author: .agent, agent: AgentHarness(profileName: "test")))
        let edited = try service.mutate(.addLayer(screenID: screen.id, parentID: screen.root.id, kind: .text, name: "Heading", text: "Hello"), expectedRevision: 1, author: .agent, agent: AgentHarness(profileName: "test"))
        XCTAssertEqual(edited.patches.first?.path, "children")
        XCTAssertEqual(try repository.load().screens.first?.root.children.first?.text, "Hello")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.appendingPathComponent("screens/\(screen.id.rawValue).json").path))
    }

    func testPreviewPatchRejectsOutOfOrderAndBuildChanges() {
        let base = PreviewPatch(documentID: EntityID("doc"), surfaceID: EntityID("surface"), revision: 2, boundary: .instantPatch, changes: [PreviewChange(layerID: EntityID("layer"), path: "text", value: "Updated")])
        XCTAssertFalse(PreviewRevisionGate.accept(base, after: 0).accepted)
        XCTAssertTrue(PreviewRevisionGate.accept(base, after: 1).accepted)
        var build = base
        build.boundary = .fullBuild
        XCTAssertFalse(PreviewRevisionGate.accept(build, after: 1).accepted)
    }

    func testDisposableIndexRebuildsAvailabilityFromCanonicalDocument() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let repository = CanonicalRepository(root: path)
        var document = try repository.create(name: "Index")
        let appID = try XCTUnwrap(document.scopes.first?.id)
        let denied = ArchitectureScope(id: EntityID("scope_denied"), name: "Denied", parentID: appID)
        document.scopes.append(denied)
        var component = ComponentDefinition(id: EntityID("component_button"), name: "Button", ownerScopeID: appID, root: Layer(id: EntityID("layer_button_root"), kind: .stack, name: "Root"))
        component.availability.denyScopeIDs = [denied.id]
        document.components.append(component)
        document.revision = 1
        try repository.save(document, expectedRevision: 0)
        let index = try LocalIndex(projectRoot: path)
        try index.rebuild(from: document)
        XCTAssertEqual(try index.components(matching: "But", consumerScopeID: appID, documentID: document.id, revision: 1).count, 1)
        XCTAssertEqual(try index.components(matching: "But", consumerScopeID: denied.id, documentID: document.id, revision: 1).count, 0)
        try FileManager.default.removeItem(at: index.url)
        let rebuilt = try LocalIndex(projectRoot: path)
        try rebuilt.rebuild(from: repository.load())
        XCTAssertEqual(try rebuilt.components(matching: "But", consumerScopeID: appID, documentID: document.id, revision: 1).count, 1)
    }

    func testComponentResolutionKeepsInstanceAsReferenceAndRejectsOverrideConflicts() throws {
        let text = Layer(id: EntityID("layer_label"), kind: .text, name: "Label", text: "Default")
        let slot = Layer(id: EntityID("layer_slot"), kind: .stack, name: "Trailing")
        var definition = ComponentDefinition(id: EntityID("component_button"), name: "Button", ownerScopeID: EntityID("scope_app"), root: Layer(id: EntityID("layer_root"), kind: .stack, name: "Root", children: [text, slot]))
        definition.api.properties = [ComponentProperty(name: "label", kind: .text, targetPath: "layer_label.text")]
        definition.api.slots = [ComponentSlot(name: "trailing", targetLayerID: slot.id)]
        definition.api.overridablePaths = ["layer_label.text"]
        definition.variants = [ComponentVariant(id: EntityID("variant_large"), axis: "size", value: "large", propertyOverrides: ["layer_label.text": "Large"])]
        let slotContent = Layer(id: EntityID("layer_icon"), kind: .text, name: "Icon", text: "→")
        let instance = ComponentInstance(definitionID: definition.id, variantSelection: ["size": "large"], propertyValues: ["label": "Property"], slotContent: ["trailing": [slotContent]], allowedOverrides: ["layer_label.text": "Continue"])
        let resolved = try ComponentResolver.resolve(instance, definition: definition)
        XCTAssertEqual(resolved.children.first?.text, "Continue")
        XCTAssertEqual(resolved.children.last?.children.first?.text, "→")
        XCTAssertEqual(definition.root.children.first?.text, "Default")
        var conflict = definition
        conflict.variants.append(ComponentVariant(id: EntityID("variant_loading"), axis: "state", value: "loading", propertyOverrides: ["layer_label.text": "Wait"]))
        var selected = instance
        selected.variantSelection["state"] = "loading"
        XCTAssertThrowsError(try ComponentResolver.resolve(selected, definition: conflict))
    }

    func testStandaloneGenerationAndIntegrationContractUseDifferentSemantics() throws {
        var document = Document(name: "Profile")
        let scopeID = try XCTUnwrap(document.scopes.first?.id)
        let target = Target(id: EntityID("target_swiftui"), platform: .iOS, framework: .swiftUI)
        document.targets = [target]
        var label = Layer(id: EntityID("layer_name"), kind: .text, name: "Name", text: "Preview")
        let root = Layer(id: EntityID("layer_profile_root"), kind: .stack, name: "Root", children: [label], layout: Layout(axis: .vertical))
        let screen = Screen(id: EntityID("screen_profile"), name: "Profile", scopeID: scopeID, root: root)
        document.screens = [screen]
        let generated = try SwiftUIGenerator.generate(document: document, screenID: screen.id, targetID: target.id)
        XCTAssertTrue(generated.source.contains("Text(\"Preview\")"))
        label.textBinding = "user.name"
        document.screens[0].root.children[0] = label
        XCTAssertThrowsError(try SwiftUIGenerator.generate(document: document, screenID: screen.id, targetID: target.id))
        let contract = try IntegrationContracts.make(screenID: screen.id, document: document)
        XCTAssertEqual(contract.inputs, ["user.name"])
        let plan = IntegrationContracts.plan(contract, profile: IntegrationProfile(repositoryName: "Product"))
        XCTAssertEqual(plan.unresolvedMappings, ["input:user.name"])
    }

    func testCanonicalValidationReportsSemanticErrorsWithoutLoadingIntoApplication() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let repository = CanonicalRepository(root: path)
        let document = try repository.create(name: "Invalid")
        let scopeID = try XCTUnwrap(document.scopes.first?.id)
        let file = path.appendingPathComponent("scopes/\(scopeID.rawValue).json")
        var data = try Data(contentsOf: file)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["parentID"] = ["rawValue": "scope_missing"]
        data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: file)
        XCTAssertTrue(try repository.diagnostics().contains(where: { $0.rule == "scope.invalidTree" }))
        XCTAssertThrowsError(try repository.load())
    }

    func testTargetPlanBlocksUndeclaredAndUnapprovedCapabilities() throws {
        var document = Document(name: "Preview")
        let scopeID = try XCTUnwrap(document.scopes.first?.id)
        let target = Target(id: EntityID("target_ios"), platform: .iOS, framework: .swiftUI)
        document.targets = [target]
        let root = Layer(id: EntityID("layer_root"), kind: .stack, name: "Root", children: [Layer(id: EntityID("layer_text"), kind: .text, name: "Title", text: "Hello")])
        let screen = Screen(id: EntityID("screen_main"), name: "Main", scopeID: scopeID, root: root)
        document.screens = [screen]
        let surface = AppSurface(id: EntityID("surface_ios"), targetID: target.id, device: "iPhone", runtime: "iOS 26", buildEnvironment: "iOS SDK 26", screenID: screen.id, architectureScopeID: scopeID)
        document.capabilityDeclarations = [CapabilityDeclaration(targetID: target.id, key: CapabilityKey("layout.stack"), support: .portable)]
        let missing = TargetPlanner.plan(surface: surface, document: document)
        XCTAssertFalse(missing.canPreview)
        XCTAssertTrue(missing.diagnostics.contains(where: { $0.rule == "capability.unsupported" }))
        document.capabilityDeclarations.append(CapabilityDeclaration(targetID: target.id, key: CapabilityKey("component.text"), support: .approximate))
        XCTAssertFalse(TargetPlanner.plan(surface: surface, document: document).canPreview)
        XCTAssertTrue(TargetPlanner.plan(surface: surface, document: document, approvedApproximationKeys: [CapabilityKey("component.text")]).canPreview)
    }

    func testSystemNavigationIsSemanticAndCannotDisappearDuringGeneration() throws {
        var document = Document(name: "Navigation")
        let scopeID = try XCTUnwrap(document.scopes.first?.id)
        let target = Target(id: EntityID("target_ios"), platform: .iOS, framework: .swiftUI)
        document.targets = [target]
        var screen = Screen(id: EntityID("screen_nav"), name: "Home", scopeID: scopeID, root: Layer(id: EntityID("layer_root"), kind: .stack, name: "Root"))
        screen.navigation = .system(SystemNavigation(title: "Home", toolbarItems: [SystemToolbarItem(id: EntityID("toolbar_edit"), title: "Edit", emittedEvent: "editTapped")]))
        document.screens = [screen]
        let contract = try IntegrationContracts.make(screenID: screen.id, document: document)
        XCTAssertEqual(contract.nativeIntents, ["navigation.system"])
        XCTAssertEqual(contract.events, ["editTapped"])
        XCTAssertThrowsError(try SwiftUIGenerator.generate(document: document, screenID: screen.id, targetID: target.id))
    }

    func testInteractionStateMachineSeparatesActionAndMotion() {
        let motionID = EntityID("motion_spring")
        let interaction = Interaction(id: EntityID("interaction_expand"), name: "Expand", states: ["collapsed", "expanded"], transitions: [Transition(from: "collapsed", event: "tap", to: "expanded", motionID: motionID, actions: [.emitEvent("expanded")])])
        let step = InteractionEngine.advance(interaction, from: "collapsed", event: "tap")
        XCTAssertEqual(step?.to, "expanded")
        XCTAssertEqual(step?.actions, [.emitEvent("expanded")])
        XCTAssertEqual(step?.motionID, motionID)
        XCTAssertNil(InteractionEngine.advance(interaction, from: "expanded", event: "tap"))
    }

    func testMigrationPreflightDoesNotRewriteUnknownCanonicalFormat() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let repository = CanonicalRepository(root: path)
        _ = try repository.create(name: "Migration")
        let file = path.appendingPathComponent("hamii.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        object["formatVersion"] = 0
        let original = try JSONSerialization.data(withJSONObject: object)
        try original.write(to: file)
        let plan = try MigrationPreflight.plan(repository: path)
        XCTAssertEqual(plan.classification, .manual)
        XCTAssertEqual(plan.state, "noMigrationEdge")
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertThrowsError(try repository.load())
    }

    func testNativeRuntimeAppliesValuePatchAtNextRevision() async throws {
        try await MainActor.run {
            var document = Document(name: "Native")
            let scopeID = try XCTUnwrap(document.scopes.first?.id)
            let target = Target(id: EntityID("target_macos"), platform: .macOS, framework: .swiftUI)
            document.targets = [target]
            let text = Layer(id: EntityID("layer_title"), kind: .text, name: "Title", text: "Before")
            let screen = Screen(id: EntityID("screen_main"), name: "Main", scopeID: scopeID, root: Layer(id: EntityID("layer_root"), kind: .stack, name: "Root", children: [text]))
            document.screens = [screen]
            document.capabilityDeclarations = [
                CapabilityDeclaration(targetID: target.id, key: CapabilityKey("layout.stack"), support: .portable),
                CapabilityDeclaration(targetID: target.id, key: CapabilityKey("component.text"), support: .exact)
            ]
            let runtime = "macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)"
            let surface = AppSurface(id: EntityID("surface_main"), targetID: target.id, device: "Mac", runtime: runtime, buildEnvironment: "macOS SDK", screenID: screen.id, architectureScopeID: scopeID)
            let session = try NativePreviewSession(document: document, surface: surface)
            let patch = PreviewPatch(documentID: document.id, surfaceID: surface.id, revision: 1, boundary: .instantPatch, changes: [PreviewChange(layerID: text.id, path: "text", value: "After")])
            XCTAssertTrue(session.apply(patch).accepted)
            XCTAssertEqual(session.document.screens[0].root.children[0].text, "After")
            XCTAssertFalse(session.apply(patch).accepted)
        }
    }

    func testNativeRuntimeRejectsPatchThatBreaksAuthoringRule() async throws {
        try await MainActor.run {
            var document = Document(name: "Controls")
            let scopeID = try XCTUnwrap(document.scopes.first?.id)
            let target = Target(id: EntityID("target_macos"), platform: .macOS, framework: .swiftUI)
            document.targets = [target]
            let button = Layer(id: EntityID("layer_button"), kind: .button, name: "Save", text: "Save")
            document.screens = [Screen(id: EntityID("screen_main"), name: "Main", scopeID: scopeID, root: Layer(id: EntityID("layer_root"), kind: .stack, name: "Root", children: [button]))]
            document.capabilityDeclarations = [
                CapabilityDeclaration(targetID: target.id, key: CapabilityKey("layout.stack"), support: .portable),
                CapabilityDeclaration(targetID: target.id, key: CapabilityKey("component.button"), support: .exact)
            ]
            let runtime = "macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)"
            let surface = AppSurface(id: EntityID("surface_main"), targetID: target.id, device: "Mac", runtime: runtime, buildEnvironment: "macOS SDK", screenID: document.screens[0].id, architectureScopeID: scopeID)
            let session = try NativePreviewSession(document: document, surface: surface)
            let invalid = PreviewPatch(documentID: document.id, surfaceID: surface.id, revision: 1, boundary: .instantPatch, changes: [PreviewChange(layerID: button.id, path: "text", value: "")])
            let result = session.apply(invalid)
            XCTAssertFalse(result.accepted)
            XCTAssertTrue(result.diagnostics.contains(where: { $0.rule == "accessibility.controlLabel" }))
            XCTAssertEqual(session.appliedRevision, 0)
        }
    }

    func testAuthoringBatchIsAtomicAndHonorsBothMutationLimits() throws {
        var document = Document(name: "Batch")
        document.authoringHarness.maximumMutationNodes = 2
        let intents: [AuthoringIntent] = [.createPage(name: "One"), .createPage(name: "Two")]
        let (updated, result) = try MutationEngine.apply(intents, to: document, expectedRevision: 0, author: .agent, agent: AgentHarness(profileName: "builder", maximumMutations: 2))
        XCTAssertEqual(updated.pages.count, 2)
        XCTAssertEqual(result.revision, 1)
        XCTAssertEqual(result.patches.count, 2)
        XCTAssertThrowsError(try MutationEngine.apply(intents, to: document, expectedRevision: 0, author: .agent, agent: AgentHarness(profileName: "limited", maximumMutations: 1)))
        let invalid: [AuthoringIntent] = [.createPage(name: "One"), .createScope(name: "Broken", parentID: EntityID("scope_missing"))]
        XCTAssertThrowsError(try MutationEngine.apply(invalid, to: document, expectedRevision: 0, author: .human))
        XCTAssertEqual(document.pages.count, 0)
    }
}
