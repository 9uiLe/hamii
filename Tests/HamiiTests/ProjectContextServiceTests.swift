import Foundation
import XCTest
import HamiiCore
import HamiiApplication

final class ProjectContextServiceTests: XCTestCase {
    private typealias ID = EntityID
    private static let app = ID("scope_app")
    private static let commerce = ID("scope_commerce")
    private static let checkout = ID("scope_checkout")
    private static let account = ID("scope_account")
    private static let screen = ID("screen_checkout")
    private static let parent = ID("layer_parent")
    private static let text = ID("layer_text")
    private static let component = ID("component_price_badge")
    private static let token = ID("token_spacing_checkout")

    private final class CountingRepository: ProjectRepository, ProjectObservationVerifying {
        var document: Document
        var generation = 0
        var observations = 0
        var verifications = 0
        var verificationFailure: Error?
        init(_ document: Document) { self.document = document }

        func observe() throws -> ProjectObservation {
            observations += 1
            return ProjectObservation(document: document,
                statePrecondition: ClientPrecondition("context-state-\(generation)"))
        }

        func commit(_ document: Document, expected: ProjectObservation) throws -> ProjectObservation {
            guard expected.statePrecondition == ClientPrecondition("context-state-\(generation)") else {
                throw AuthoringError.staleState
            }
            self.document = document
            generation += 1
            return try observe()
        }

        func verifyCurrent(_ expected: ClientPrecondition) throws {
            verifications += 1
            if let verificationFailure { throw verificationFailure }
            guard expected == ClientPrecondition("context-state-\(generation)") else {
                throw AuthoringError.staleState
            }
        }

        func transitionWithoutRevisionChange() {
            generation += 1
        }
    }

    private final class ConcurrentSessionBox: @unchecked Sendable {
        let session: ProjectContextReadSession
        let scopeID: EntityID
        let lock = NSLock()
        var stale = 0
        var invalidated = 0
        var unexpected = 0

        init(session: ProjectContextReadSession, scopeID: EntityID) {
            self.session = session
            self.scopeID = scopeID
        }

        func record(_ error: Error?) {
            lock.lock()
            defer { lock.unlock() }
            if let error {
                if case AuthoringError.staleState = error { stale += 1 }
                else if error as? ProjectContextSessionError == .invalidated { invalidated += 1 }
                else { unexpected += 1 }
            } else { unexpected += 1 }
        }
    }

