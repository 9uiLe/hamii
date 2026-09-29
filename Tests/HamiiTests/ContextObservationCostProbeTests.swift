import Foundation
import XCTest
import HamiiCore
import HamiiApplication
@testable import HamiiFormat

/// Opt-in measurements of the production observation path. Nothing here is a
/// freshness shortcut or a service-level latency guarantee.
final class ContextObservationCostProbeTests: XCTestCase {
    private struct Case: Codable {
        let scale: Int
        let root: String
        let screenID: String
        let textLayerID: String
        let parentLayerID: String
        let scopeID: String
        let componentID: String
        let tokenID: String
    }

    private struct Result: Codable {
        let scale: Int
        let observeMs: [Double]
        let instrumentedObserveMs: [Double]
        let stagesMs: [String: [Double]]
        let stageBytes: [String: Int]
        let stagePathCounts: [String: Int]
        let agentProfilesReadValidationMs: [Double]
        let inMemoryContextMs: [String: [Double]]
    }

    private struct ObservedRepository: ProjectRepository {
        let observed: ProjectObservation
        func observe() throws -> ProjectObservation { observed }
        func commit(_ document: Document, expected: ProjectObservation) throws -> ProjectObservation {
            throw AuthoringError.staleState
        }
    }

    func testObservationCost() throws {
        guard let casePath = ProcessInfo.processInfo.environment["HAMII_CONTEXT_OBSERVATION_CASES"],
              let outputPath = ProcessInfo.processInfo.environment["HAMII_CONTEXT_OBSERVATION_OUTPUT"] else {
            throw XCTSkip("Set HAMII_CONTEXT_OBSERVATION_CASES and HAMII_CONTEXT_OBSERVATION_OUTPUT")
        }
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: casePath)))
        var results: [Result] = []
        for item in cases {
            let root = URL(fileURLWithPath: item.root)
            let repository = CanonicalRepository(root: root)
            var observeMs: [Double] = []
            var instrumentedMs: [Double] = []
            var stages: [String: [Double]] = [:]
            var stageBytes: [String: Int] = [:]
            var stagePathCounts: [String: Int] = [:]
            var observed: ProjectObservation?
            for _ in 0..<20 {
                let started = DispatchTime.now().uptimeNanoseconds
                observed = try repository.observe()
                observeMs.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            }
            for _ in 0..<20 {
                var measurements: [CanonicalObservationMeasurement] = []
                let started = DispatchTime.now().uptimeNanoseconds
                let measured = try repository.observeForMeasurement { measurements.append($0) }
                instrumentedMs.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
                XCTAssertEqual(measured.statePrecondition, observed?.statePrecondition)
                var iterationMs: [String: Double] = [:]
                var iterationBytes: [String: Int] = [:]
                var iterationPaths: [String: Int] = [:]
                for measurement in measurements {
                    iterationMs[measurement.stage.rawValue, default: 0] += measurement.milliseconds
                    if let bytes = measurement.bytes {
                        iterationBytes[measurement.stage.rawValue, default: 0] += bytes
                    }
                    if let count = measurement.pathCount {
                        iterationPaths[measurement.stage.rawValue, default: 0] += count
                    }
                }
                for (stage, duration) in iterationMs { stages[stage, default: []].append(duration) }
                for (stage, bytes) in iterationBytes { stageBytes[stage] = bytes }
                for (stage, count) in iterationPaths { stagePathCounts[stage] = count }
            }
            let stable = try XCTUnwrap(observed)
            let state = stable.statePrecondition
            let context = ProjectContextService(repository: ObservedRepository(observed: stable))
            let screen = EntityID(item.screenID)
            let text = EntityID(item.textLayerID)
            let parent = EntityID(item.parentLayerID)
            let scope = EntityID(item.scopeID)
            let component = EntityID(item.componentID)
            let token = EntityID(item.tokenID)
            var projections: [String: [Double]] = [:]
            func measure(_ name: String, _ operation: () throws -> Void) throws {
                var samples: [Double] = []
                for _ in 0..<100 {
                    let started = DispatchTime.now().uptimeNanoseconds
                    try operation()
                    samples.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
                }
                projections[name] = samples
            }
            try measure("summary") {
                let response = try context.projectSummary(selection: ContextSelection(screenID: screen, layerID: text))
                XCTAssertEqual(response.observation.statePrecondition, state)
            }
            try measure("layer") {
                let response = try context.layerDetail(screenID: screen, layerID: parent, expectedState: state)
                XCTAssertEqual(response.payload.layer.id, parent)
            }
            try measure("resourcesComponent") {
                let response = try context.resources(consumerScopeID: scope, kind: .component,
                    matching: "PriceBadge", expectedState: state)
                XCTAssertEqual(response.payload.items.map(\.id), [component])
            }
            try measure("componentDetail") {
                let response = try context.componentDetail(componentID: component,
                    consumerScopeID: scope, expectedState: state)
                XCTAssertEqual(response.payload.id, component)
            }
            try measure("resourcesToken") {
                let response = try context.resources(consumerScopeID: scope, kind: .token,
                    matching: "spacing.checkout", expectedState: state)
                XCTAssertEqual(response.payload.items.map(\.id), [token])
            }
            try measure("tokenDetail") {
                let response = try context.tokenDetail(tokenID: token,
                    consumerScopeID: scope, expectedState: state)
                XCTAssertEqual(response.payload.id, token)
            }
            var agentProfileMs: [Double] = []
            for _ in 0..<20 {
                let started = DispatchTime.now().uptimeNanoseconds
                XCTAssertEqual(try AgentProfilesRepository(root: root).profiles().count, 2)
                agentProfileMs.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            }
            results.append(Result(scale: item.scale, observeMs: observeMs,
                instrumentedObserveMs: instrumentedMs, stagesMs: stages,
                stageBytes: stageBytes, stagePathCounts: stagePathCounts,
                agentProfilesReadValidationMs: agentProfileMs,
                inMemoryContextMs: projections))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }
}
