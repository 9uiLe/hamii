import Foundation
import XCTest
import HamiiCore
import HamiiIntegration

final class IntegrationPlannerTests: XCTestCase {
    private func contract() -> IntegrationContract {
        IntegrationContract(
            screenID: EntityID("screen_profile"), name: "Profile",
            architectureScopeID: EntityID("scope_app"), inputs: [], events: [],
            tokenIDs: [], assetIDs: [], nativeIntents: [], accessibilityLabels: [])
    }

    private func stateContract() -> IntegrationContract {
        var value = contract()
        value.semanticSources = [
            .init(key: .init("profile.displayName"), valueKind: .text),
            .init(key: .init("profile.createdAt"), valueKind: .date),
            .init(key: .init("profile.renderable"), valueKind: .boolean)
        ]
        value.relations = [
            .init(output: .init("I01"), source: .init("profile.displayName"),
                  visibleWhen: .booleanEquals(source: .init("profile.renderable"), value: true),
                  whenNil: .literal("Guest")),
            .init(output: .init("I02"), source: .init("profile.createdAt"),
                  visibleWhen: .booleanEquals(source: .init("profile.renderable"), value: true),
                  whenNil: .hidden)
        ]
        return value
    }

    private func mappedProfile() -> IntegrationProfile {
        var profile = IntegrationProfile(repositoryName: "Product")
        profile.stateMappings = [
            "profile.displayName": "Profile.nickname",
            "profile.createdAt": "Profile.createdAt",
            "profile.renderable": "Profile.isRenderable"
        ]
        return profile
    }

    func testLegacyContractJSONRoundTripKeepsExistingShape() throws {
        var value = contract()
        value.inputs = ["user.name"]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let original = try encoder.encode(value)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        XCTAssertEqual(Set(keys.keys), ["screenID", "name", "architectureScopeID", "inputs", "events",
                                         "tokenIDs", "assetIDs", "nativeIntents", "accessibilityLabels"])
        let decoded = try JSONDecoder().decode(IntegrationContract.self, from: original)
        XCTAssertNil(decoded.semanticSources)
        XCTAssertNil(decoded.relations)
        XCTAssertEqual(try encoder.encode(decoded), original)
    }