    private func fixture() -> Document {
        var document = Document(name: "Context fixture")
        document.id = ID("document_context")
        document.scopes = [
            ArchitectureScope(id: Self.app, name: "App", parentID: nil),
            ArchitectureScope(id: Self.commerce, name: "Commerce", parentID: Self.app),
            ArchitectureScope(id: Self.checkout, name: "Checkout", parentID: Self.commerce),
            ArchitectureScope(id: Self.account, name: "Account", parentID: Self.app)
        ]
        document.pages = [Page(id: ID("page_main"), name: "Main")]
        let text = Layer(id: Self.text, kind: .text, name: "Summary", text: "Order summary")
        let parent = Layer(id: Self.parent, kind: .stack, name: "Content", children: [text])
        document.screens = [Screen(id: Self.screen, name: "Checkout", scopeID: Self.checkout, root: parent)]
        let base = ComponentDefinition(id: ID("component_app_base"), name: "Base",
            ownerScopeID: Self.app, root: Layer(id: ID("layer_base"), kind: .stack, name: "Base"))
        let price = ComponentDefinition(id: Self.component, name: "PriceBadge",
            ownerScopeID: Self.commerce, root: Layer(id: ID("layer_price"), kind: .stack, name: "Price"))
        let sibling = ComponentDefinition(id: ID("component_account"), name: "AccountBadge",
            ownerScopeID: Self.account, root: Layer(id: ID("layer_account"), kind: .stack, name: "Account"))
        var denied = ComponentDefinition(id: ID("component_denied"), name: "DeniedButton",
            ownerScopeID: Self.app, root: Layer(id: ID("layer_denied"), kind: .stack, name: "Denied"))
        denied.availability.denyScopeIDs = [Self.checkout]
        document.components = [base, price, sibling, denied]
        document.tokens = [
            DesignToken(id: ID("token_spacing_commerce"), name: "spacing.commerce", kind: .spacing,
                        ownerScopeID: Self.commerce, value: .literal("12")),
            DesignToken(id: Self.token, name: "spacing.checkout", kind: .spacing,
                        ownerScopeID: Self.checkout, value: .reference(ID("token_spacing_commerce"))),
            DesignToken(id: ID("token_spacing_account"), name: "spacing.account", kind: .spacing,
                        ownerScopeID: Self.account, value: .literal("16"))
        ]
        document.assets = [
            Asset(id: ID("asset_app"), name: "Logo", ownerScopeID: Self.app,
                  mediaType: "image/png", source: .system(name: "star")),
            Asset(id: ID("asset_account"), name: "Private", ownerScopeID: Self.account,
                  mediaType: "image/png", source: .system(name: "person"))
        ]
        return document
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    func testReadSessionSharesProjectionAndObservesOnlyOnce() throws {
        let currentRepository = CountingRepository(fixture())
        let current = ProjectContextService(repository: currentRepository)
        let selection = ContextSelection(screenID: Self.screen, layerID: Self.parent)
        let summary = try current.projectSummary(selection: selection)
        let state = summary.observation.statePrecondition
        let layer = try current.layerDetail(screenID: Self.screen, layerID: Self.parent, expectedState: state)
        let components = try current.resources(consumerScopeID: Self.checkout, kind: .component,
            expectedState: state)
        let tokens = try current.resources(consumerScopeID: Self.checkout, kind: .token, expectedState: state)
        let assets = try current.resources(consumerScopeID: Self.checkout, kind: .asset, expectedState: state)
        let component = try current.componentDetail(componentID: Self.component,
            consumerScopeID: Self.checkout, expectedState: state)
        let token = try current.tokenDetail(tokenID: Self.token, consumerScopeID: Self.checkout, expectedState: state)
        let denied = try current.resources(consumerScopeID: Self.checkout, kind: .component,
            matching: "AccountBadge", expectedState: state)
        XCTAssertEqual(currentRepository.observations, 8)

        let repository = CountingRepository(fixture())
        let started = try ProjectContextReadSession.start(repository: repository, selection: selection)
        let session = started.session
        XCTAssertEqual(try encoded(started.initialSummary), try encoded(summary))
        XCTAssertEqual(try encoded(session.layerDetail(screenID: Self.screen, layerID: Self.parent)), try encoded(layer))
        XCTAssertEqual(try encoded(session.resources(consumerScopeID: Self.checkout, kind: .component)), try encoded(components))
        XCTAssertEqual(try encoded(session.resources(consumerScopeID: Self.checkout, kind: .token)), try encoded(tokens))
        XCTAssertEqual(try encoded(session.resources(consumerScopeID: Self.checkout, kind: .asset)), try encoded(assets))
        XCTAssertEqual(try encoded(session.componentDetail(componentID: Self.component,
            consumerScopeID: Self.checkout)), try encoded(component))
        XCTAssertEqual(try encoded(session.tokenDetail(tokenID: Self.token,
            consumerScopeID: Self.checkout)), try encoded(token))
        let deniedSession = try session.resources(consumerScopeID: Self.checkout, kind: .component,
            matching: "AccountBadge")
        XCTAssertEqual(try encoded(deniedSession), try encoded(denied))
        XCTAssertTrue(deniedSession.payload.items.isEmpty)
        XCTAssertEqual(repository.observations, 1)
        XCTAssertEqual(repository.verifications, 7)
    }

    func testReadSessionInvalidationIsPermanentAndMutationStillRevalidates() throws {
        let repository = CountingRepository(fixture())
        let started = try ProjectContextReadSession.start(repository: repository)
        let state = started.initialSummary.observation.statePrecondition
        XCTAssertEqual(repository.observations, 1)
        _ = try started.session.layerDetail(screenID: Self.screen, layerID: Self.text)
        XCTAssertEqual(repository.verifications, 1)
        let service = ProjectService(repository: repository)
        _ = try service.mutate(.createPage(name: "Changed"), expectedState: state, author: .human)
        XCTAssertThrowsError(try started.session.layerDetail(screenID: Self.screen, layerID: Self.text)) { error in
            guard case AuthoringError.staleState = error else { return XCTFail("Wrong error: \(error)") }
        }
        repository.generation = 0 // Simulates bytes/token returning to an old state.
        XCTAssertThrowsError(try started.session.layerDetail(screenID: Self.screen, layerID: Self.text)) { error in
            XCTAssertEqual(error as? ProjectContextSessionError, .invalidated)
        }
        XCTAssertEqual(repository.verifications, 2, "An invalidated session must not retry verification")
        repository.generation = 1
        XCTAssertThrowsError(try service.mutate(.createPage(name: "Stale"),
            expectedState: state, author: .human)) { error in
            guard case AuthoringError.staleState = error else { return XCTFail("Wrong error: \(error)") }
        }
    }

    func testConcurrentFollowUpsSerializePermanentInvalidation() throws {
        let repository = CountingRepository(fixture())
        let session = try ProjectContextReadSession.start(repository: repository).session
        repository.verificationFailure = AuthoringError.staleState
        let box = ConcurrentSessionBox(session: session, scopeID: Self.checkout)
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            do {
                _ = try box.session.resources(consumerScopeID: box.scopeID, kind: .component)
                box.record(nil)
            } catch {
                box.record(error)
            }
        }
        XCTAssertEqual(box.stale, 1)
        XCTAssertEqual(box.invalidated, 15)
        XCTAssertEqual(box.unexpected, 0)
        XCTAssertEqual(repository.verifications, 1)
        XCTAssertEqual(repository.observations, 1)
    }

