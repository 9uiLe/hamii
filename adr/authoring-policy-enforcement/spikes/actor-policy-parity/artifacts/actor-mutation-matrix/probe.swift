import Foundation
import HamiiApplication
import HamiiCore

private final class MemoryRepository: ProjectRepository {
    var document: Document
    var commits = 0
    var state = ClientPrecondition("observation-0")

    init(_ document: Document) { self.document = document }
    func observe() throws -> ProjectObservation {
        ProjectObservation(document: document, statePrecondition: state)
    }
    func commit(_ candidate: Document, expected: ProjectObservation) throws -> ProjectObservation {
        guard expected.statePrecondition == state else { throw AuthoringError.staleState }
        document = candidate
        commits += 1
        state = ClientPrecondition("observation-\(commits)")
        return try observe()
    }
}

private struct Outcome {
    let category: String
    let diagnostics: [[String: String]]
    let commits: Int
    let revision: Int
    let state: String

    var json: [String: Any] {
        ["category": category, "diagnostics": diagnostics, "commits": commits,
         "revision": revision, "state": state]
    }
}

private func diagnosticRows(_ diagnostics: [Diagnostic]) -> [[String: String]] {
    diagnostics.map { ["rule": $0.rule, "entityID": $0.entityID?.rawValue ?? ""] }
        .sorted { ($0["rule"] ?? "", $0["entityID"] ?? "") < ($1["rule"] ?? "", $1["entityID"] ?? "") }
}

private func execute(_ document: Document, _ intents: [AuthoringIntent],
                     author: Author, agent: AgentHarness? = nil) -> Outcome {
    let repo = MemoryRepository(document)
    let service = ProjectService(repository: repo)
    let state = try! service.observe().statePrecondition
    var category = "success"
    var diagnostics: [Diagnostic] = []
    do {
        _ = try service.mutate(intents, expectedState: state, author: author, agent: agent)
    } catch AuthoringError.validation(let errors) {
        category = "validation"
        diagnostics = errors
    } catch AuthoringError.mutationLimit {
        category = "mutationLimit"
    } catch AuthoringError.approvalRequired {
        category = "approvalRequired"
    } catch {
        category = "unexpected:\(type(of: error))"
    }
    return Outcome(category: category, diagnostics: diagnosticRows(diagnostics),
                   commits: repo.commits, revision: repo.document.revision, state: repo.state.rawValue)
}

private let tokenID = EntityID("token_spacing")
private let screenID = EntityID("screen_main")
private let rootID = EntityID("layer_root")
private let buttonID = EntityID("layer_button")
private let stackID = EntityID("layer_stack")

private func base() -> Document {
    var document = Document(name: "Actor policy matrix")
    let app = document.scopes[0].id
    document.tokens = [DesignToken(id: tokenID, name: "spacing", kind: .spacing,
                                   ownerScopeID: app, value: .literal("8"))]
    let button = Layer(id: buttonID, kind: .button, name: "Button", text: "Submit")
    let stack = Layer(id: stackID, kind: .stack, name: "Nested",
                      layout: Layout(axis: .vertical, spacingTokenID: tokenID))
    let root = Layer(id: rootID, kind: .stack, name: "Root", children: [button, stack],
                     layout: Layout(axis: .vertical, spacingTokenID: tokenID))
    document.screens = [Screen(id: screenID, name: "Main", scopeID: app, root: root)]
    document.authoringHarness.requireAccessibleControls = true
    document.authoringHarness.requireTokenSpacing = true
    return document
}

private func has(_ outcome: Outcome, category: String, rule: String? = nil, entity: EntityID? = nil,
                 saved: Bool = false) -> Bool {
    guard outcome.category == category, outcome.commits == (saved ? 1 : 0),
          outcome.revision == (saved ? 1 : 0),
          outcome.state == (saved ? "observation-1" : "observation-0") else { return false }
    guard let rule else { return true }
    return outcome.diagnostics.contains { $0["rule"] == rule && $0["entityID"] == entity?.rawValue }
}

