import Foundation
import XCTest
import HamiiCore
import HamiiApplication
@testable import HamiiFormat
@testable import HamiiIndex

final class ComponentScopeParitySpikeTests: XCTestCase {
    private let commerce = EntityID("scope_commerce")
    private let checkout = EntityID("scope_checkout")
    private let product = EntityID("scope_product")
    private let account = EntityID("scope_account")

    private final class MemoryRepository: ProjectRepository {
        var document: Document
        var generation = 0

        init(_ document: Document) { self.document = document }

        func observe() throws -> ProjectObservation {
            ProjectObservation(document: document, statePrecondition: ClientPrecondition("scope-\(generation)"))
        }

        func commit(_ document: Document, expected: ProjectObservation) throws -> ProjectObservation {
            guard expected.statePrecondition == ClientPrecondition("scope-\(generation)") else {
                throw AuthoringError.staleState
            }
            self.document = document
            generation += 1
            return try observe()
        }
    }

    private func scopes(in document: Document) -> [ArchitectureScope] {
        let app = document.scopes[0].id
        return [
            ArchitectureScope(id: commerce, name: "Commerce", parentID: app),
            ArchitectureScope(id: checkout, name: "Checkout", parentID: commerce),
            ArchitectureScope(id: product, name: "Product", parentID: commerce),
            ArchitectureScope(id: account, name: "Account", parentID: app)
        ]
    }

    private func screen(for scope: EntityID) -> Screen {
        Screen(id: EntityID("screen_\(scope.rawValue)"), name: scope.rawValue, scopeID: scope,
               root: Layer(id: EntityID("root_\(scope.rawValue)"), name: "Root", payload: .stack))
    }

    private func matrixDocument() -> Document {
        var document = Document(name: "Scope matrix")
        document.scopes += scopes(in: document)
        var inner = ComponentDefinition(id: EntityID("component_inner"), name: "Inner", ownerScopeID: commerce,
            root: Layer(id: EntityID("inner_root"), name: "Inner root", payload: .stack))
        inner.availability.allowOnlyScopeIDs = [commerce, product]
        let nested = Layer(id: EntityID("nested_inner"), name: "Nested", payload: .componentInstance(
            ComponentInstanceLayerPayload(instance: ComponentInstance(definitionID: inner.id))))
        let outer = ComponentDefinition(id: EntityID("component_outer"), name: "Outer", ownerScopeID: commerce,
            root: Layer(id: EntityID("outer_root"), name: "Outer root", payload: .stack, children: [nested]))
        var shared = ComponentDefinition(id: EntityID("component_shared"), name: "Shared", ownerScopeID: document.scopes[0].id,
            root: Layer(id: EntityID("shared_root"), name: "Shared root", payload: .stack))
        shared.availability.denyScopeIDs = [account]
        let productOnly = ComponentDefinition(id: EntityID("component_product"), name: "ProductOnly", ownerScopeID: product,
            root: Layer(id: EntityID("product_root"), name: "Product root", payload: .stack))
        document.components = [inner, outer, shared, productOnly]
        document.screens = [commerce, checkout, product, account].map(screen(for:))
        return document
    }