    func testSingleObservationScopeAndEndToEndSemanticMutations() throws {
        for task in ["text", "component", "token"] {
            let repository = CountingRepository(fixture())
            XCTAssertTrue(DocumentValidator.validate(repository.document).isEmpty)
            let context = ProjectContextService(repository: repository)
            let service = ProjectService(repository: repository)
            let summary = try context.projectSummary(selection: ContextSelection(
                screenID: Self.screen, layerID: task == "text" ? Self.text : Self.parent))
            XCTAssertEqual(repository.observations, 1)
            let state = summary.observation.statePrecondition
            XCTAssertEqual(summary.observation.documentRevision, repository.document.revision)
            XCTAssertEqual(summary.payload.selectedScreen?.scopeID, Self.checkout)
            let layer = try context.layerDetail(screenID: Self.screen,
                layerID: task == "text" ? Self.text : Self.parent, expectedState: state)
            XCTAssertEqual(repository.observations, 2)
            XCTAssertEqual(layer.observation, summary.observation)
            let layerJSON = try JSONSerialization.jsonObject(with: encoded(layer)) as! [String: Any]
            let payload = layerJSON["payload"] as! [String: Any]
            XCTAssertNil((payload["layer"] as! [String: Any])["children"])
            let result: MutationResult
            switch task {
            case "text":
                XCTAssertEqual(layer.payload.layer.text, "Order summary")
                result = try service.mutate(.setText(screenID: Self.screen, layerID: Self.text,
                    text: "Updated order summary"), expectedState: state, author: .human)
                XCTAssertEqual(result.patches.map(\.path), ["text"])
            case "component":
                let list = try context.resources(consumerScopeID: Self.checkout, kind: .component,
                    expectedState: state)
                XCTAssertEqual(repository.observations, 3)
                XCTAssertEqual(list.observation, summary.observation)
                XCTAssertEqual(Set(list.payload.items.map(\.id)), Set([ID("component_app_base"), Self.component]))
                let detail = try context.componentDetail(componentID: Self.component,
                    consumerScopeID: Self.checkout, expectedState: state)
                XCTAssertEqual(repository.observations, 4)
                XCTAssertEqual(detail.observation, summary.observation)
                let detailJSON = try JSONSerialization.jsonObject(with: encoded(detail)) as! [String: Any]
                XCTAssertNil(((detailJSON["payload"] as! [String: Any])["root"] as! [String: Any])["children"])
                result = try service.mutate(.instantiate(screenID: Self.screen,
                    parentID: Self.parent, definitionID: detail.payload.id),
                    expectedState: state, author: .human)
                XCTAssertEqual(result.patches.map(\.path), ["component.definitionID"])
            default:
                let list = try context.resources(consumerScopeID: Self.checkout, kind: .token,
                    expectedState: state)
                XCTAssertEqual(repository.observations, 3)
                XCTAssertEqual(Set(list.payload.items.map(\.id)),
                    Set([ID("token_spacing_commerce"), Self.token]))
                let detail = try context.tokenDetail(tokenID: Self.token,
                    consumerScopeID: Self.checkout, expectedState: state)
                XCTAssertEqual(repository.observations, 4)
                XCTAssertEqual(detail.payload.value, .reference(ID("token_spacing_commerce")))
                result = try service.mutate(.setLayoutToken(screenID: Self.screen,
                    layerID: Self.parent, property: .spacing, tokenID: detail.payload.id),
                    expectedState: state, author: .human)
                XCTAssertEqual(result.patches.map(\.path), ["layout.spacingTokenID"])
            }
            XCTAssertNotEqual(result.statePrecondition, state)
            XCTAssertThrowsError(try context.layerDetail(screenID: Self.screen,
                layerID: Self.text, expectedState: state)) { error in
                guard case AuthoringError.staleState = error else { return XCTFail("\(error)") }
            }
        }
    }

