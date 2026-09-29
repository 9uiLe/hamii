import Foundation
import XCTest
import HamiiCore
import HamiiApplication
@testable import HamiiFormat

/// Opt-in candidates only. No production batch, session, or mutation authority.
final class ContextObservationReuseSpikeTests: XCTestCase {
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

    private struct Input: Codable {
        let performance: [Case]
        let correctness: [String: String]
        let mainBranch: String
    }

    private struct ShapeResult: Codable {
        let shape: String
        let currentServiceMs: [String: [Double]]
        let batchMs: [String: [Double]]
        let sessionMs: [String: [Double]]
        let verifierMs: [Double]
        let batchResponses: [String: [String]]
        let sessionResponses: [String: [String]]
        let currentServiceResponses: [String: [String]]
        let currentServiceFullObservationCounts: [String: Int]
        let batchFullObservationCounts: [String: Int]
        let sessionFullObservationCounts: [String: Int]
        let sessionFreshnessVerificationCounts: [String: Int]
    }

    private struct CandidateRun {
        let responses: [String]
        let fullObservationCount: Int
        let freshnessVerificationCount: Int
    }

    private struct Result: Codable {
        let shapes: [ShapeResult]
        let correctness: [String: Bool]
    }

    private struct FixedRepository: ProjectRepository {
        let observation: ProjectObservation
        func observe() throws -> ProjectObservation { observation }
        func commit(_ document: Document, expected: ProjectObservation) throws -> ProjectObservation {
            throw AuthoringError.staleState
        }
    }

    private enum SessionError: Error { case invalidated }

    private final class TestSession {
        private let repository: CanonicalRepository
        private var observation: ProjectObservation?
        private(set) var verificationCount = 0

        init(repository: CanonicalRepository, observation: ProjectObservation) {
            self.repository = repository
            self.observation = observation
        }

        var isValid: Bool { observation != nil }

        func followUp<T>(_ project: (ProjectContextService, ClientPrecondition) throws -> T) throws -> T {
            guard let observation else { throw SessionError.invalidated }
            do {
                verificationCount += 1
                try repository.verifyCurrent(observation.statePrecondition)
            } catch {
                self.observation = nil
                throw error
            }
            return try project(ProjectContextService(repository: FixedRepository(observation: observation)),
                               observation.statePrecondition)
        }
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try XCTUnwrap(String(data: encoder.encode(value), encoding: .utf8))
    }

    private func current(_ task: String, item: Case, repository: CanonicalRepository) throws -> CandidateRun {
        let service = ProjectContextService(repository: repository)
        let selected = EntityID(task == "T1" ? item.textLayerID : item.parentLayerID)
        let screen = EntityID(item.screenID)
        let scope = EntityID(item.scopeID)
        let summary = try service.projectSummary(selection: ContextSelection(screenID: screen, layerID: selected))
        let state = summary.observation.statePrecondition
        let layer = try service.layerDetail(screenID: screen, layerID: selected, expectedState: state)
        XCTAssertEqual(summary.observation, layer.observation)
        var responses = [try json(summary), try json(layer)]
        if task == "T1" {
            return CandidateRun(responses: responses, fullObservationCount: 2, freshnessVerificationCount: 0)
        }
        if task == "T2" {
            let resources = try service.resources(consumerScopeID: scope, kind: .component,
                matching: "PriceBadge", expectedState: state)
            let chosen = try XCTUnwrap(resources.payload.items.first?.id)
            let detail = try service.componentDetail(componentID: chosen, consumerScopeID: scope,
                expectedState: state)
            XCTAssertEqual(summary.observation, resources.observation)
            XCTAssertEqual(summary.observation, detail.observation)
            responses += [try json(resources), try json(detail)]
        } else {
            let resources = try service.resources(consumerScopeID: scope, kind: .token,
                matching: "spacing.checkout", expectedState: state)
            let chosen = try XCTUnwrap(resources.payload.items.first?.id)
            let detail = try service.tokenDetail(tokenID: chosen, consumerScopeID: scope,
                expectedState: state)
            XCTAssertEqual(summary.observation, resources.observation)
            XCTAssertEqual(summary.observation, detail.observation)
            responses += [try json(resources), try json(detail)]
        }
        return CandidateRun(responses: responses, fullObservationCount: 4, freshnessVerificationCount: 0)
    }

