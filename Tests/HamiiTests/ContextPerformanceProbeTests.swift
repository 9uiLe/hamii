import Foundation
import XCTest
import HamiiCore
import HamiiApplication
import HamiiFormat

/// Opt-in production service timing. The CLI measurement script supplies disposable fixtures.
final class ContextPerformanceProbeTests: XCTestCase {
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
        let milliseconds: [String: [Double]]
    }

    func testServiceOperationTimings() throws {
        guard let casesPath = ProcessInfo.processInfo.environment["HAMII_CONTEXT_PERF_CASES"],
              let outputPath = ProcessInfo.processInfo.environment["HAMII_CONTEXT_PERF_OUTPUT"] else {
            throw XCTSkip("Set HAMII_CONTEXT_PERF_CASES and HAMII_CONTEXT_PERF_OUTPUT to run the measurement")
        }
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: casesPath)))
        var results: [Result] = []
        for item in cases {
            let service = ProjectContextService(repository: CanonicalRepository(root: URL(fileURLWithPath: item.root)))
            let screenID = EntityID(item.screenID)
            let scopeID = EntityID(item.scopeID)
            let textID = EntityID(item.textLayerID)
            let parentID = EntityID(item.parentLayerID)
            let componentID = EntityID(item.componentID)
            let tokenID = EntityID(item.tokenID)
            let state = try service.projectSummary().observation.statePrecondition
            var times: [String: [Double]] = [:]
            func measure(_ name: String, _ body: () throws -> Void) throws {
                var samples: [Double] = []
                for _ in 0..<10 {
                    let start = DispatchTime.now().uptimeNanoseconds
                    try body()
                    samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                }
                times[name] = samples
            }
            try measure("summary") {
                let result = try service.projectSummary(selection: ContextSelection(screenID: screenID, layerID: textID))
                XCTAssertEqual(result.observation.statePrecondition, state)
            }
            try measure("layer") {
                let result = try service.layerDetail(screenID: screenID, layerID: parentID, expectedState: state)
                XCTAssertEqual(result.payload.layer.id, parentID)
            }
            try measure("resourcesComponent") {
                let result = try service.resources(consumerScopeID: scopeID, kind: .component,
                    matching: "PriceBadge", expectedState: state)
                XCTAssertEqual(result.payload.items.map(\.id), [componentID])
            }
            try measure("componentDetail") {
                let result = try service.componentDetail(componentID: componentID,
                    consumerScopeID: scopeID, expectedState: state)
                XCTAssertEqual(result.payload.id, componentID)
            }
            try measure("resourcesToken") {
                let result = try service.resources(consumerScopeID: scopeID, kind: .token,
                    matching: "spacing.checkout", expectedState: state)
                XCTAssertEqual(result.payload.items.map(\.id), [tokenID])
            }
            try measure("tokenDetail") {
                let result = try service.tokenDetail(tokenID: tokenID,
                    consumerScopeID: scopeID, expectedState: state)
                XCTAssertEqual(result.payload.id, tokenID)
            }
            results.append(Result(scale: item.scale, milliseconds: times))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(results).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }
}