    func testSameRevisionTransitionRejectsAllFollowUpsBeforePayload() throws {
        let repository = CountingRepository(fixture())
        let context = ProjectContextService(repository: repository)
        let initial = try context.projectSummary()
        let state = initial.observation.statePrecondition
        let listed = try context.resources(consumerScopeID: Self.checkout, kind: .component,
            expectedState: state)
        XCTAssertEqual(listed.observation, initial.observation)
        repository.transitionWithoutRevisionChange()
        XCTAssertEqual(repository.document.revision, initial.observation.documentRevision)
        XCTAssertThrowsError(try context.layerDetail(screenID: Self.screen, layerID: Self.text,
            expectedState: state))
        XCTAssertThrowsError(try context.resources(consumerScopeID: Self.checkout, kind: .component,
            expectedState: state))
        XCTAssertThrowsError(try context.componentDetail(componentID: Self.component,
            consumerScopeID: Self.checkout, expectedState: state))
        XCTAssertThrowsError(try context.tokenDetail(tokenID: Self.token,
            consumerScopeID: Self.checkout, expectedState: state))
        XCTAssertThrowsError(try ProjectService(repository: repository).mutate(
            .setText(screenID: Self.screen, layerID: Self.text, text: "Stale"),
            expectedState: state, author: .human))
        XCTAssertEqual(repository.document.screens[0].root.children[0].text, "Order summary")
    }

