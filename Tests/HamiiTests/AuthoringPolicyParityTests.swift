import Foundation
import XCTest
import HamiiApplication
import HamiiCore

final class AuthoringPolicyParityTests: XCTestCase {
    private final class MemoryRepository: ProjectRepository {
        var document: Document
        var commits = 0
        var state = ClientPrecondition("policy-observation-0")

        init(_ document: Document) { self.document = document }

        func observe() throws -> ProjectObservation {
            ProjectObservation(document: document, statePrecondition: state)
        }

        func commit(_ candidate: Document, expected: ProjectObservation) throws -> ProjectObservation {
            guard expected.statePrecondition == state else { throw AuthoringError.staleState }
            document = candidate
            commits += 1
            state = ClientPrecondition("policy-observation-\(commits)")
            return try observe()
        }
    }

    private let screenID = EntityID("screen_policy")
    private let buttonID = EntityID("layer_button")
    private let stackID = EntityID("layer_stack")
    private let spacingID = EntityID("token_spacing")
    private let authorizedAgent = AgentHarness(profileName: "authorized", maximumMutations: 10,
                                               mayPromoteScope: true)

    private func fixture() -> Document {
        var document = Document(name: "Policy parity")
        let app = document.scopes[0].id
        document.tokens = [DesignToken(id: spacingID, name: "spacing", kind: .spacing,
                                       ownerScopeID: app, value: .literal("8"))]
        let button = Layer(id: buttonID, kind: .button, name: "Button", text: "Submit")
        let stack = Layer(id: stackID, kind: .stack, name: "Nested",
                          layout: Layout(axis: .vertical, spacingTokenID: spacingID))
        let root = Layer(id: EntityID("layer_root"), kind: .stack, name: "Root",
                         children: [button, stack],
                         layout: Layout(axis: .vertical, spacingTokenID: spacingID))
        document.screens = [Screen(id: screenID, name: "Main", scopeID: app, root: root)]
        document.authoringHarness.requireAccessibleControls = true
        document.authoringHarness.requireTokenSpacing = true
        return document
    }

    private func assertRejectedWithoutCommit(_ intent: AuthoringIntent,
                                             from original: Document,
                                             directCandidate: Document,
                                             rule: String,
                                             entityID: EntityID,
                                             file: StaticString = #filePath,
                                             line: UInt = #line) throws {
        XCTAssertTrue(DocumentValidator.validate(original).isEmpty, file: file, line: line)
        let direct = DocumentValidator.validate(directCandidate)
        XCTAssertEqual(direct.count, 1, file: file, line: line)
        XCTAssertEqual(direct.first?.rule, rule, file: file, line: line)
        XCTAssertEqual(direct.first?.entityID, entityID, file: file, line: line)

        for author in [Author.human, .agent] {
            let repository = MemoryRepository(original)
            let service = ProjectService(repository: repository)
            let observed = try service.observe()
            XCTAssertThrowsError(try service.mutate(intent, expectedState: observed.statePrecondition,
                author: author, agent: author == .agent ? authorizedAgent : nil), file: file, line: line) { error in
                guard case AuthoringError.validation(let diagnostics) = error else {
                    return XCTFail("Expected candidate validation for \(author): \(error)", file: file, line: line)
                }
                XCTAssertEqual(diagnostics.count, 1, file: file, line: line)
                XCTAssertEqual(diagnostics.first?.rule, rule, file: file, line: line)
                XCTAssertEqual(diagnostics.first?.entityID, entityID, file: file, line: line)
                XCTAssertEqual(diagnostics.first?.severity, direct.first?.severity, file: file, line: line)
            }
            XCTAssertEqual(repository.commits, 0, file: file, line: line)
            XCTAssertEqual(repository.document, original, file: file, line: line)
            XCTAssertEqual(repository.document.revision, observed.document.revision, file: file, line: line)
            XCTAssertEqual(try service.observe().statePrecondition, observed.statePrecondition,
                           file: file, line: line)
        }
    }

    func testAccessibleControlRuleHasSameTypedCandidateResultForHumanAndAgent() throws {
        let original = fixture()
        var candidate = original
        candidate.screens[0].root.children[0].text = ""
        try assertRejectedWithoutCommit(.setText(screenID: screenID, layerID: buttonID, text: ""),
                                        from: original, directCandidate: candidate,
                                        rule: "accessibility.controlLabel", entityID: buttonID)
    }