    private func seed(_ document: Document) throws -> (URL, CanonicalRepository, Document) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scope-parity-\(UUID().uuidString)")
        let repository = CanonicalRepository(root: root)
        let created = try repository.create(name: document.name)
        var seeded = document
        seeded.id = created.id
        seeded.revision = created.revision + 1
        try repository.save(seeded, expected: created)
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", root.path, "init", "-q"]
        try git.run()
        git.waitUntilExit()
        XCTAssertEqual(git.terminationStatus, 0)
        return (root, repository, seeded)
    }

    private func index(_ repository: CanonicalRepository, root: URL, document: Document) throws -> (LocalIndex, CanonicalSnapshotIdentity, URL) {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("scope-index-\(UUID().uuidString)")
        let index = try LocalIndex(projectRoot: root, documentID: document.id,
            revisionCalculator: GitCanonicalRevisionCalculator(), storageRoot: storage)
        let snapshot = try repository.withCoordinatedSnapshot { $0 }
        let revision = try GitCanonicalRevisionCalculator().current(at: root)
        try index.rebuild(from: snapshot, canonicalRevision: revision)
        return (index, snapshot.identity, storage)
    }

    private func assertMutation(_ document: Document, screen: Screen, definition: ComponentDefinition,
                                expectedReason: String?) throws {
        for author in [Author.human, .agent] {
            let memory = MemoryRepository(document)
            let service = ProjectService(repository: memory)
            let state = try service.observe().statePrecondition
            let intent = AuthoringIntent.instantiate(screenID: screen.id, parentID: screen.root.id, definitionID: definition.id)
            if let expectedReason {
                XCTAssertThrowsError(try service.mutate(intent, expectedState: state, author: author,
                    agent: AgentHarness(profileName: "scope-spike"))) { error in
                    guard case AuthoringError.validation(let diagnostics) = error else {
                        return XCTFail("\(author): \(error)")
                    }
                    XCTAssertTrue(diagnostics.contains { $0.rule == expectedReason }, "\(author): \(diagnostics)")
                }
                XCTAssertEqual(memory.document, document)
            } else {
                _ = try service.mutate(intent, expectedState: state, author: author,
                    agent: AgentHarness(profileName: "scope-spike"))
                XCTAssertEqual(memory.document.revision, document.revision + 1)
            }
        }
    }

    func testAllowOnlyCandidatesAndAllConsumerPathsAgreeWithCurrentEvaluator() throws {
        let document = matrixDocument()
        XCTAssertEqual(DocumentValidator.validate(document), [])
        let (root, repository, saved) = try seed(document)
        defer { try? FileManager.default.removeItem(at: root) }
        let (localIndex, sourceIdentity, indexRoot) = try index(repository, root: root, document: saved)
        defer { try? FileManager.default.removeItem(at: indexRoot) }
        let service = ProjectService(repository: repository)
        let context = ProjectContextService(repository: repository)
        let evaluator = ScopeEvaluator(saved.scopes)
        let definitions = Dictionary(uniqueKeysWithValues: saved.components.map { ($0.id, $0) })
        let expanded = saved.components.map { definition -> ComponentDefinition in
            var candidate = definition
            if !definition.availability.allowOnlyScopeIDs.isEmpty {
                candidate.availability.allowOnlyScopeIDs = saved.scopes.compactMap { scope in
                    definition.availability.allowOnlyScopeIDs.contains(where: {
                        evaluator.canUse(owner: $0, consumer: scope.id)
                    }) ? scope.id : nil
                }
            }
            return candidate
        }
        let descendantDefinitions = Dictionary(uniqueKeysWithValues: expanded.map { ($0.id, $0) })
        let expected: [EntityID: Set<EntityID>] = [
            commerce: [EntityID("component_inner"), EntityID("component_outer"), EntityID("component_shared")],
            checkout: [EntityID("component_shared")],
            product: [EntityID("component_inner"), EntityID("component_outer"), EntityID("component_shared"), EntityID("component_product")],
            account: []
        ]
        var differences: [(EntityID, EntityID)] = []
        for consumer in [commerce, checkout, product, account] {
            let exact = Set(saved.components.compactMap { definition in
                ComponentAvailability.reason(definition, consumer: consumer, scopes: evaluator, definitions: definitions) == nil
                    ? definition.id : nil
            })
            XCTAssertEqual(exact, expected[consumer])
            XCTAssertEqual(Set(try service.availableComponents(for: consumer).map(\.id)), exact)
            let state = try service.observe().statePrecondition
            let ai = try context.resources(consumerScopeID: consumer, kind: .component,
                expectedState: state).payload.items
            XCTAssertEqual(Set(ai.map(\.id)), exact)
            let hits = try localIndex.components(matching: "", consumerScopeID: consumer,
                documentID: saved.id, revision: saved.revision, expectedSourceIdentity: sourceIdentity)
            XCTAssertEqual(Set(hits.map(\.id)), exact)
            let screen = try XCTUnwrap(saved.screens.first { $0.scopeID == consumer })
            for definition in saved.components {
                let currentReason = ComponentAvailability.reason(definition, consumer: consumer,
                    scopes: evaluator, definitions: definitions)
                let descendantReason = ComponentAvailability.reason(descendantDefinitions[definition.id]!,
                    consumer: consumer, scopes: evaluator, definitions: descendantDefinitions)
                if (currentReason == nil) != (descendantReason == nil) { differences.append((consumer, definition.id)) }
                try assertMutation(saved, screen: screen, definition: definition, expectedReason: currentReason)
                print("SCOPE_MATRIX consumer=\(consumer.rawValue) component=\(definition.id.rawValue) exact=\(currentReason ?? "allow") descendant=\(descendantReason ?? "allow")")
            }
        }
        XCTAssertEqual(Set(differences.map { "\($0.0.rawValue):\($0.1.rawValue)" }), [
            "scope_checkout:component_inner", "scope_checkout:component_outer"
        ])
    }

    func testUnsafePromotionRejectsWithoutChangingCanonicalAndSafePromotionReindexes() throws {
        func base(innerOwner: EntityID) -> Document {
            var document = Document(name: "Promotion")
            document.scopes += scopes(in: document)
            let inner = ComponentDefinition(id: EntityID("component_inner"), name: "Inner", ownerScopeID: innerOwner,
                root: Layer(id: EntityID("inner_root"), name: "Inner root", payload: .stack))
            let nested = Layer(id: EntityID("nested_inner"), name: "Nested", payload: .componentInstance(
                ComponentInstanceLayerPayload(instance: ComponentInstance(definitionID: inner.id))))
            let outer = ComponentDefinition(id: EntityID("component_outer"), name: "Outer", ownerScopeID: checkout,
                root: Layer(id: EntityID("outer_root"), name: "Outer root", payload: .stack, children: [nested]))
            document.components = [inner, outer]
            document.screens = [commerce, checkout, product, account].map(screen(for:))
            return document
        }

        let (unsafeRoot, unsafeRepo, _) = try seed(base(innerOwner: checkout))
        defer { try? FileManager.default.removeItem(at: unsafeRoot) }
        let unsafeService = ProjectService(repository: unsafeRepo)
        let unsafeBefore = try unsafeService.observe()
        let unsafeSnapshot = try unsafeRepo.withCoordinatedSnapshot { $0.identity }
        let promote = AuthoringIntent.promoteComponent(definitionID: EntityID("component_outer"), newOwnerID: commerce)
        XCTAssertThrowsError(try unsafeService.mutate(promote, expectedState: unsafeBefore.statePrecondition,
            author: .human)) { error in
            guard case AuthoringError.validation(let diagnostics) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(diagnostics.contains { $0.rule == "scope.notAncestor" })
        }
        let unsafeAfter = try unsafeService.observe()
        XCTAssertEqual(unsafeAfter.document, unsafeBefore.document)
        XCTAssertEqual(unsafeAfter.document.revision, unsafeBefore.document.revision)
        XCTAssertEqual(unsafeAfter.statePrecondition, unsafeBefore.statePrecondition)
        XCTAssertEqual(try unsafeRepo.withCoordinatedSnapshot { $0.identity }, unsafeSnapshot)
        XCTAssertThrowsError(try unsafeService.mutate(promote, expectedState: unsafeBefore.statePrecondition,
            author: .agent, agent: AgentHarness(profileName: "denied"))) { error in
            guard case AuthoringError.approvalRequired = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try unsafeService.mutate(promote, expectedState: unsafeBefore.statePrecondition,
            author: .agent, agent: AgentHarness(profileName: "approved", mayPromoteScope: true))) { error in
            guard case AuthoringError.validation(let diagnostics) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(diagnostics.contains { $0.rule == "scope.notAncestor" })
        }

        let (safeRoot, safeRepo, safe) = try seed(base(innerOwner: commerce))
        defer { try? FileManager.default.removeItem(at: safeRoot) }
        let safeService = ProjectService(repository: safeRepo)
        let (oldIndex, oldIdentity, oldIndexRoot) = try index(safeRepo, root: safeRoot, document: safe)
        defer { try? FileManager.default.removeItem(at: oldIndexRoot) }
        XCTAssertFalse(try safeService.availableComponents(for: commerce).contains { $0.id == EntityID("component_outer") })
        XCTAssertTrue(try safeService.availableComponents(for: checkout).contains { $0.id == EntityID("component_outer") })
        XCTAssertFalse(try oldIndex.components(matching: "Outer", consumerScopeID: commerce,
            documentID: safe.id, revision: safe.revision, expectedSourceIdentity: oldIdentity).contains {
            $0.id == EntityID("component_outer")
        })
        let oldState = try safeService.observe().statePrecondition
        XCTAssertEqual(try safeService.promotionCandidate(for: [checkout, product]), commerce)
        XCTAssertThrowsError(try safeService.mutate(promote, expectedState: oldState, author: .agent,
            agent: AgentHarness(profileName: "denied"))) { error in
            guard case AuthoringError.approvalRequired = error else { return XCTFail("\(error)") }
        }
        let human = try MutationEngine.apply(promote, to: safe, expectedRevision: safe.revision, author: .human)
        let approved = try MutationEngine.apply(promote, to: safe, expectedRevision: safe.revision,
            author: .agent, agent: AgentHarness(profileName: "approved", mayPromoteScope: true))
        XCTAssertEqual(human.0, approved.0)
        _ = try safeService.mutate(promote, expectedState: oldState, author: .agent,
            agent: AgentHarness(profileName: "approved", mayPromoteScope: true))
        let published = try safeService.observe()
        XCTAssertEqual(published.document.components.first { $0.id == EntityID("component_outer") }?.ownerScopeID, commerce)
        XCTAssertNotEqual(published.statePrecondition, oldState)
        XCTAssertThrowsError(try oldIndex.components(matching: "Outer", consumerScopeID: checkout,
            documentID: safe.id, revision: safe.revision, expectedSourceIdentity: oldIdentity))
        let (freshIndex, freshIdentity, freshIndexRoot) = try index(safeRepo, root: safeRoot, document: published.document)
        defer { try? FileManager.default.removeItem(at: freshIndexRoot) }
        let context = ProjectContextService(repository: safeRepo)
        for consumer in [commerce, checkout, product, account] {
            let picker = Set(try safeService.availableComponents(for: consumer).map(\.id))
            let ai = Set(try context.resources(consumerScopeID: consumer, kind: .component,
                expectedState: published.statePrecondition).payload.items.map(\.id))
            let indexed = Set(try freshIndex.components(matching: "", consumerScopeID: consumer,
                documentID: published.document.id, revision: published.document.revision,
                expectedSourceIdentity: freshIdentity).map(\.id))
            XCTAssertEqual(picker, ai)
            XCTAssertEqual(picker, indexed)
            let expectedOuter = consumer != account
            XCTAssertEqual(picker.contains(EntityID("component_outer")), expectedOuter)
            let outer = try XCTUnwrap(published.document.components.first { $0.id == EntityID("component_outer") })
            let reason = ComponentAvailability.reason(outer, consumer: consumer,
                scopes: ScopeEvaluator(published.document.scopes),
                definitions: Dictionary(uniqueKeysWithValues: published.document.components.map { ($0.id, $0) }))
            XCTAssertEqual(reason == nil, expectedOuter)
            let screen = try XCTUnwrap(published.document.screens.first { $0.scopeID == consumer })
            try assertMutation(published.document, screen: screen, definition: outer, expectedReason: reason)
        }
    }

    func testAvailabilityAndProjectionLatencySamples() {
        func samples(_ document: Document) -> (Double, Double, Double, Double) {
            let evaluator = ScopeEvaluator(document.scopes)
            let definitions = Dictionary(uniqueKeysWithValues: document.components.map { ($0.id, $0) })
            var availability: [Double] = []
            var projection: [Double] = []
            for _ in 0..<30 {
                let start = DispatchTime.now().uptimeNanoseconds
                for component in document.components {
                    _ = ComponentAvailability.reason(component, consumer: checkout,
                        scopes: evaluator, definitions: definitions)
                }
                let middle = DispatchTime.now().uptimeNanoseconds
                _ = IndexProjection(document: document)
                let end = DispatchTime.now().uptimeNanoseconds
                availability.append(Double(middle - start) / 1_000_000)
                projection.append(Double(end - middle) / 1_000_000)
            }
            func percentile(_ values: [Double], _ fraction: Double) -> Double {
                let sorted = values.sorted()
                return sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)]
            }
            return (percentile(availability, 0.5), percentile(availability, 0.95),
                    percentile(projection, 0.5), percentile(projection, 0.95))
        }
        let small = matrixDocument()
        var large = small
        for number in 0..<996 {
            large.components.append(ComponentDefinition(id: EntityID("component_extra_\(number)"),
                name: "Extra \(number)", ownerScopeID: commerce,
                root: Layer(id: EntityID("extra_root_\(number)"), name: "Root", payload: .stack)))
        }
        for (label, document) in [("small", small), ("1000", large)] {
            let result = samples(document)
            print("SCOPE_LATENCY fixture=\(label) components=\(document.components.count) " +
                "availabilityP50Ms=\(result.0) availabilityP95Ms=\(result.1) " +
                "projectionP50Ms=\(result.2) projectionP95Ms=\(result.3) runs=30")
        }
    }
}