    private func batch(_ task: String, item: Case, repository: CanonicalRepository) throws -> CandidateRun {
        let first = try repository.observe()
        var observationCount = 1
        let service = ProjectContextService(repository: FixedRepository(observation: first))
        let selected = EntityID(task == "T1" ? item.textLayerID : item.parentLayerID)
        let screen = EntityID(item.screenID)
        let scope = EntityID(item.scopeID)
        let summary = try service.projectSummary(selection: ContextSelection(screenID: screen, layerID: selected))
        let layer = try service.layerDetail(screenID: screen, layerID: selected,
            expectedState: first.statePrecondition)
        XCTAssertEqual(summary.observation, layer.observation)
        var responses = [try json(summary), try json(layer)]
        if task == "T1" { return CandidateRun(responses: responses, fullObservationCount: 1, freshnessVerificationCount: 0) }
        if task == "T2" {
            let resources = try service.resources(consumerScopeID: scope, kind: .component,
                matching: "PriceBadge", expectedState: first.statePrecondition)
            XCTAssertEqual(resources.payload.items.map(\.id), [EntityID(item.componentID)])
            XCTAssertEqual(summary.observation, resources.observation)
            let chosen = try XCTUnwrap(resources.payload.items.first?.id)
            let second = try repository.observe()
            observationCount += 1
            let detail = try ProjectContextService(repository: FixedRepository(observation: second))
                .componentDetail(componentID: chosen, consumerScopeID: scope,
                                 expectedState: first.statePrecondition)
            XCTAssertEqual(summary.observation, detail.observation)
            responses += [try json(resources), try json(detail)]
        } else {
            let resources = try service.resources(consumerScopeID: scope, kind: .token,
                matching: "spacing.checkout", expectedState: first.statePrecondition)
            XCTAssertEqual(resources.payload.items.map(\.id), [EntityID(item.tokenID)])
            XCTAssertEqual(summary.observation, resources.observation)
            let chosen = try XCTUnwrap(resources.payload.items.first?.id)
            let second = try repository.observe()
            observationCount += 1
            let detail = try ProjectContextService(repository: FixedRepository(observation: second))
                .tokenDetail(tokenID: chosen, consumerScopeID: scope,
                             expectedState: first.statePrecondition)
            XCTAssertEqual(summary.observation, detail.observation)
            responses += [try json(resources), try json(detail)]
        }
        return CandidateRun(responses: responses, fullObservationCount: observationCount, freshnessVerificationCount: 0)
    }

    private func session(_ task: String, item: Case, repository: CanonicalRepository) throws -> CandidateRun {
        let first = try repository.observe()
        let held = TestSession(repository: repository, observation: first)
        let service = ProjectContextService(repository: FixedRepository(observation: first))
        let selected = EntityID(task == "T1" ? item.textLayerID : item.parentLayerID)
        let screen = EntityID(item.screenID)
        let scope = EntityID(item.scopeID)
        let summary = try service.projectSummary(selection: ContextSelection(screenID: screen, layerID: selected))
        let layer = try held.followUp { service, state in
            try service.layerDetail(screenID: screen, layerID: selected, expectedState: state)
        }
        XCTAssertEqual(summary.observation, layer.observation)
        var responses = [try json(summary), try json(layer)]
        if task == "T1" {
            XCTAssertEqual(held.verificationCount, 1)
            return CandidateRun(responses: responses, fullObservationCount: 1,
                                freshnessVerificationCount: held.verificationCount)
        }
        if task == "T2" {
            let resources = try held.followUp { service, state in
                try service.resources(consumerScopeID: scope, kind: .component,
                                      matching: "PriceBadge", expectedState: state)
            }
            XCTAssertEqual(resources.payload.items.map(\.id), [EntityID(item.componentID)])
            let chosen = try XCTUnwrap(resources.payload.items.first?.id)
            let detail = try held.followUp { service, state in
                try service.componentDetail(componentID: chosen, consumerScopeID: scope, expectedState: state)
            }
            XCTAssertEqual(summary.observation, resources.observation)
            XCTAssertEqual(summary.observation, detail.observation)
            responses += [try json(resources), try json(detail)]
        } else {
            let resources = try held.followUp { service, state in
                try service.resources(consumerScopeID: scope, kind: .token,
                                      matching: "spacing.checkout", expectedState: state)
            }
            XCTAssertEqual(resources.payload.items.map(\.id), [EntityID(item.tokenID)])
            let chosen = try XCTUnwrap(resources.payload.items.first?.id)
            let detail = try held.followUp { service, state in
                try service.tokenDetail(tokenID: chosen, consumerScopeID: scope, expectedState: state)
            }
            XCTAssertEqual(summary.observation, resources.observation)
            XCTAssertEqual(summary.observation, detail.observation)
            responses += [try json(resources), try json(detail)]
        }
        XCTAssertEqual(held.verificationCount, 3)
        return CandidateRun(responses: responses, fullObservationCount: 1,
                            freshnessVerificationCount: held.verificationCount)
    }

