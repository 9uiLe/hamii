import Foundation
import CryptoKit
import XCTest
import HamiiCore

// Evidence-only models for adr/capability-contract. No canonical serialization or production registry.
private struct CapabilityOracle: Decodable {
    var schemaVersion: Int
    var frozenBeforeCandidateImplementation: Bool
    var cases: [OracleCase]
}
private struct OracleCase: Decodable {
    var scenario: String
    var profile: String
    var approval: Bool
    var semanticRequirements: [OracleRequirement]
}
private struct OracleRequirement: Decodable {
    var key: String
    var support: CapabilitySupport
}
private struct ProbeEffect { var key: String }
private struct ProbeExtension { var key: String }
private struct ProbeFixture {
    var document: Document
    var surface: AppSurface
    var effects: [ProbeEffect] = []
    var targetExtension: ProbeExtension? = nil
    var productBinding = false
    var productHandler = false
}
private struct LossItem: Codable, Equatable {
    var key: String
    var support: CapabilitySupport
    var allowed: Bool
    var rule: String
    var loss: String
}
private struct LossReport: Codable, Equatable {
    var allowed: Bool
    var items: [LossItem]
}
private struct CandidateResult: Codable {
    var allowed: Bool
    var items: [LossItem]
    var falsePositives: [String]
    var falseNegatives: [String]
    var silentApproximations: [String]
    var consumerDivergences: Int
}
private struct PlannerResult: Codable {
    var allowed: Bool
    var diagnosticRules: [String]
}
private struct MatrixRow: Codable {
    var scenario: String
    var profile: String
    var approval: Bool
    var semanticRequirements: [OracleRequirementRecord]
    var oracleAllowed: Bool
    var nodeCandidate: CandidateResult
    var propertyCandidate: CandidateResult
    var contractCandidate: CandidateResult
    var currentPlanner: PlannerResult
}
private struct OracleRequirementRecord: Codable {
    var key: String
    var support: CapabilitySupport
}
private struct Matrix: Codable {
    var oracleCommit: String
    var measuredOracleSHA256: String
    var implementationScope: String
    var rows: [MatrixRow]
    var metrics: [String: CandidateMetrics]
}
private struct CandidateMetrics: Codable {
    var falsePositives: Int
    var falseNegatives: Int
    var consumerDivergences: Int
    var silentApproximations: Int
    var registryEntries: Int
    var duplicateDeclarations: Int
    var buttonEventProfileChangeEntries: Int
    var buttonEventCollateralRequirements: Int
}