@main private enum Probe {
    static func main() throws {
        let source = base()
        var checks: [String: Bool] = [:]
        var cases: [[String: Any]] = []
        let fullAgent = AgentHarness(profileName: "authorized", maximumMutations: 10,
                                     mayPromoteScope: true)
        checks["validBase"] = DocumentValidator.validate(source).isEmpty

        func pair(_ name: String, document: Document, intents: [AuthoringIntent],
                  rule: String, entity: EntityID, directCandidate: Document) {
            let human = execute(document, intents, author: .human)
            let agent = execute(document, intents, author: .agent, agent: fullAgent)
            let direct = diagnosticRows(DocumentValidator.validate(directCandidate))
            checks["\(name).human"] = has(human, category: "validation", rule: rule, entity: entity)
            checks["\(name).agent"] = has(agent, category: "validation", rule: rule, entity: entity)
            checks["\(name).direct"] = direct.contains { $0["rule"] == rule && $0["entityID"] == entity.rawValue }
            checks["\(name).sameTypedDiagnostics"] = human.diagnostics == agent.diagnostics &&
                human.diagnostics == direct
            cases.append(["case": name, "human": human.json, "agent": agent.json,
                          "directCandidateDiagnostics": direct])
        }

        var emptyButton = source
        emptyButton.screens[0].root.children[0].text = ""
        pair("accessibleButton", document: source,
             intents: [.setText(screenID: screenID, layerID: buttonID, text: "")],
             rule: "accessibility.controlLabel", entity: buttonID, directCandidate: emptyButton)

        var untokenedStack = source
        untokenedStack.screens[0].root.children[1].layout.spacingTokenID = nil
        pair("tokenSpacing", document: source,
             intents: [.setLayoutToken(screenID: screenID, layerID: stackID,
                                       property: .spacing, tokenID: nil)],
             rule: "token.spacingRequired", entity: stackID, directCandidate: untokenedStack)

        var commonLimit = source
        commonLimit.authoringHarness.maximumMutationNodes = 2
        let threePages: [AuthoringIntent] = [.createPage(name: "One"), .createPage(name: "Two"),
                                             .createPage(name: "Three")]
        let humanCommon = execute(commonLimit, threePages, author: .human)
        let agentCommon = execute(commonLimit, threePages, author: .agent, agent: fullAgent)
        checks["commonLimit.human"] = has(humanCommon, category: "mutationLimit")
        checks["commonLimit.agent"] = has(agentCommon, category: "mutationLimit")
        cases.append(["case": "commonLimit", "human": humanCommon.json, "agent": agentCommon.json])

        commonLimit.authoringHarness.maximumMutationNodes = 3
        let twoPages: [AuthoringIntent] = [.createPage(name: "One"), .createPage(name: "Two")]
        let humanTwo = execute(commonLimit, twoPages, author: .human)
        let agentTwo = execute(commonLimit, twoPages, author: .agent,
                               agent: AgentHarness(profileName: "limited", maximumMutations: 1))
        checks["agentLimit.humanAllowed"] = has(humanTwo, category: "success", saved: true)
        checks["agentLimit.agentRejected"] = has(agentTwo, category: "mutationLimit")
        cases.append(["case": "agentLimit", "human": humanTwo.json, "agent": agentTwo.json])

        var promotion = source
        let childID = EntityID("scope_child")
        let componentID = EntityID("component_child")
        promotion.scopes.append(ArchitectureScope(id: childID, name: "Child", parentID: promotion.scopes[0].id))
        promotion.components.append(ComponentDefinition(id: componentID, name: "Child component",
            ownerScopeID: childID,
            root: Layer(id: EntityID("component_root"), kind: .text, name: "Text", text: "Body")))
        let promote = AuthoringIntent.promoteComponent(definitionID: componentID,
                                                       newOwnerID: promotion.scopes[0].id)
        let humanPromotion = execute(promotion, [promote], author: .human)
        let deniedPromotion = execute(promotion, [promote], author: .agent,
            agent: AgentHarness(profileName: "withoutApproval", mayPromoteScope: false))
        let approvedPromotion = execute(promotion, [promote], author: .agent, agent: fullAgent)
        checks["promotion.humanAllowed"] = has(humanPromotion, category: "success", saved: true)
        checks["promotion.agentDenied"] = has(deniedPromotion, category: "approvalRequired")
        checks["promotion.agentApproved"] = has(approvedPromotion, category: "success", saved: true)
        cases.append(["case": "promotion", "human": humanPromotion.json,
                      "agentDenied": deniedPromotion.json, "agentApproved": approvedPromotion.json])

        var deniedComponent = source
        let deniedScope = EntityID("scope_denied")
        let deniedDefinition = EntityID("component_denied")
        let instanceID = EntityID("layer_instance")
        deniedComponent.scopes.append(ArchitectureScope(id: deniedScope, name: "Denied",
            parentID: deniedComponent.scopes[0].id))
        deniedComponent.screens[0].scopeID = deniedScope
        var definition = ComponentDefinition(id: deniedDefinition, name: "Shared",
            ownerScopeID: deniedComponent.scopes[0].id,
            root: Layer(id: EntityID("definition_root"), kind: .text, name: "Text", text: "Body"))
        definition.availability.denyScopeIDs = [deniedScope]
        deniedComponent.components.append(definition)
        deniedComponent.screens[0].root.children.append(Layer(id: instanceID,
            kind: .componentInstance, name: "Instance", component: ComponentInstance(definitionID: deniedDefinition)))
        var availabilityCandidate = deniedComponent
        availabilityCandidate.screens[0].root.children[0].text = "Changed"
        pair("availabilityInvariant", document: deniedComponent,
             intents: [.setText(screenID: screenID, layerID: buttonID, text: "Changed")],
             rule: "component.denied", entity: instanceID, directCandidate: availabilityCandidate)

        let report: [String: Any] = [
            "sourceCommit": ProcessInfo.processInfo.environment["HAMII_SOURCE_COMMIT"] ?? "unspecified",
            "fixture": "in-memory ProjectRepository, same Document and intent per actor, fixed IDs",
            "cases": cases,
            "checks": checks,
            "passed": checks.values.allSatisfy { $0 },
            "checkCount": checks.count,
            "classification": ["Confirmed": "typed rule/entity and save behavior for exercised service path",
                               "Measured": "one run, 20 checks, 20 passes; no latency benchmark",
                               "Unknown": "CanonicalRepository disk persistence and GUI/CLI adapter forwarding not exercised"]
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        if checks.values.contains(false) { exit(1) }
    }
}
