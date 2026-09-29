import Foundation
import XCTest
import HamiiCore
import HamiiApplication
@testable import HamiiFormat
@testable import HamiiIndex
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
            let created = base
            let scopeID = try XCTUnwrap(base.scopes.first?.id)
            base.pages = [Page(id: EntityID("page_old"), name: "Old")]
            base.revision = 1
            try repository.save(base, expected: created)
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
            XCTAssertThrowsError(try interrupted.save(updated, expected: base), "stop: \(stop)")
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
        let created = base
        base.pages = [Page(id: EntityID("page_old"), name: "Old")]
        base.revision = 1
        try repository.save(base, expected: created)
        var updated = base
        updated.pages = [Page(id: EntityID("page_new"), name: "New")]
        updated.revision = 2
        let interrupted = CanonicalRepository(root: path) { step in
            if case .ready = step { throw Stopped() }
        }
        XCTAssertThrowsError(try interrupted.save(updated, expected: base))
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

    func testGitCheckoutBeforeCanonicalApplyStopsSaveAndPreservesExternalBytes() throws {
        enum ProbeError: Error { case git }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", path.path] + arguments
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw ProbeError.git }
        }

        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"])
        try Data(".hamii/\n".utf8).write(to: path.appendingPathComponent(".gitignore"))
        let repository = CanonicalRepository(root: path)
        var base = try repository.create(name: "Checkout")
        let created = base
        let scopeID = try XCTUnwrap(base.scopes.first?.id)
        let componentID = EntityID("component_checkout")
        base.components = [ComponentDefinition(id: componentID, name: "BaseButton", ownerScopeID: scopeID, root: Layer(id: EntityID("layer_checkout"), kind: .stack, name: "Root"))]
        base.revision = 1
        try repository.save(base, expected: created)
        try git(["add", "-A"])
        try git(["-c", "user.name=Probe", "-c", "user.email=probe@example.invalid", "commit", "-qm", "baseline"])

        let componentFile = path.appendingPathComponent("components/\(componentID.rawValue).json")
        try git(["switch", "-qc", "external"])
        let baselineBytes = try Data(contentsOf: componentFile)
        let externalBytes = try XCTUnwrap(String(data: baselineBytes, encoding: .utf8)).replacingOccurrences(of: "BaseButton", with: "ExternalButton").data(using: .utf8)!
        try externalBytes.write(to: componentFile)
        try git(["add", "-A"])
        try git(["-c", "user.name=Probe", "-c", "user.email=probe@example.invalid", "commit", "-qm", "external edit"])
        try git(["switch", "-q", "main"])

        var updated = base
        updated.components[0].name = "HamiiButton"
        updated.revision = 2
        let interrupted = CanonicalRepository(root: path) { step in
            if case .ready = step { try git(["switch", "-q", "external"]) }
        }
        XCTAssertThrowsError(try interrupted.save(updated, expected: base)) { error in
            guard case CanonicalError.transactionConflict(let file) = error else { return XCTFail("Wrong error: \(error)") }
            XCTAssertEqual(file, "components/\(componentID.rawValue).json")
        }
        XCTAssertEqual(try Data(contentsOf: componentFile), externalBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.appendingPathComponent(".hamii/transaction.ready").path))
    }

    func testExternalEditAfterLoadStopsSaveBeforeJournalAndPreservesBytes() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let repository = CanonicalRepository(root: path)
        var base = try repository.create(name: "External edit")
        let created = base
        let owner = try XCTUnwrap(base.scopes.first?.id)
        base.components = [ComponentDefinition(id: EntityID("component_probe"), name: "BaseButton", ownerScopeID: owner, root: Layer(id: EntityID("layer_probe"), kind: .stack, name: "Root"))]
        base.revision = 1
        try repository.save(base, expected: created)

        let loaded = try repository.load()
        let componentFile = path.appendingPathComponent("components/component_probe.json")
        let externalBytes = try XCTUnwrap(String(data: Data(contentsOf: componentFile), encoding: .utf8)?
            .replacingOccurrences(of: "BaseButton", with: "ExternalButton").data(using: .utf8))
        try externalBytes.write(to: componentFile)

        var intended = loaded
        intended.components[0].name = "HamiiButton"
        intended.revision = 2
        XCTAssertThrowsError(try repository.save(intended, expected: loaded)) { error in
            guard case CanonicalError.transactionConflict(let file) = error else { return XCTFail("Wrong error: \(error)") }
            XCTAssertEqual(file, "components/component_probe.json")
        }
        XCTAssertEqual(try Data(contentsOf: componentFile), externalBytes)
        XCTAssertEqual(try repository.load().components[0].name, "ExternalButton")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.appendingPathComponent(".hamii/transaction.ready").path))
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
        let generationBefore = try CanonicalGenerationStore(root: path).readStable().generation
        let initialState = try service.observe().statePrecondition
        XCTAssertThrowsError(try service.importRepositoryAsset(data, name: "Denied", scopeID: scopeID, mediaType: "image/png", expectedState: initialState, author: .agent, agent: AgentHarness(profileName: "reviewer", maximumMutations: 0), blobs: store))
        XCTAssertEqual(try CanonicalGenerationStore(root: path).readStable().generation, generationBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.appendingPathComponent("assets/blobs").path))
        let first = try service.importRepositoryAsset(data, name: "Avatar", scopeID: scopeID, mediaType: "image/png", expectedState: initialState, author: .human, blobs: store)
        XCTAssertEqual(try CanonicalGenerationStore(root: path).readStable().generation.value, generationBefore.value + 1)
        let second = try service.importRepositoryAsset(data, name: "Avatar Copy", scopeID: scopeID, mediaType: "image/png", expectedState: try XCTUnwrap(first.statePrecondition), author: .human, blobs: store)
        XCTAssertEqual(try CanonicalGenerationStore(root: path).readStable().generation.value, generationBefore.value + 2)
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
        let created = document
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
        try repository.save(document, expected: created)
        try initializeGit(at: path)

        let service = ProjectService(repository: repository)
        XCTAssertEqual(try service.availableComponents(for: checkout.id).count, 0)
        let index = try LocalIndex(projectRoot: path, documentID: document.id, revisionCalculator: GitCanonicalRevisionCalculator(), storageRoot: path.appendingPathComponent("test-indexes"))
        let revision = try GitCanonicalRevisionCalculator().current(at: path)
        let snapshot = try repository.withCoordinatedSnapshot { $0 }
        try index.rebuild(from: snapshot, canonicalRevision: revision)
        XCTAssertEqual(try index.components(matching: "Outer", consumerScopeID: checkout.id, documentID: document.id,
                                            revision: 1, expectedSourceIdentity: snapshot.identity).count, 0)

        let intent = AuthoringIntent.instantiate(screenID: screen.id, parentID: screen.root.id, definitionID: outer.id)
        for author in [Author.human, .agent] {
            XCTAssertThrowsError(try service.mutate(intent, expectedState: service.observe().statePrecondition, author: author, agent: AgentHarness(profileName: "test"))) { error in
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
        let created = document
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
        try repository.save(document, expected: created)
        let service = ProjectService(repository: repository)
        XCTAssertEqual(try service.availableAssets(for: checkout.id).map(\.id), [appAsset.id])
        let intent = AuthoringIntent.addImageLayer(screenID: screen.id, parentID: screen.root.id, assetID: productAsset.id, name: "Forbidden")
        for author in [Author.human, .agent] {
            XCTAssertThrowsError(try service.mutate(intent, expectedState: service.observe().statePrecondition, author: author, agent: AgentHarness(profileName: "builder"))) { error in
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
        let initialState = try service.observe().statePrecondition
        let result = try service.mutate(.createScreen(name: "Profile", scopeID: scopeID), expectedState: initialState, author: .human)
        XCTAssertEqual(result.revision, 1)
        let screen = try XCTUnwrap(service.document().screens.first)
        XCTAssertThrowsError(try service.mutate(.createPage(name: "Late"), expectedState: initialState, author: .agent, agent: AgentHarness(profileName: "test")))
        let edited = try service.mutate(.addLayer(screenID: screen.id, parentID: screen.root.id, kind: .text, name: "Heading", text: "Hello"), expectedState: try XCTUnwrap(result.statePrecondition), author: .agent, agent: AgentHarness(profileName: "test"))
        XCTAssertEqual(edited.patches.first?.path, "children")
        XCTAssertEqual(try repository.load().screens.first?.root.children.first?.text, "Hello")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.appendingPathComponent("screens/\(screen.id.rawValue).json").path))
    }

    func testPreviewPatchRejectsOutOfOrderAndBuildChanges() {
        let state = ClientPrecondition("state-1")
        let base = PreviewPatch(documentID: EntityID("doc"), surfaceID: EntityID("surface"), baseRevision: 1, revision: 2, baseState: state, newState: ClientPrecondition("state-2"), boundary: .instantPatch, changes: [PreviewChange(layerID: EntityID("layer"), path: "text", value: "Updated")])
        XCTAssertFalse(PreviewRevisionGate.accept(base, after: 0, state: state).accepted)
        XCTAssertTrue(PreviewRevisionGate.accept(base, after: 1, state: state).accepted)
        var wrongBase = base
        wrongBase.baseRevision = 0
        XCTAssertFalse(PreviewRevisionGate.accept(wrongBase, after: 1, state: state).accepted)
        var build = base
        build.boundary = .fullBuild
        XCTAssertFalse(PreviewRevisionGate.accept(build, after: 1, state: state).accepted)
    }

    func testDisposableIndexRebuildsAvailabilityFromCanonicalDocument() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let repository = CanonicalRepository(root: path)
        var document = try repository.create(name: "Index")
        let created = document
        let appID = try XCTUnwrap(document.scopes.first?.id)
        let denied = ArchitectureScope(id: EntityID("scope_denied"), name: "Denied", parentID: appID)
        document.scopes.append(denied)
        var component = ComponentDefinition(id: EntityID("component_button"), name: "Button", ownerScopeID: appID, root: Layer(id: EntityID("layer_button_root"), kind: .stack, name: "Root"))
        component.availability.denyScopeIDs = [denied.id]
        document.components.append(component)
        document.revision = 1
        try repository.save(document, expected: created)
        try initializeGit(at: path)
        let index = try LocalIndex(projectRoot: path, documentID: document.id, revisionCalculator: GitCanonicalRevisionCalculator(), storageRoot: path.appendingPathComponent("test-indexes"))
        let revision = try GitCanonicalRevisionCalculator().current(at: path)
        let snapshot = try repository.withCoordinatedSnapshot { $0 }
        try index.rebuild(from: snapshot, canonicalRevision: revision)
        XCTAssertEqual(try index.components(matching: "But", consumerScopeID: appID, documentID: document.id,
                                            revision: 1, expectedSourceIdentity: snapshot.identity).count, 1)
        XCTAssertEqual(try index.components(matching: "But", consumerScopeID: denied.id, documentID: document.id,
                                            revision: 1, expectedSourceIdentity: snapshot.identity).count, 0)
        try FileManager.default.removeItem(at: index.url)
        let rebuilt = try LocalIndex(projectRoot: path, documentID: document.id, revisionCalculator: GitCanonicalRevisionCalculator(), storageRoot: path.appendingPathComponent("test-indexes"))
        try rebuilt.rebuild(from: snapshot, canonicalRevision: revision)
        XCTAssertEqual(try rebuilt.components(matching: "But", consumerScopeID: appID, documentID: document.id,
                                              revision: 1, expectedSourceIdentity: snapshot.identity).count, 1)
        let componentFile = path.appendingPathComponent("components/\(component.id.rawValue).json")
        var externalBytes = try Data(contentsOf: componentFile)
        externalBytes.append(0x0A)
        try externalBytes.write(to: componentFile)
        XCTAssertThrowsError(try rebuilt.components(matching: "But", consumerScopeID: appID, documentID: document.id,
                                                     revision: 1, expectedSourceIdentity: snapshot.identity)) { error in
            guard case IndexError.stale = error else { return XCTFail("Expected stale index") }
        }
    }

    func testLocalIndexLocationIsOutsideRepositoryAndIsolatesWorktrees() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let otherWorktree = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let documentID = EntityID("document_shared")
        let first = LocalIndexLocation.url(projectRoot: root, documentID: documentID)
        let second = LocalIndexLocation.url(projectRoot: otherWorktree, documentID: documentID)
        let differentDocument = LocalIndexLocation.url(projectRoot: root, documentID: EntityID("document_other"))
        XCTAssertFalse(first.path.hasPrefix(root.path + "/"))
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first, differentDocument)
        XCTAssertEqual(first.lastPathComponent, "index.sqlite")
    }

    func testIndexProjectionCountsNestedScreenInstances() throws {
        var document = Document(name: "Usage")
        let owner = try XCTUnwrap(document.scopes.first?.id)
        let firstID = EntityID("component_first")
        let secondID = EntityID("component_second")
        document.components = [
            ComponentDefinition(id: firstID, name: "First", ownerScopeID: owner, root: Layer(id: EntityID("definition_first"), kind: .stack, name: "Root")),
            ComponentDefinition(id: secondID, name: "Second", ownerScopeID: owner, root: Layer(id: EntityID("definition_second"), kind: .stack, name: "Root"))
        ]
        let first = Layer(id: EntityID("instance_first"), kind: .componentInstance, name: "First", component: ComponentInstance(definitionID: firstID))
        let firstAgain = Layer(id: EntityID("instance_first_again"), kind: .componentInstance, name: "First Again", component: ComponentInstance(definitionID: firstID))
        let second = Layer(id: EntityID("instance_second"), kind: .componentInstance, name: "Second", component: ComponentInstance(definitionID: secondID))
        let nested = Layer(id: EntityID("nested"), kind: .stack, name: "Nested", children: [second, firstAgain])
        document.screens = [Screen(id: EntityID("screen_usage"), name: "Usage", scopeID: owner, root: Layer(id: EntityID("root_usage"), kind: .stack, name: "Root", children: [first, nested]))]
        let counts = Dictionary(uniqueKeysWithValues: IndexProjection(document: document).components.map { ($0.id, $0.usageCount) })
        XCTAssertEqual(counts[firstID], 2)
        XCTAssertEqual(counts[secondID], 1)
    }

    func testCanonicalRevisionRejectsDirectoryWithoutGit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try CanonicalRepository(root: root).create(name: "No Git")
        XCTAssertThrowsError(try GitCanonicalRevisionCalculator().current(at: root)) { error in
            guard case IndexError.unverifiableSource = error else { return XCTFail("Wrong error: \(error)") }
        }
    }

    func testCanonicalRevisionRejectsBranchSwitchBetweenGitChecks() throws {
        enum ProbeError: Error { case git(String) }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        func git(_ arguments: [String]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", path.path] + arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            try process.run()
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw ProbeError.git(arguments.joined(separator: " ")) }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try git(["init", "-q"])
        try Data(".hamii/\n".utf8).write(to: path.appendingPathComponent(".gitignore"))
        let repository = CanonicalRepository(root: path)
        let created = try repository.create(name: "Branch race")
        let owner = try XCTUnwrap(created.scopes.first?.id)
        var base = created
        base.components = [ComponentDefinition(id: EntityID("component_race"), name: "BaseButton", ownerScopeID: owner, root: Layer(id: EntityID("layer_race"), kind: .stack, name: "Root"))]
        base.revision = 1
        try repository.save(base, expected: created)
        _ = try git(["add", "-A"])
        _ = try git(["-c", "user.name=Probe", "-c", "user.email=probe@example.invalid", "commit", "-qm", "base"])
        let baseBranch = try git(["symbolic-ref", "--short", "HEAD"])
        _ = try git(["switch", "-qc", "alternate"])
        let componentFile = path.appendingPathComponent("components/component_race.json")
        let alternate = try XCTUnwrap(String(data: Data(contentsOf: componentFile), encoding: .utf8)?
            .replacingOccurrences(of: "BaseButton", with: "XaseButton").data(using: .utf8))
        try alternate.write(to: componentFile)
        _ = try git(["add", "-A"])
        _ = try git(["-c", "user.name=Probe", "-c", "user.email=probe@example.invalid", "commit", "-qm", "alternate"])
        _ = try git(["switch", "-q", baseBranch])

        let calculator = GitCanonicalRevisionCalculator(afterInitialStatus: {
            _ = try git(["switch", "-q", "alternate"])
        })
        XCTAssertThrowsError(try calculator.current(at: path)) { error in
            guard case IndexError.stale = error else { return XCTFail("Wrong error: \(error)") }
        }
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
        XCTAssertEqual(resolved.children.first?.payload, .text(TextLayerPayload(value: "Continue")))
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
        document.capabilityDeclarations = [
            CapabilityDeclaration(targetID: target.id, key: CapabilityKeys.legacyStack, support: .portable),
            CapabilityDeclaration(targetID: target.id, key: CapabilityKeys.legacyText, support: .exact)
        ]
        var label = Layer(id: EntityID("layer_name"), kind: .text, name: "Name", text: "Preview")
        let root = Layer(id: EntityID("layer_profile_root"), kind: .stack, name: "Root", children: [label], layout: Layout(axis: .vertical))
        let screen = Screen(id: EntityID("screen_profile"), name: "Profile", scopeID: scopeID, root: root)
        document.screens = [screen]
        let generated = try SwiftUIGenerator.generate(document: document, screenID: screen.id, targetID: target.id)
        XCTAssertEqual(generated.source, "import SwiftUI\n\nstruct HamiiScreen_screen_profile: View {\n    var body: some View {\n        VStack {\n            Text(\"Preview\")\n        }\n    }\n}\n")
        label.textBinding = "user.name"
        document.screens[0].root.children[0] = label
        XCTAssertThrowsError(try SwiftUIGenerator.generate(document: document, screenID: screen.id, targetID: target.id)) { error in
            guard case GenerationError.unsupported(let id, let reason) = error else { return XCTFail("Unexpected generator error: \(error)") }
            XCTAssertEqual(id, label.id)
            XCTAssertEqual(reason, "Runtime binding requires product integration")
        }
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
        var versions = try XCTUnwrap(object["versions"] as? [String: Any])
        versions["document"] = 0
        object["versions"] = versions
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
            let session = try NativePreviewSession(document: document, surface: surface, statePrecondition: ClientPrecondition("state-0"))
            let patch = PreviewPatch(documentID: document.id, surfaceID: surface.id, baseRevision: 0, revision: 1, baseState: ClientPrecondition("state-0"), newState: ClientPrecondition("state-1"), boundary: .instantPatch, changes: [PreviewChange(layerID: text.id, path: "text", value: "After")])
            XCTAssertTrue(session.apply(patch).accepted)
            XCTAssertEqual(session.document.screens[0].root.children[0].text, "After")
            XCTAssertFalse(session.apply(patch).accepted)
            let missing = PreviewPatch(documentID: document.id, surfaceID: surface.id, baseRevision: 2, revision: 3, baseState: ClientPrecondition("state-1"), newState: ClientPrecondition("state-3"), boundary: .instantPatch, changes: [PreviewChange(layerID: text.id, path: "text", value: "Missing")])
            XCTAssertFalse(session.apply(missing).accepted)
            var resynced = document
            resynced.revision = 3
            resynced.screens[0].root.children[0].text = "Snapshot"
            var updatedSurface = surface
            updatedSurface.device = "MacBook"
            XCTAssertTrue(session.load(PreviewSnapshot(document: resynced, surface: updatedSurface, statePrecondition: ClientPrecondition("state-3"))).accepted)
            XCTAssertEqual(session.appliedRevision, 3)
            XCTAssertEqual(session.surface.device, "MacBook")
            XCTAssertEqual(session.document.screens[0].root.children[0].text, "Snapshot")
            let resumed = PreviewPatch(documentID: document.id, surfaceID: surface.id, baseRevision: 3, revision: 4, baseState: ClientPrecondition("state-3"), newState: ClientPrecondition("state-4"), boundary: .instantPatch, changes: [PreviewChange(layerID: text.id, path: "text", value: "Resumed")])
            XCTAssertTrue(session.apply(resumed).accepted)
            XCTAssertEqual(session.document.screens[0].root.children[0].text, "Resumed")
            var sameRevisionDifferentState = session.document
            sameRevisionDifferentState.screens[0].root.children[0].text = "Merged elsewhere"
            XCTAssertTrue(session.load(PreviewSnapshot(document: sameRevisionDifferentState, surface: updatedSurface, statePrecondition: ClientPrecondition("state-4-merged"))).accepted)
            let oldSessionPatch = PreviewPatch(documentID: document.id, surfaceID: surface.id, baseRevision: 4, revision: 5, baseState: ClientPrecondition("state-4"), newState: ClientPrecondition("state-5"), boundary: .instantPatch, changes: [PreviewChange(layerID: text.id, path: "text", value: "Old session")])
            XCTAssertFalse(session.apply(oldSessionPatch).accepted)
            XCTAssertEqual(session.document.screens[0].root.children[0].text, "Merged elsewhere")
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
            let session = try NativePreviewSession(document: document, surface: surface, statePrecondition: ClientPrecondition("state-0"))
            let invalid = PreviewPatch(documentID: document.id, surfaceID: surface.id, baseRevision: 0, revision: 1, baseState: ClientPrecondition("state-0"), newState: ClientPrecondition("state-1"), boundary: .instantPatch, changes: [PreviewChange(layerID: button.id, path: "text", value: "")])
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

    func testEquivalentMutationDoesNotWriteCanonicalRevision() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let repository = CanonicalRepository(root: path)
        let service = ProjectService(repository: repository)
        let initial = try repository.create(name: "No-op")
        let scopeID = try XCTUnwrap(initial.scopes.first?.id)
        let created = try service.mutate(.createScreen(name: "Welcome", scopeID: scopeID), expectedState: service.observe().statePrecondition, author: .human)
        let screen = try XCTUnwrap(service.document().screens.first)
        let inserted = try service.mutate(.addLayer(screenID: screen.id, parentID: screen.root.id, kind: .text, name: "Greeting", text: "Hello"), expectedState: try XCTUnwrap(created.statePrecondition), author: .human)
        let current = try service.document()
        let layerID = try XCTUnwrap(current.screens.first?.root.children.first?.id)
        let manifest = path.appendingPathComponent("hamii.json")
        let screenFile = path.appendingPathComponent("screens/\(screen.id.rawValue).json")
        let before = try Data(contentsOf: manifest)
        let screenBefore = try Data(contentsOf: screenFile)
        let snapshotBefore = try repository.withCoordinatedSnapshot { $0.identity }
        let result = try service.mutate(.setText(screenID: screen.id, layerID: layerID, text: "Hello"), expectedState: try XCTUnwrap(inserted.statePrecondition), author: .human)
        XCTAssertEqual(result.revision, inserted.revision)
        XCTAssertEqual(result.statePrecondition, inserted.statePrecondition)
        XCTAssertTrue(result.patches.isEmpty)
        XCTAssertEqual(try Data(contentsOf: manifest), before)
        XCTAssertEqual(try Data(contentsOf: screenFile), screenBefore)
        XCTAssertEqual(try repository.withCoordinatedSnapshot { $0.identity }, snapshotBefore)
        XCTAssertEqual(try service.document().revision, inserted.revision)
    }

    private func initializeGit(at root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "init", "-q"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
