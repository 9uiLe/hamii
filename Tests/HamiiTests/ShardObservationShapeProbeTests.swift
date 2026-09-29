import Foundation
import XCTest
import HamiiCore
import HamiiApplication
@testable import HamiiFormat

/// Opt-in shape and observation-count measurement. The candidate is in-memory
/// projection after one real observation, never a production batch or lease.
final class ShardObservationShapeProbeTests: XCTestCase {
    private struct Case: Codable {
        let shape: String
        let root: String
        let screenID: String
        let textLayerID: String
        let parentLayerID: String
        let scopeID: String
        let componentID: String
        let tokenID: String
    }

    private struct Result: Codable {
        let shape: String
        let observeMs: [Double]
        let instrumentedObserveMs: [Double]
        let stagesMs: [String: [Double]]
        let folderDecodeMs: [String: [Double]]
        let stageBytes: [String: Int]
        let stagePathCounts: [String: Int]
        let candidateMs: [String: [Double]]
        let candidateResponses: [String: [String]]
    }

    private struct FixedRepository: ProjectRepository {
        let observed: ProjectObservation
        func observe() throws -> ProjectObservation { observed }
        func commit(_ document: Document, expected: ProjectObservation) throws -> ProjectObservation {
            throw AuthoringError.staleState
        }
    }

    private func responseJSON<T: Encodable>(_ response: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try XCTUnwrap(String(data: encoder.encode(response), encoding: .utf8))
    }

    private func candidate(_ task: String, case item: Case,
                           observed: ProjectObservation) throws -> [String] {
        let context = ProjectContextService(repository: FixedRepository(observed: observed))
        let screen = EntityID(item.screenID)
        let text = EntityID(item.textLayerID)
        let parent = EntityID(item.parentLayerID)
        let scope = EntityID(item.scopeID)
        let state = observed.statePrecondition
        let selected = task == "T1" ? text : parent
        let summary = try context.projectSummary(selection: ContextSelection(screenID: screen, layerID: selected))
        let layer = try context.layerDetail(screenID: screen, layerID: selected, expectedState: state)
        XCTAssertEqual(summary.observation, layer.observation)
        var values = [try responseJSON(summary), try responseJSON(layer)]
        if task == "T2" {
            let resources = try context.resources(consumerScopeID: scope, kind: .component,
                matching: "PriceBadge", expectedState: state)
            let detail = try context.componentDetail(componentID: EntityID(item.componentID),
                consumerScopeID: scope, expectedState: state)
            XCTAssertEqual(resources.observation, summary.observation)
            XCTAssertEqual(detail.observation, summary.observation)
            XCTAssertEqual(resources.payload.items.map(\.id), [EntityID(item.componentID)])
            values += [try responseJSON(resources), try responseJSON(detail)]
        } else if task == "T3" {
            let resources = try context.resources(consumerScopeID: scope, kind: .token,
                matching: "spacing.checkout", expectedState: state)
            let detail = try context.tokenDetail(tokenID: EntityID(item.tokenID),
                consumerScopeID: scope, expectedState: state)
            XCTAssertEqual(resources.observation, summary.observation)
            XCTAssertEqual(detail.observation, summary.observation)
            XCTAssertEqual(resources.payload.items.map(\.id), [EntityID(item.tokenID)])
            values += [try responseJSON(resources), try responseJSON(detail)]
        }
        return values
    }

    func testShapeAndObservationCount() throws {
        guard let casesPath = ProcessInfo.processInfo.environment["HAMII_SHARD_SHAPE_CASES"],
              let outputPath = ProcessInfo.processInfo.environment["HAMII_SHARD_SHAPE_OUTPUT"] else {
            throw XCTSkip("Set HAMII_SHARD_SHAPE_CASES and HAMII_SHARD_SHAPE_OUTPUT")
        }
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: casesPath)))
        var results: [Result] = []
        for item in cases {
            let repository = CanonicalRepository(root: URL(fileURLWithPath: item.root))
            var plain: [Double] = []
            var instrumented: [Double] = []
            var stages: [String: [Double]] = [:]
            var folderDecode: [String: [Double]] = [:]
            var stageBytes: [String: Int] = [:]
            var stagePathCounts: [String: Int] = [:]
            var last: ProjectObservation?
            for _ in 0..<20 {
                let started = DispatchTime.now().uptimeNanoseconds
                last = try repository.observe()
                plain.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            }
            for _ in 0..<20 {
                var measurements: [CanonicalObservationMeasurement] = []
                let started = DispatchTime.now().uptimeNanoseconds
                let measured = try repository.observeForMeasurement { measurements.append($0) }
                instrumented.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
                XCTAssertEqual(measured.statePrecondition, last?.statePrecondition)
                var iterationStages: [String: Double] = [:]
                var iterationFolders: [String: Double] = [:]
                var iterationBytes: [String: Int] = [:]
                var iterationPaths: [String: Int] = [:]
                for measurement in measurements {
                    let stage = measurement.stage.rawValue
                    iterationStages[stage, default: 0] += measurement.milliseconds
                    if measurement.stage == .entityDecode, let folder = measurement.detail {
                        iterationFolders[folder, default: 0] += measurement.milliseconds
                    }
                    if let bytes = measurement.bytes { iterationBytes[stage, default: 0] += bytes }
                    if let count = measurement.pathCount { iterationPaths[stage, default: 0] += count }
                }
                for (stage, value) in iterationStages { stages[stage, default: []].append(value) }
                for (folder, value) in iterationFolders { folderDecode[folder, default: []].append(value) }
                stageBytes = iterationBytes
                stagePathCounts = iterationPaths
            }
            var candidateMs: [String: [Double]] = [:]
            var candidateResponses: [String: [String]] = [:]
            for task in ["T1", "T2", "T3"] {
                var samples: [Double] = []
                for iteration in 0..<20 {
                    let started = DispatchTime.now().uptimeNanoseconds
                    let observed = try repository.observe()
                    let responses = try candidate(task, case: item, observed: observed)
                    samples.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
                    if iteration == 0 { candidateResponses[task] = responses }
                }
                candidateMs[task] = samples
            }
            results.append(Result(shape: item.shape, observeMs: plain,
                instrumentedObserveMs: instrumented, stagesMs: stages,
                folderDecodeMs: folderDecode, stageBytes: stageBytes,
                stagePathCounts: stagePathCounts, candidateMs: candidateMs,
                candidateResponses: candidateResponses))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }
}