    func testBoundsDeterminismAndUnavailableResources() throws {
        var document = fixture()
        for index in 0..<151 {
            document.components.append(ComponentDefinition(id: ID("component_extra_\(index)"),
                name: "Extra", ownerScopeID: Self.app,
                root: Layer(id: ID("layer_extra_\(index)"), kind: .stack, name: "Extra")))
        }
        let repository = CountingRepository(document)
        let context = ProjectContextService(repository: repository)
        let state = try context.projectSummary().observation.statePrecondition
        let defaultList = try context.resources(consumerScopeID: Self.checkout,
            kind: .component, expectedState: state)
        XCTAssertEqual(defaultList.payload.returnedCount, 32)
        XCTAssertTrue(defaultList.payload.truncated)
        let largeList = try context.resources(consumerScopeID: Self.checkout,
            kind: .component, limit: 100, expectedState: state)
        XCTAssertEqual(largeList.payload.returnedCount, 100)
        XCTAssertTrue(largeList.payload.truncated)
        XCTAssertThrowsError(try context.resources(consumerScopeID: Self.checkout,
            kind: .component, limit: 101, expectedState: state))
        XCTAssertEqual(repository.observations, 3, "Invalid limit must not read the repository")
        let matching = try context.resources(consumerScopeID: Self.checkout,
            kind: .component, matching: "Price", expectedState: state)
        XCTAssertEqual(matching.payload.items.map(\.id), [Self.component])
        let assets = try context.resources(consumerScopeID: Self.checkout,
            kind: .asset, expectedState: state)
        XCTAssertEqual(assets.payload.items.map(\.id), [ID("asset_app")])
        XCTAssertThrowsError(try context.componentDetail(componentID: ID("component_account"),
            consumerScopeID: Self.checkout, expectedState: state))
        XCTAssertThrowsError(try context.componentDetail(componentID: ID("component_denied"),
            consumerScopeID: Self.checkout, expectedState: state))
        XCTAssertThrowsError(try context.tokenDetail(tokenID: ID("token_spacing_account"),
            consumerScopeID: Self.checkout, expectedState: state))
        let first = try encoded(defaultList)
        for _ in 0..<2 {
            XCTAssertEqual(try encoded(context.resources(consumerScopeID: Self.checkout,
                kind: .component, expectedState: state)), first)
        }
        let ids = defaultList.payload.items.map(\.id.rawValue)
        XCTAssertEqual(ids, ids.sorted())
    }

    func testProductionServicePayloadRemainsBoundedAtOneAndTenThousandLayers() throws {
        func document(_ scale: Int) -> Document {
            var result = fixture()
            let extra = (0..<(scale - 3)).map { index in
                Layer(id: ID("layer_extra_\(index)"), kind: .text,
                      name: "Unrelated \(index)", text: "Unrelated value \(index)")
            }
            result.screens.append(Screen(id: ID("screen_other"), name: "Other",
                scopeID: Self.account,
                root: Layer(id: ID("layer_other_root"), kind: .stack,
                            name: "Other", children: extra)))
            return result
        }

        func sizes(_ document: Document, task: String) throws -> [Int] {
            let repository = CountingRepository(document)
            let context = ProjectContextService(repository: repository)
            let selected = task == "T1" || task == "S" ? Self.text : Self.parent
            let summary = try context.projectSummary(selection: ContextSelection(
                screenID: Self.screen, layerID: selected))
            let state = summary.observation.statePrecondition
            var result = [try encoded(summary).count]
            result.append(try encoded(context.layerDetail(screenID: Self.screen,
                layerID: selected, expectedState: state)).count)
            if task == "T2" || task == "N" {
                result.append(try encoded(context.resources(consumerScopeID: Self.checkout,
                    kind: .component, expectedState: state)).count)
                if task == "T2" {
                    result.append(try encoded(context.componentDetail(componentID: Self.component,
                        consumerScopeID: Self.checkout, expectedState: state)).count)
                }
            }
            if task == "T3" {
                result.append(try encoded(context.resources(consumerScopeID: Self.checkout,
                    kind: .token, expectedState: state)).count)
                result.append(try encoded(context.tokenDetail(tokenID: Self.token,
                    consumerScopeID: Self.checkout, expectedState: state)).count)
            }
            return result
        }

        let small = document(1_000)
        let large = document(10_000)
        XCTAssertEqual(small.screens.reduce(0) { $0 + 1 + $1.root.children.count }, 1_000)
        XCTAssertEqual(large.screens.reduce(0) { $0 + 1 + $1.root.children.count }, 10_000)
        let full = try encoded(large).count
        XCTAssertGreaterThan(full, 100_000)
        for task in ["T1", "T2", "T3", "N", "S"] {
            let smallSizes = try sizes(small, task: task)
            let largeSizes = try sizes(large, task: task)
            XCTAssertLessThanOrEqual(largeSizes.count, 4, task)
            XCTAssertLessThanOrEqual(largeSizes.reduce(0, +), 2 * smallSizes.reduce(0, +), task)
            XCTAssertLessThanOrEqual(largeSizes.reduce(0, +), full / 4, task)
        }
    }
}