    private func elapsed(_ body: () throws -> CandidateRun) throws -> (CandidateRun, Double) {
        let started = DispatchTime.now().uptimeNanoseconds
        let response = try body()
        return (response, Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
    }

    private func expectInvalidation(root: URL, change: (CanonicalRepository, ProjectObservation) throws -> Void) throws -> Bool {
        let repository = CanonicalRepository(root: root)
        let first = try repository.observe()
        let held = TestSession(repository: repository, observation: first)
        try change(repository, first)
        XCTAssertThrowsError(try held.followUp { service, state in
            try service.projectSummary(expectedState: state)
        })
        XCTAssertFalse(held.isValid)
        XCTAssertThrowsError(try held.followUp { service, state in
            try service.projectSummary(expectedState: state)
        })
        return !held.isValid
    }

    private func correctness(_ input: Input) throws -> [String: Bool] {
        func root(_ name: String) throws -> URL {
            URL(fileURLWithPath: try XCTUnwrap(input.correctness[name]))
        }
        var results: [String: Bool] = [:]
        let stable = CanonicalRepository(root: try root("stable"))
        let first = try stable.observe()
        let held = TestSession(repository: stable, observation: first)
        let current = try ProjectContextService(repository: stable).projectSummary()
        let cached = try held.followUp { service, state in
            try service.projectSummary(expectedState: state)
        }
        XCTAssertEqual(current, cached)
        results["unchanged"] = current == cached && held.isValid

        results["semanticMutation"] = try expectInvalidation(root: root("mutation")) { repository, old in
            let service = ProjectService(repository: repository)
            _ = try service.mutate(.createPage(name: "changed"), expectedState: old.statePrecondition, author: .human)
            XCTAssertThrowsError(try service.mutate(.createPage(name: "stale"),
                expectedState: old.statePrecondition, author: .human))
        }
        let batchRepository = CanonicalRepository(root: try root("batchStale"))
        let batchFirst = try batchRepository.observe()
        let batchFirstService = ProjectContextService(repository: FixedRepository(observation: batchFirst))
        let batchResources = try batchFirstService.resources(consumerScopeID: EntityID(input.performance[0].scopeID),
            kind: .component, matching: "PriceBadge", expectedState: batchFirst.statePrecondition)
        let chosen = try XCTUnwrap(batchResources.payload.items.first?.id)
        _ = try ProjectService(repository: batchRepository).mutate(.createPage(name: "between batches"),
            expectedState: batchFirst.statePrecondition, author: .human)
        let batchSecond = try batchRepository.observe()
        XCTAssertThrowsError(try ProjectContextService(repository: FixedRepository(observation: batchSecond))
            .componentDetail(componentID: chosen, consumerScopeID: EntityID(input.performance[0].scopeID),
                             expectedState: batchFirst.statePrecondition))
        results["batchSecondObservationRejectsStale"] = batchFirst.statePrecondition != batchSecond.statePrecondition
        results["sameRevisionManagedSwitch"] = try expectInvalidation(root: root("branch")) { repository, old in
            let switched = try ManagedGit(root: repository.root).switchBranch("other", expectedState: old.statePrecondition)
            XCTAssertEqual(old.document.revision, switched.document.revision)
            XCTAssertNotEqual(old.statePrecondition, switched.statePrecondition)
        }
        results["coordinatedAtoBtoA"] = try expectInvalidation(root: root("roundTrip")) { repository, old in
            let service = ProjectService(repository: repository)
            let screen = EntityID(input.performance[0].screenID)
            let layer = EntityID(input.performance[0].textLayerID)
            let changed = try service.mutate(.setText(screenID: screen, layerID: layer, text: "B"),
                expectedState: old.statePrecondition, author: .human)
            _ = try service.mutate(.setText(screenID: screen, layerID: layer, text: "Order summary"),
                expectedState: try XCTUnwrap(changed.statePrecondition), author: .human)
            XCTAssertNotEqual(try repository.observe().statePrecondition, old.statePrecondition)
        }
        for (key, filename) in [("pendingGit", "managed-git-transition.json"),
                                 ("pendingMerge", "merge-publication.pending.json"),
                                 ("pendingMigration", "migration-publication.pending.json")] {
            results[key] = try expectInvalidation(root: root(key)) { repository, _ in
                try Data("{}".utf8).write(to: repository.root.appendingPathComponent(".hamii/\(filename)"), options: .atomic)
            }
        }
        results["epochMissing"] = try expectInvalidation(root: root("epochMissing")) { repository, _ in
            try FileManager.default.removeItem(at: repository.root.appendingPathComponent(".hamii/client-observation-epoch"))
        }
        results["epochCorrupt"] = try expectInvalidation(root: root("epochCorrupt")) { repository, _ in
            try Data("corrupt\n".utf8).write(to: repository.root.appendingPathComponent(".hamii/client-observation-epoch"), options: .atomic)
        }
        results["agentProfileEdit"] = try expectInvalidation(root: root("agentProfile")) { repository, _ in
            let path = repository.root.appendingPathComponent("hamii-agent-profiles.json")
            let original = try String(contentsOf: path, encoding: .utf8)
            let changed = original.replacingOccurrences(of: "\"builder\"", with: "\"builderChanged\"")
            XCTAssertNotEqual(original, changed)
            try changed.write(to: path, atomically: true, encoding: .utf8)
        }
        results["externalCanonicalEdit"] = try expectInvalidation(root: root("externalEdit")) { repository, _ in
            let path = repository.root.appendingPathComponent("screens/\(input.performance[0].screenID).json")
            let original = try String(contentsOf: path, encoding: .utf8)
            let changed = original.replacingOccurrences(of: "Order summary", with: "External edit")
            XCTAssertNotEqual(original, changed)
            try changed.write(to: path, atomically: true, encoding: .utf8)
        }
        let scopeRepository = CanonicalRepository(root: try root("scope"))
        let scopeObserved = try scopeRepository.observe()
        let scopeSession = TestSession(repository: scopeRepository, observation: scopeObserved)
        let scope = EntityID(input.performance[0].scopeID)
        let production = try ProjectContextService(repository: scopeRepository).resources(
            consumerScopeID: scope, kind: .component, matching: "PrivateBadge",
            expectedState: scopeObserved.statePrecondition)
        let session = try scopeSession.followUp { service, state in
            try service.resources(consumerScopeID: scope, kind: .component,
                matching: "PrivateBadge", expectedState: state)
        }
        XCTAssertTrue(production.payload.items.isEmpty)
        XCTAssertEqual(production, session)
        results["negativeScope"] = production == session && production.payload.items.isEmpty
        results["processRestartReusable"] = false // No persistent session object or serialized Document exists.
        return results
    }

    func testCandidateMatrixAndCorrectness() throws {
        guard let casesPath = ProcessInfo.processInfo.environment["HAMII_CONTEXT_REUSE_INPUT"],
              let outputPath = ProcessInfo.processInfo.environment["HAMII_CONTEXT_REUSE_OUTPUT"] else {
            throw XCTSkip("Set HAMII_CONTEXT_REUSE_INPUT and HAMII_CONTEXT_REUSE_OUTPUT")
        }
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(fileURLWithPath: casesPath)))
        var results: [ShapeResult] = []
        for item in input.performance {
            let repository = CanonicalRepository(root: URL(fileURLWithPath: item.root))
            let state = try repository.observe().statePrecondition
            var verifierMs: [Double] = []
            for _ in 0..<50 {
                let started = DispatchTime.now().uptimeNanoseconds
                try repository.verifyCurrent(state)
                verifierMs.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            }
            var batchMs: [String: [Double]] = [:]
            var sessionMs: [String: [Double]] = [:]
            var currentMs: [String: [Double]] = [:]
            var batchResponses: [String: [String]] = [:]
            var sessionResponses: [String: [String]] = [:]
            var currentResponses: [String: [String]] = [:]
            var currentCounts: [String: Int] = [:]
            var batchCounts: [String: Int] = [:]
            var sessionCounts: [String: Int] = [:]
            var verificationCounts: [String: Int] = [:]
            for task in ["T1", "T2", "T3"] {
                var batchSamples: [Double] = []
                var sessionSamples: [Double] = []
                var currentSamples: [Double] = []
                for iteration in 0..<20 {
                    if iteration < 10 {
                        let (currentRun, currentTime) = try elapsed { try current(task, item: item, repository: repository) }
                        XCTAssertEqual(currentRun.fullObservationCount, task == "T1" ? 2 : 4)
                        currentSamples.append(currentTime)
                        if iteration == 0 {
                            currentResponses[task] = currentRun.responses
                            currentCounts[task] = currentRun.fullObservationCount
                        }
                        XCTAssertEqual(currentRun.responses, currentResponses[task])
                    }
                    let (batchRun, batchTime) = try elapsed { try batch(task, item: item, repository: repository) }
                    let (sessionRun, sessionTime) = try elapsed { try session(task, item: item, repository: repository) }
                    let expectedBatchCount = task == "T1" ? 1 : 2
                    let expectedVerificationCount = task == "T1" ? 1 : 3
                    XCTAssertEqual(batchRun.fullObservationCount, expectedBatchCount)
                    XCTAssertEqual(sessionRun.fullObservationCount, 1)
                    XCTAssertEqual(sessionRun.freshnessVerificationCount, expectedVerificationCount)
                    batchSamples.append(batchTime)
                    sessionSamples.append(sessionTime)
                    if iteration == 0 {
                        batchResponses[task] = batchRun.responses
                        sessionResponses[task] = sessionRun.responses
                        batchCounts[task] = batchRun.fullObservationCount
                        sessionCounts[task] = sessionRun.fullObservationCount
                        verificationCounts[task] = sessionRun.freshnessVerificationCount
                    }
                    XCTAssertEqual(batchRun.responses, batchResponses[task])
                    XCTAssertEqual(sessionRun.responses, sessionResponses[task])
                }
                batchMs[task] = batchSamples
                sessionMs[task] = sessionSamples
                currentMs[task] = currentSamples
            }
            results.append(ShapeResult(shape: item.shape, currentServiceMs: currentMs, batchMs: batchMs,
                sessionMs: sessionMs, verifierMs: verifierMs,
                batchResponses: batchResponses, sessionResponses: sessionResponses,
                currentServiceResponses: currentResponses, currentServiceFullObservationCounts: currentCounts,
                batchFullObservationCounts: batchCounts, sessionFullObservationCounts: sessionCounts,
                sessionFreshnessVerificationCounts: verificationCounts))
        }
        let correctness = try correctness(input)
        XCTAssertTrue(correctness.filter { $0.key != "processRestartReusable" }.values.allSatisfy { $0 })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Result(shapes: results, correctness: correctness))
            .write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }
}