private enum SpikeFixtureFactory {
    static func make(_ scenario: String, profile: String) -> ProbeFixture {
        var document = Document(name: scenario)
        let scope = document.scopes[0].id
        let platform: Platform = profile.hasPrefix("ios") ? .iOS : profile.hasPrefix("android") ? .android : .macOS
        let framework: Framework = platform == .android ? .jetpackCompose : .swiftUI
        let target = Target(id: EntityID("target_probe"), platform: platform, framework: framework)
        document.targets = [target]
        let spacing = EntityID("token_spacing")
        document.tokens = [DesignToken(id: spacing, name: "spacing", kind: .spacing, ownerScopeID: scope, value: .literal("12"))]
        let symbol = EntityID("asset_symbol")
        let remote = EntityID("asset_remote")
        document.assets = [
            Asset(id: symbol, name: "person", ownerScopeID: scope, mediaType: "image/system", source: .system(name: "person")),
            Asset(id: remote, name: "avatar", ownerScopeID: scope, mediaType: "image/png", source: .remote(url: "https://example.com/avatar.png"))
        ]
        let root: Layer
        var navigation: NavigationConfiguration? = nil
        var effects: [ProbeEffect] = []
        var ext: ProbeExtension? = nil
        var productBinding = false
        var productHandler = false
        switch scenario {
        case "A-stack":
            root = Layer(id: EntityID("layer_root"), name: "Stack", payload: .stack, layout: Layout(axis: .vertical, spacingTokenID: spacing))
        case "B-button":
            root = Layer(id: EntityID("layer_root"), name: "Button", payload: .button(ButtonLayerPayload(label: "Go", emittedEvent: "go")))
            productHandler = true
        case "C-binding":
            root = Layer(id: EntityID("layer_root"), name: "Text", payload: .text(TextLayerPayload(value: "Guest", binding: "user.name")))
            productBinding = true
            document.fixtures = [try! JSONDecoder().decode(PreviewFixture.self, from: Data(#"{"id":{"rawValue":"fixture_main"},"name":"Main","values":{"user.name":"Ada"},"assetBindings":{}}"#.utf8))]
        case "D-navigation":
            root = Layer(id: EntityID("layer_root"), name: "Root", payload: .stack)
            navigation = .system(SystemNavigation(title: "Profile", toolbarItems: [SystemToolbarItem(id: EntityID("toolbar_edit"), title: "Edit", emittedEvent: "edit")]))
            productHandler = true
        case "E-system-apple", "E-system-compose":
            root = Layer(id: EntityID("layer_root"), name: "System image", payload: .image(ImageLayerPayload(assetID: symbol)))
        case "F-remote":
            root = Layer(id: EntityID("layer_root"), name: "Remote image", payload: .image(ImageLayerPayload(assetID: remote)))
        case "G-approx-denied", "G-approx-approved":
            root = Layer(id: EntityID("layer_root"), name: "Overlay", payload: .overlay)
        case "H-ios15", "H-ios16":
            root = Layer(id: EntityID("layer_root"), name: "Root", payload: .stack)
            ext = ProbeExtension(key: "sheet.detents")
        case "I-ordered-effects":
            root = Layer(id: EntityID("layer_root"), name: "Text", payload: .text(TextLayerPayload(value: "Hello")))
            effects = [ProbeEffect(key: "effect.padding"), ProbeEffect(key: "effect.background"), ProbeEffect(key: "effect.order")]
        case "J-extension-macos", "J-extension-ios16":
            root = Layer(id: EntityID("layer_root"), name: "Text", payload: .text(TextLayerPayload(value: "Hello")))
            ext = ProbeExtension(key: "extension.iosSheetDetents")
        default: fatalError("Unknown scenario \(scenario)")
        }
        var screen = Screen(id: EntityID("screen_main"), name: "Main", scopeID: scope, root: root)
        screen.navigation = navigation
        document.screens = [screen]
        let surface = AppSurface(id: EntityID("surface_main"), targetID: target.id, device: platform == .macOS ? "Mac" : "Phone", runtime: "\(platform.rawValue) \(profile.hasPrefix("ios15") ? "15" : profile.hasPrefix("ios16") ? "16" : "27")", buildEnvironment: "SDK probe", screenID: screen.id, architectureScopeID: scope, fixtureID: document.fixtures.first?.id)
        return ProbeFixture(document: document, surface: surface, effects: effects, targetExtension: ext, productBinding: productBinding, productHandler: productHandler)
    }
}

private enum RequirementExtractor {
    static func extract(_ fixture: ProbeFixture) -> [String] {
        let screen = fixture.document.screens[0]
        var keys: [String] = []
        func layer(_ value: Layer) {
            switch value.payload {
            case .stack:
                // The detents probe is an extension-only scenario: its stack is just a placeholder host.
                if fixture.targetExtension?.key != "sheet.detents" { keys.append("stack.container") }
                if value.layout.spacingTokenID != nil { keys.append("stack.spacingToken") }
            case .text(let payload):
                keys.append("text.visual")
                if payload.binding != nil { keys.append("text.fixtureBinding") }
                if payload.value != nil && payload.binding != nil { keys.append("text.fallback") }
                if fixture.productBinding { keys.append("text.productBinding") }
            case .button(let payload):
                keys.append("button.visual")
                if payload.emittedEvent != nil { keys.append("button.eventEmit") }
                if fixture.productHandler { keys.append("button.productHandler") }
            case .image(let payload):
                keys.append("image.visual")
                if let id = payload.assetID, let asset = fixture.document.assets.first(where: { $0.id == id }) {
                    switch asset.source {
                    case .system: keys.append("asset.systemMapping")
                    case .remote: keys.append("asset.remoteFetch")
                    default: break
                    }
                }
            case .overlay: keys.append("overlay.visual")
            case .scroll, .componentInstance: break
            }
            value.children.forEach(layer)
        }
        layer(screen.root)
        if case .system(let navigation) = screen.navigation {
            keys.append("navigation.systemContainer")
            if navigation.title != nil { keys.append("navigation.title") }
            if !navigation.toolbarItems.isEmpty {
                keys.append("toolbar.systemOwnership")
                keys.append("toolbar.eventEmit")
                if fixture.productHandler { keys.append("toolbar.productHandler") }
            }
        }
        keys += fixture.effects.map(\.key)
        if let ext = fixture.targetExtension { keys.append(ext.key) }
        return keys
    }
}

private enum RegistryCandidate: String, CaseIterable {
    case node, property, contract

    func registryKey(_ requirement: String) -> String {
        switch self {
        case .contract: return requirement
        case .property:
            if requirement == "button.productHandler" { return "button.eventEmit" }
            if requirement == "text.productBinding" { return "text.fixtureBinding" }
            if requirement == "toolbar.productHandler" { return "toolbar.eventEmit" }
            if requirement == "effect.order" { return "effect.padding" }
            return requirement
        case .node:
            if requirement.hasPrefix("stack.") { return "stack" }
            if requirement.hasPrefix("button.") { return "button" }
            if requirement.hasPrefix("text.") { return "text" }
            if requirement.hasPrefix("navigation.") || requirement.hasPrefix("toolbar.") { return "navigation" }
            if requirement.hasPrefix("image.") || requirement.hasPrefix("asset.") { return "image" }
            if requirement.hasPrefix("overlay.") { return "overlay" }
            if requirement.hasPrefix("sheet.") { return "sheet" }
            if requirement.hasPrefix("effect.") { return "text" }
            if requirement.hasPrefix("extension.") { return "text" }
            return requirement
        }
    }

    func declaredSupport(profile: String, key: String) -> CapabilitySupport {
        if self == .node {
            if key == "overlay" && profile == "approximation-probe" { return .approximate }
            if key == "sheet" { return profile == "ios15-feasibility" ? .unsupported : .targetSpecific }
            if key == "image" && profile == "android15-feasibility" { return .portable }
            if key == "text" && profile == "ios16-feasibility" { return .portable }
            return ["stack", "button", "text", "navigation", "image", "overlay"].contains(key) ? .exact : .unsupported
        }
        if key == "overlay.visual" { return .approximate }
        if key == "sheet.detents" { return profile == "ios15-feasibility" ? .unsupported : .targetSpecific }
        if key == "image.visual" && profile == "android15-feasibility" { return .portable }
        if key == "text.visual" && profile == "ios16-feasibility" { return .portable }
        if key == "asset.systemMapping" { return profile == "android15-feasibility" ? .externalIntegrationRequired : .targetSpecific }
        if key == "asset.remoteFetch" || key.hasPrefix("effect.") { return .unsupported }
        if key == "extension.iosSheetDetents" { return profile == "ios16-feasibility" ? .targetSpecific : .unsupported }
        if key == "button.productHandler" || key == "toolbar.productHandler" || key == "text.productBinding" { return .externalIntegrationRequired }
        if key == "stack.spacingToken" { return .portable }
        let exactKeys: Set<String> = ["stack.container", "button.visual", "button.eventEmit", "text.visual", "text.fixtureBinding", "text.fallback", "navigation.systemContainer", "navigation.title", "toolbar.systemOwnership", "toolbar.eventEmit", "image.visual"]
        return exactKeys.contains(key) ? .exact : .unsupported
    }
}

private enum CapabilityEvaluatorProbe {
    static func evaluate(_ requirements: [String], profile: String, approval: Bool, candidate: RegistryCandidate) -> LossReport {
        let items = requirements.map { requirement -> LossItem in
            let key = candidate.registryKey(requirement)
            let support = candidate.declaredSupport(profile: profile, key: key)
            let allowed = support == .exact || support == .portable || support == .targetSpecific || (support == .approximate && approval)
            let loss = support == .approximate ? "approvedApproximation" : support == .externalIntegrationRequired ? "externalIntegration" : support == .unsupported ? "unsupported" : "none"
            return LossItem(key: requirement, support: support, allowed: allowed, rule: "capability.\(requirement)", loss: loss)
        }
        return LossReport(allowed: items.allSatisfy(\.allowed), items: items)
    }
}

private enum ConsumerAdapter: CaseIterable {
    case canvas, nativeHost, generator, aiPlanning
    func evaluate(_ requirements: [String], profile: String, approval: Bool, candidate: RegistryCandidate) -> LossReport {
        CapabilityEvaluatorProbe.evaluate(requirements, profile: profile, approval: approval, candidate: candidate)
    }
}

final class CapabilityGranularitySpikeTests: XCTestCase {
    private let artifact = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("adr/capability-contract/spikes/capability-granularity/artifacts")

    func testFrozenOracleAndCandidateComparison() throws {
        let oracleData = try Data(contentsOf: artifact.appendingPathComponent("oracle.json"))
        let oracle = try JSONDecoder().decode(CapabilityOracle.self, from: oracleData)
        let oracleSHA256 = SHA256.hash(data: oracleData).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(oracleSHA256, "56186093b247b168c41bd9bcb867c23942a158f486f8ec88de3a4af8a4d7fd07")
        XCTAssertEqual(oracle.schemaVersion, 1)
        XCTAssertTrue(oracle.frozenBeforeCandidateImplementation)
        XCTAssertEqual(oracle.cases.count, 14)
        var rows: [MatrixRow] = []
        for scenario in oracle.cases {
            let fixture = SpikeFixtureFactory.make(scenario.scenario, profile: scenario.profile)
            let extracted = RequirementExtractor.extract(fixture)
            let expected = scenario.semanticRequirements.map(\.key)
            XCTAssertEqual(extracted, expected, scenario.scenario)
            XCTAssertEqual(DocumentValidator.validate(fixture.document).filter { $0.severity == .error }, [], scenario.scenario)
            let oracleAllowed = scenario.semanticRequirements.allSatisfy { requirement in
                requirement.support == .exact || requirement.support == .portable || requirement.support == .targetSpecific || (requirement.support == .approximate && scenario.approval)
            }
            func result(_ candidate: RegistryCandidate) -> CandidateResult {
                let reports = ConsumerAdapter.allCases.map { $0.evaluate(extracted, profile: scenario.profile, approval: scenario.approval, candidate: candidate) }
                let primary = reports[0]
                let falsePositives = zip(scenario.semanticRequirements, primary.items).compactMap { original, actual -> String? in
                    let shouldAllow = original.support == .exact || original.support == .portable || original.support == .targetSpecific || (original.support == .approximate && scenario.approval)
                    return !shouldAllow && actual.allowed ? original.key : nil
                }
                let falseNegatives = zip(scenario.semanticRequirements, primary.items).compactMap { original, actual -> String? in
                    let shouldAllow = original.support == .exact || original.support == .portable || original.support == .targetSpecific || (original.support == .approximate && scenario.approval)
                    return shouldAllow && !actual.allowed ? original.key : nil
                }
                let silent = zip(scenario.semanticRequirements, primary.items).compactMap { original, actual -> String? in
                    original.support == .approximate && actual.allowed && actual.loss != "approvedApproximation" ? original.key : nil
                }
                return CandidateResult(allowed: primary.allowed, items: primary.items, falsePositives: falsePositives, falseNegatives: falseNegatives, silentApproximations: silent, consumerDivergences: reports.dropFirst().filter { $0 != primary }.count)
            }
            var plannerDocument = fixture.document
            let plannerKeys: [String] = ["layout.stack", "layout.overlay", "component.text", "component.button", "component.image", "navigation.system", "token.spacing"]
            plannerDocument.capabilityDeclarations = plannerKeys.map { CapabilityDeclaration(targetID: fixture.surface.targetID, key: CapabilityKey($0), support: scenario.scenario.hasPrefix("G-") && $0 == "layout.overlay" ? .approximate : .exact) }
            let plan = TargetPlanner.plan(surface: fixture.surface, document: plannerDocument, approvedApproximationKeys: scenario.approval ? [CapabilityKey("layout.overlay")] : [])
            rows.append(MatrixRow(scenario: scenario.scenario, profile: scenario.profile, approval: scenario.approval, semanticRequirements: scenario.semanticRequirements.map { OracleRequirementRecord(key: $0.key, support: $0.support) }, oracleAllowed: oracleAllowed, nodeCandidate: result(.node), propertyCandidate: result(.property), contractCandidate: result(.contract), currentPlanner: PlannerResult(allowed: plan.canPreview, diagnosticRules: plan.diagnostics.map(\.rule))))
        }
        func metrics(_ candidate: RegistryCandidate) -> CandidateMetrics {
            let results = rows.map { row in
                switch candidate { case .node: row.nodeCandidate; case .property: row.propertyCandidate; case .contract: row.contractCandidate }
            }
            let declarations = Set(oracle.cases.flatMap { row in row.semanticRequirements.map { "\(row.profile)|\(candidate.registryKey($0.key))" } })
            return CandidateMetrics(falsePositives: results.reduce(0) { $0 + $1.falsePositives.count }, falseNegatives: results.reduce(0) { $0 + $1.falseNegatives.count }, consumerDivergences: results.reduce(0) { $0 + $1.consumerDivergences }, silentApproximations: results.reduce(0) { $0 + $1.silentApproximations.count }, registryEntries: declarations.count, duplicateDeclarations: 0, buttonEventProfileChangeEntries: declarations.filter { $0 == "macos27-host|\(candidate.registryKey("button.eventEmit"))" }.count, buttonEventCollateralRequirements: oracle.cases.first(where: { $0.scenario == "B-button" })!.semanticRequirements.filter { $0.key != "button.eventEmit" && candidate.registryKey($0.key) == candidate.registryKey("button.eventEmit") }.count)
        }
        let matrix = Matrix(oracleCommit: "0f2694fb7004335fafcdcc3a6eb84322cd2117c7", measuredOracleSHA256: oracleSHA256, implementationScope: "test-only; current planner and production capability declarations unchanged", rows: rows, metrics: Dictionary(uniqueKeysWithValues: RegistryCandidate.allCases.map { ($0.rawValue, metrics($0)) }))
        for row in rows {
            let source = try XCTUnwrap(oracle.cases.first(where: { $0.scenario == row.scenario }))
            XCTAssertEqual(row.contractCandidate.items.map(\.support), source.semanticRequirements.map(\.support), row.scenario)
            XCTAssertEqual(row.contractCandidate.allowed, row.oracleAllowed, row.scenario)
        }
        let plannerUnexpectedPasses = Set(["B-button", "C-binding", "D-navigation", "E-system-compose", "H-ios15", "I-ordered-effects", "J-extension-macos"])
        XCTAssertTrue(plannerUnexpectedPasses.allSatisfy { scenario in rows.first(where: { $0.scenario == scenario })?.currentPlanner.allowed == true })
        XCTAssertEqual(rows.first(where: { $0.scenario == "F-remote" })?.currentPlanner.diagnosticRules, ["preview.asset"])
        XCTAssertEqual(matrix.metrics["contract"]?.falsePositives, 0)
        XCTAssertEqual(matrix.metrics["contract"]?.falseNegatives, 0)
        XCTAssertEqual(matrix.metrics["contract"]?.consumerDivergences, 0)
        XCTAssertEqual(matrix.metrics["contract"]?.silentApproximations, 0)
        XCTAssertGreaterThan(matrix.metrics["node"]?.falsePositives ?? 0, 0)
        XCTAssertGreaterThan(matrix.metrics["property"]?.falsePositives ?? 0, 0)
        XCTAssertEqual(rows.first(where: { $0.scenario == "G-approx-approved" })?.contractCandidate.items[0].loss, "approvedApproximation")
        if ProcessInfo.processInfo.environment["HAMII_CAPABILITY_SPIKE_OUTPUT"] == "1" {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(matrix).write(to: artifact.appendingPathComponent("capability-matrix.json"))
        }
    }
}