    func testTokenSpacingRuleHasSameTypedCandidateResultForHumanAndAgent() throws {
        let original = fixture()
        var candidate = original
        candidate.screens[0].root.children[1].layout.spacingTokenID = nil
        try assertRejectedWithoutCommit(.setLayoutToken(screenID: screenID, layerID: stackID,
                                                        property: .spacing, tokenID: nil),
                                        from: original, directCandidate: candidate,
                                        rule: "token.spacingRequired", entityID: stackID)
    }

    func testProductMutationLimitAppliesToBothActorsAndAgentLimitCanBeStricter() throws {
        var document = fixture()
        document.authoringHarness.maximumMutationNodes = 2
        XCTAssertTrue(DocumentValidator.validate(document).isEmpty)
        let threePages: [AuthoringIntent] = [.createPage(name: "One"), .createPage(name: "Two"),
                                             .createPage(name: "Three")]
        for author in [Author.human, .agent] {
            let repository = MemoryRepository(document)
            let service = ProjectService(repository: repository)
            let state = try service.observe().statePrecondition
            XCTAssertThrowsError(try service.mutate(threePages, expectedState: state,
                author: author, agent: author == .agent ? authorizedAgent : nil)) { error in
                guard case AuthoringError.mutationLimit = error else {
                    return XCTFail("Expected common mutation limit: \(error)")
                }
            }
            XCTAssertEqual(repository.commits, 0)
            XCTAssertEqual(repository.document, document)
            XCTAssertEqual(repository.document.revision, 0)
            XCTAssertEqual(repository.state, state)
        }

        document.authoringHarness.maximumMutationNodes = 3
        let twoPages: [AuthoringIntent] = [.createPage(name: "One"), .createPage(name: "Two")]
        let humanRepository = MemoryRepository(document)
        let human = ProjectService(repository: humanRepository)
        _ = try human.mutate(twoPages, expectedState: human.observe().statePrecondition, author: .human)
        XCTAssertEqual(humanRepository.commits, 1)
        XCTAssertEqual(humanRepository.document.revision, 1)
        XCTAssertEqual(humanRepository.document.pages.count, 2)

        let agentRepository = MemoryRepository(document)
        let agent = ProjectService(repository: agentRepository)
        let state = try agent.observe().statePrecondition
        XCTAssertThrowsError(try agent.mutate(twoPages, expectedState: state, author: .agent,
            agent: AgentHarness(profileName: "limited", maximumMutations: 1))) { error in
            guard case AuthoringError.mutationLimit = error else {
                return XCTFail("Expected Agent Harness limit: \(error)")
            }
        }
        XCTAssertEqual(agentRepository.commits, 0)
        XCTAssertEqual(agentRepository.document, document)
        XCTAssertEqual(agentRepository.state, state)
    }

    func testScopePromotionApprovalRemainsAnActorPermission() throws {
        var document = fixture()
        let app = document.scopes[0].id
        let child = EntityID("scope_child")
        let componentID = EntityID("component_child")
        document.scopes.append(ArchitectureScope(id: child, name: "Child", parentID: app))
        document.components.append(ComponentDefinition(id: componentID, name: "Child component",
            ownerScopeID: child,
            root: Layer(id: EntityID("component_root"), kind: .text, name: "Text", text: "Body")))
        XCTAssertTrue(DocumentValidator.validate(document).isEmpty)
        let intent = AuthoringIntent.promoteComponent(definitionID: componentID, newOwnerID: app)

        let deniedRepository = MemoryRepository(document)
        let denied = ProjectService(repository: deniedRepository)
        let deniedState = try denied.observe().statePrecondition
        XCTAssertThrowsError(try denied.mutate(intent, expectedState: deniedState, author: .agent,
            agent: AgentHarness(profileName: "withoutApproval", mayPromoteScope: false))) { error in
            guard case AuthoringError.approvalRequired = error else {
                return XCTFail("Expected Agent approval requirement: \(error)")
            }
        }
        XCTAssertEqual(deniedRepository.commits, 0)
        XCTAssertEqual(deniedRepository.document, document)
        XCTAssertEqual(deniedRepository.state, deniedState)

        for author in [Author.human, .agent] {
            let repository = MemoryRepository(document)
            let service = ProjectService(repository: repository)
            let state = try service.observe().statePrecondition
            _ = try service.mutate(intent, expectedState: state, author: author,
                                   agent: author == .agent ? authorizedAgent : nil)
            XCTAssertEqual(repository.commits, 1)
            XCTAssertEqual(repository.document.revision, 1)
            XCTAssertEqual(repository.document.components[0].ownerScopeID, app)
            XCTAssertTrue(DocumentValidator.validate(repository.document).isEmpty)
        }
    }
}