    func testTypedRelationJSONRoundTrip() throws {
        let value = stateContract()
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(IntegrationContract.self, from: data)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.relations?.first?.dependencies,
                       [.init("profile.displayName"), .init("profile.renderable")])
    }

    func testMissingAndInvalidRelationDependenciesFailClosed() {
        var value = stateContract()
        value.semanticSources?.removeAll { $0.key == .init("profile.renderable") }
        var plan = IntegrationContracts.plan(value, profile: mappedProfile())
        XCTAssertEqual(plan.blockedOutputs, [.init("I01"), .init("I02")])
        XCTAssertTrue(plan.resolutionIssues.contains(.init(code: .missingDependency,
                                                           semanticID: "profile.renderable", output: .init("I01"))))
        value.semanticSources?.append(.init(key: .init("profile.renderable"), valueKind: .text))
        plan = IntegrationContracts.plan(value, profile: mappedProfile())
        XCTAssertEqual(plan.blockedOutputs, [.init("I01"), .init("I02")])
        XCTAssertTrue(plan.resolutionIssues.contains(.init(code: .invalidRelation,
                                                           semanticID: "profile.renderable", output: .init("I01"))))
    }

    func testMissingEmptyAndWhitespaceLegacyMappingsNeedResolution() {
        var value = contract()
        value.inputs = ["user.name"]
        for candidate: String? in [nil, "", " \t\n "] {
            var profile = IntegrationProfile(repositoryName: "Product")
            profile.stateMappings["user.name"] = candidate
            let plan = IntegrationContracts.plan(value, profile: profile)
            XCTAssertEqual(plan.unresolvedMappings, ["input:user.name"])
            XCTAssertEqual(plan.resolutionIssues.map(\.code),
                           [candidate == nil ? .missingMapping : .emptyMapping])
        }
    }

    func testUnknownTransformAndDuplicateOutputFailClosed() throws {
        var value = stateContract()
        value.relations?[1].transform = .init("date.koreanCopy")
        var plan = IntegrationContracts.plan(value, profile: mappedProfile())
        XCTAssertEqual(plan.blockedOutputs, [.init("I02")])
        XCTAssertTrue(plan.resolutionIssues.contains(.init(code: .unsupportedTransform,
                                                           semanticID: "date.koreanCopy", output: .init("I02"))))
        let duplicate = try XCTUnwrap(value.relations?.first)
        value.relations?.append(duplicate)
        plan = IntegrationContracts.plan(value, profile: mappedProfile())
        XCTAssertEqual(plan.blockedOutputs, [.init("I01"), .init("I02")])
        XCTAssertTrue(plan.resolutionIssues.contains(.init(code: .invalidRelation,
                                                           semanticID: "I01", output: .init("I01"))))
    }

    func testTypedAmbiguousAndConflictingAssessmentBlocksDependentOutput() {
        let value = stateContract()
        var assessments = IntegrationPlanner.assessments(for: value, profile: mappedProfile())
        let name = IntegrationMappingKey(kind: .source, semanticID: "profile.displayName")
        let date = IntegrationMappingKey(kind: .source, semanticID: "profile.createdAt")
        assessments.removeAll { $0.key == name || $0.key == date }
        assessments.append(.init(key: name, status: .ambiguous))
        assessments.append(.init(key: date, status: .conflicting))
        let plan = IntegrationPlanner.plan(value, assessments: assessments)
        XCTAssertEqual(plan.blockedOutputs, [.init("I01"), .init("I02")])
        XCTAssertTrue(plan.resolutionIssues.contains(.init(code: .ambiguousMapping, semanticID: name.identifier)))
        XCTAssertTrue(plan.resolutionIssues.contains(.init(code: .conflictingMapping, semanticID: date.identifier)))
    }

    func testInvalidMappingAndAvatarConflictNeverChooseAdaptation() {
        var value = contract()
        value.semanticSources = [.init(key: .init("profile.avatar"), valueKind: .image)]
        value.relations = [.init(output: .init("I03.avatar"), source: .init("profile.avatar"), whenNil: .hidden)]
        let key = IntegrationMappingKey(kind: .source, semanticID: "profile.avatar")
        for (status, code): (IntegrationMappingStatus, IntegrationIssueCode) in [
            (.invalid, .invalidMapping), (.conflicting, .conflictingMapping)
        ] {
            let plan = IntegrationPlanner.plan(value, assessments: [.init(key: key, status: status)])
            XCTAssertEqual(plan.blockedOutputs, [.init("I03.avatar")])
            XCTAssertEqual(plan.resolutionIssues.map(\.code), [code])
            XCTAssertTrue(plan.needsResolution)
        }
    }

    func testUnspecifiedNilBehaviorBlocksEvenWithMappedSource() {
        var value = contract()
        value.semanticSources = [.init(key: .init("profile.avatar"), valueKind: .image)]
        value.relations = [.init(output: .init("I03.avatar"), source: .init("profile.avatar"))]
        var profile = IntegrationProfile(repositoryName: "Product")
        profile.stateMappings["profile.avatar"] = "Profile.avatar"
        let plan = IntegrationContracts.plan(value, profile: profile)
        XCTAssertEqual(plan.blockedOutputs, [.init("I03.avatar")])
        XCTAssertEqual(plan.resolutionIssues.map(\.code), [.unresolvedNilBehavior])
        XCTAssertTrue(plan.needsResolution)
        XCTAssertTrue(plan.unresolvedMappings.isEmpty) // A nil rule is not a missing mapping.
    }

    func testUnmappedLegacyResourceConservativelyBlocksPartialApplication() {
        var value = stateContract()
        value.assetIDs = [EntityID("asset_avatar")]
        let plan = IntegrationContracts.plan(value, profile: mappedProfile())
        XCTAssertEqual(plan.unresolvedMappings, ["asset:asset_avatar"])
        XCTAssertEqual(plan.blockedOutputs, [.init("I01"), .init("I02")])
        XCTAssertTrue(plan.needsResolution)
    }

    func testSharedAndOutputSpecificDependenciesBlockOnlyAffectedOutputs() {
        let value = stateContract()
        var profile = mappedProfile()
        let valid = IntegrationContracts.plan(value, profile: profile)
        XCTAssertTrue(valid.blockedOutputs.isEmpty)
        XCTAssertTrue(valid.resolutionIssues.isEmpty)
        profile.stateMappings.removeValue(forKey: "profile.createdAt")
        var plan = IntegrationContracts.plan(value, profile: profile)
        XCTAssertEqual(plan.blockedOutputs, [.init("I02")])
        XCTAssertEqual(plan.unresolvedMappings, ["source:profile.createdAt"])
        profile = mappedProfile()
        profile.stateMappings.removeValue(forKey: "profile.renderable")
        plan = IntegrationContracts.plan(value, profile: profile)
        XCTAssertEqual(plan.blockedOutputs, [.init("I01"), .init("I02")])
        XCTAssertEqual(plan.unresolvedMappings, ["source:profile.renderable"])
    }

    func testPlanningIsIndependentOfAssessmentOrder() throws {
        let value = stateContract()
        var assessments = IntegrationPlanner.assessments(for: value, profile: mappedProfile())
        assessments.append(.init(key: .init(kind: .source, semanticID: "profile.renderable"), status: .resolved("second")))
        assessments.removeAll { $0.key.semanticID == "profile.createdAt" }
        let first = IntegrationPlanner.plan(value, assessments: assessments)
        let second = IntegrationPlanner.plan(value, assessments: assessments.reversed())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(first), try encoder.encode(second))
        XCTAssertEqual(first.blockedOutputs, [.init("I01"), .init("I02")])
    }
}
