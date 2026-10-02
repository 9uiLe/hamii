import Foundation
import XCTest
import HamiiCore
import HamiiIntegration
@testable import HamiiIntegrationRuntime

final class RepositoryBuildJoinTests: XCTestCase {
    private let commit = String(repeating: "a", count: 40)
    private let blob = String(repeating: "b", count: 40)
    private let path = "App/General/FlowLayout.swift"

    private func receipt(profileVersion: Int = 2) -> RepositoryProfileReceipt {
        RepositoryProfileReceipt(productCommitOID: commit, profilePath: "config/profile.json",
            profileBlobOID: String(repeating: "c", count: 40),
            profileSHA256: String(repeating: "d", count: 64), profileFormatVersion: profileVersion,
            hamiiDocumentID: EntityID("doc_bridge"), hamiiDocumentRevision: 1,
            hamiiStatePrecondition: ClientPrecondition("state"), screenID: EntityID("screen_bridge"),
            contractSHA256: String(repeating: "e", count: 64))
    }

    private func source(status: RepositorySourceEvidenceStatus = .verified,
                        scope: String? = "pinnedSourceDeclaration") -> RepositorySourceEvidence {
        RepositorySourceEvidence(mappingKey: "input:probe.flowSpacing", status: status, scope: scope,
            locator: SwiftDirectDeclarationLocator(path: path, enclosingKind: .structType,
                enclosingName: "FlowLayout", memberKind: .storedProperty, memberName: "spacing"),
            sourceBlobOID: blob, line: 12)
    }

    private func selection(owner: String = "Food Truck All", module: String = "Food_Truck_All",
                           configuration: String = "Debug", project: String = "Food Truck.xcodeproj")
        -> RepositoryBuildSelection {
        RepositoryBuildSelection(projectPath: project, scheme: "Food Truck All",
            rootTarget: "Food Truck All", ownerTarget: owner, module: module,
            configuration: configuration, sdk: "iphonesimulator",
            destination: "generic/platform=iOS Simulator", architecture: "arm64")
    }

    private func input(kind: RepositoryBuildInputKind = .tracked,
                       path: String? = nil, blob: String? = nil) -> RepositoryBuildInput {
        RepositoryBuildInput(kind: kind, path: path ?? self.path, blobOID: blob ?? self.blob)
    }

    private func invocation(owner: String = "Food Truck All", module: String = "Food_Truck_All",
                            executed: Bool = true, inputs: [RepositoryBuildInput]? = nil,
                            compiler: String = "/Applications/Xcode.app/usr/bin/swiftc",
                            version: String = "6.4", id: String = "invocation-1",
                            argumentHash: String = String(repeating: "1", count: 64),
                            inventoryHash: String = String(repeating: "2", count: 64))
        -> RepositoryExecutedSwiftInvocation {
        RepositoryExecutedSwiftInvocation(executed: executed, ownerTarget: owner, module: module,
            compilerExecutable: compiler, compilerVersion: version,
            normalizedArgumentsSHA256: argumentHash, invocationID: id,
            inventorySHA256: inventoryHash, inputs: inputs ?? [input()])
    }

    private func inventory(selection: RepositoryBuildSelection? = nil,
                           commit: String? = nil, format: String = RepositoryExecutedBuildInventory.recognizedFormat,
                           succeeded: Bool = true, complete: Bool = true, protected: Bool = true,
                           invocations: [RepositoryExecutedSwiftInvocation]? = nil,
                           resolved: RepositoryBuildSelection? = nil) -> RepositoryExecutedBuildInventory {
        let chosen = selection ?? self.selection()
        return RepositoryExecutedBuildInventory(formatIdentifier: format,
            productCommitOID: commit ?? self.commit, requestedSelection: chosen,
            resolvedSelection: resolved ?? chosen, buildSucceeded: succeeded,
            inventoryComplete: complete, sourceMaterializationProtected: protected,
            invocations: invocations ?? [invocation()])
    }

    private func assess(receipt: RepositoryProfileReceipt? = nil,
                        source: RepositorySourceEvidence? = nil,
                        selection: RepositoryBuildSelection? = nil,
                        inventory: RepositoryExecutedBuildInventory? = nil) -> RepositoryBuildEvidence {
        let chosen = selection ?? self.selection()
        return RepositoryBuildJoin.evaluate(receipt: receipt ?? self.receipt(),
            sourceEvidence: source ?? self.source(), selection: chosen,
            inventory: inventory ?? self.inventory(selection: chosen))
    }

    func testExactTrackedInputYieldsOnlyAdditiveSelectedBuildMemberEvidence() throws {
        let original = source()
        let result = assess(source: original)
        XCTAssertEqual(result.status, .selectedBuildMember)
        XCTAssertEqual(result.scope, "selectedBuildMember")
        XCTAssertNil(result.reason)
        XCTAssertEqual(result.mappingKey, original.mappingKey)
        XCTAssertEqual(result.productCommitOID, commit)
        XCTAssertEqual(result.sourcePath, path)
        XCTAssertEqual(result.sourceBlobOID, blob)
        XCTAssertEqual(result.requestedSelection, selection())
        XCTAssertEqual(result.resolvedSelection, selection())
        XCTAssertEqual(result.compilerVersion, "6.4")
        XCTAssertEqual(result.normalizedArgumentsSHA256, String(repeating: "1", count: 64))
        XCTAssertEqual(result.inventorySHA256, String(repeating: "2", count: 64))
        XCTAssertEqual(try JSONDecoder().decode(RepositoryBuildEvidence.self,
            from: JSONEncoder().encode(result)), result)
        XCTAssertEqual(original.scope, "pinnedSourceDeclaration")
    }

    func testCommitMismatchPrecedesSourceAndBlobChecks() {
        let changed = inventory(commit: String(repeating: "f", count: 40),
            invocations: [invocation(inputs: [input(blob: String(repeating: "0", count: 40))])])
        let result = assess(source: source(status: .missing), inventory: changed)
        XCTAssertEqual(result.status, .staleProduct)
        XCTAssertEqual(result.reason, "commitMismatch")
        XCTAssertNil(result.scope)
    }

    func testSourceMustBeReceiptPinnedV2VerifiedDeclaration() {
        for invalid in [source(status: .missing), source(scope: "selectedBuildMember"),
                        source(scope: nil)] {
            let result = assess(source: invalid)
            XCTAssertEqual(result.status, .unverifiable)
            XCTAssertEqual(result.reason, "sourceNotVerified")
            XCTAssertNil(result.scope)
        }
        XCTAssertEqual(assess(receipt: receipt(profileVersion: 1)).reason, "sourceNotVerified")
    }

    func testExplicitSelectionAndCompleteExecutedInventoryPermitAbsence() {
        let kit = selection(owner: "FoodTruckKit", module: "FoodTruckKit")
        let selected = invocation(owner: "FoodTruckKit", module: "FoodTruckKit",
            inputs: [input(path: "FoodTruckKit/Sources/Account/User.swift")])
        let widget = invocation(owner: "Widgets", module: "Widgets")
        let result = assess(selection: kit, inventory: inventory(selection: kit,
            invocations: [selected, widget]))
        XCTAssertEqual(result.status, .missingFromSelection)
        XCTAssertEqual(result.reason, "sourceAbsent")
        XCTAssertNil(result.scope)
    }

    func testOmittedTargetOrModuleWithAbsentSourceNeverMeansMissingFromSelection() {
        for incomplete in [selection(owner: "", module: "Food_Truck_All"),
                           selection(owner: "Food Truck All", module: ""),
                           selection(owner: "", module: "")] {
            let absent = invocation(inputs: [input(path: "Other.swift")])
            let result = assess(selection: incomplete, inventory: inventory(selection: incomplete,
                invocations: [absent]))
            XCTAssertEqual(result.status, .unverifiable)
            XCTAssertEqual(result.reason, "incompleteSelection")
            XCTAssertNotEqual(result.status, .missingFromSelection)
        }
    }

    func testOmittedModuleWithTwoMatchingInvocationsIsAmbiguous() {
        let incomplete = selection(owner: "", module: "")
        let result = assess(selection: incomplete, inventory: inventory(selection: incomplete,
            invocations: [invocation(), invocation(owner: "Widgets", module: "Widgets")]))
        XCTAssertEqual(result.status, .ambiguous)
        XCTAssertEqual(result.reason, "moduleOrTargetOmitted")
    }

    func testOmittedSelectionDoesNotTreatUnexecutedOrMalformedInputsAsAmbiguity() {
        let incomplete = selection(owner: "", module: "")
        let cases: [[RepositoryExecutedSwiftInvocation]] = [
            [invocation(executed: false), invocation(owner: "Widgets", module: "Widgets", executed: false)],
            [invocation(argumentHash: "bad"),
             invocation(owner: "Widgets", module: "Widgets", inventoryHash: "bad")],
            [invocation(executed: false), invocation(owner: "Widgets", module: "Widgets")]
        ]
        for invocations in cases {
            let result = assess(selection: incomplete, inventory: inventory(selection: incomplete,
                invocations: invocations))
            XCTAssertEqual(result.status, .unverifiable)
            XCTAssertEqual(result.reason, "incompleteSelection")
            XCTAssertNil(result.scope)
        }
    }

    func testWrongBlobDuplicatePathAndMultipleSelectedInvocations() {
        let wrong = assess(inventory: inventory(invocations: [invocation(inputs:
            [input(blob: String(repeating: "0", count: 40))])]))
        XCTAssertEqual(wrong.status, .mismatchedSource)
        XCTAssertEqual(wrong.reason, "blobMismatch")
        let duplicate = assess(inventory: inventory(invocations: [invocation(inputs: [input(), input()])]))
        XCTAssertEqual(duplicate.status, .ambiguous)
        XCTAssertEqual(duplicate.reason, "duplicateLogicalPath")
        let multiple = assess(inventory: inventory(invocations: [invocation(), invocation()]))
        XCTAssertEqual(multiple.status, .ambiguous)
        XCTAssertEqual(multiple.reason, "multipleSelectedInvocations")
    }

    func testUnknownFormatFailedAndWarmBuildsAreUnverifiable() {
        let cases: [(RepositoryExecutedBuildInventory, String)] = [
            (inventory(format: "unknown"), "unknownInventoryFormat"),
            (inventory(succeeded: false), "buildNotSuccessful"),
            (inventory(complete: false), "missingInventory"),
            (inventory(invocations: []), "noExecutedInvocation"),
            (inventory(invocations: [invocation(executed: false)]), "noExecutedInvocation"),
            (inventory(protected: false), "unprotectedSourceMaterialization")
        ]
        for (build, reason) in cases {
            let result = assess(inventory: build)
            XCTAssertEqual(result.status, .unverifiable)
            XCTAssertEqual(result.reason, reason)
            XCTAssertNil(result.scope)
        }
    }

    func testRequestedResolvedMismatchAndIncompleteSelectionFailClosed() {
        let requested = selection()
        let fallback = selection(configuration: "Release")
        let mismatch = assess(selection: requested, inventory: inventory(selection: requested,
            resolved: fallback))
        XCTAssertEqual(mismatch.status, .unverifiable)
        XCTAssertEqual(mismatch.reason, "resolvedSelectionMismatch")
        let badPath = selection(project: "../Food Truck.xcodeproj")
        XCTAssertEqual(assess(selection: badPath,
            inventory: inventory(selection: badPath)).reason, "incompleteSelection")
        XCTAssertEqual(assess(inventory: inventory(selection: fallback)).reason,
            "requestedSelectionMismatch")
    }

    func testGeneratedExternalAndUntrackedInputCannotBePositive() {
        for kind in [RepositoryBuildInputKind.generated, .external, .untracked] {
            let result = assess(inventory: inventory(invocations: [invocation(inputs: [input(kind: kind)])]))
            XCTAssertEqual(result.status, .unverifiable)
            XCTAssertEqual(result.reason, "nonTrackedSourceInput")
        }
        // Other generated inputs do not erase a distinct exact tracked input.
        let mixed = assess(inventory: inventory(invocations: [invocation(inputs:
            [input(), input(kind: .generated, path: "DerivedData/Generated.swift")])]))
        XCTAssertEqual(mixed.status, .selectedBuildMember)
    }

    func testIncompleteInvocationIdentityAndUnavailableSelectedTargetFailClosed() {
        let incomplete = assess(inventory: inventory(invocations: [invocation(argumentHash: "invalid")]))
        XCTAssertEqual(incomplete.status, .unverifiable)
        XCTAssertEqual(incomplete.reason, "incompleteInvocationIdentity")
        let missingTarget = assess(inventory: inventory(invocations:
            [invocation(owner: "Widgets", module: "Widgets")]))
        XCTAssertEqual(missingTarget.status, .unverifiable)
        XCTAssertEqual(missingTarget.reason, "unknownOrUnselectedTarget")
    }

    func testIncompleteSelectedInvocationCannotAssertAbsenceOrBlobMismatch() {
        let absent = [input(path: "Other.swift")]
        let wrong = [input(blob: String(repeating: "0", count: 40))]
        let malformed: [RepositoryExecutedSwiftInvocation] = [
            invocation(inputs: absent, compiler: ""),
            invocation(inputs: absent, version: ""),
            invocation(inputs: absent, id: ""),
            invocation(inputs: absent, argumentHash: "bad"),
            invocation(inputs: absent, inventoryHash: "bad"),
            invocation(inputs: wrong, argumentHash: "bad")
        ]
        for selected in malformed {
            let result = assess(inventory: inventory(invocations: [selected]))
            XCTAssertEqual(result.status, .unverifiable)
            XCTAssertEqual(result.reason, "incompleteInvocationIdentity")
            XCTAssertNotEqual(result.status, .missingFromSelection)
            XCTAssertNotEqual(result.status, .mismatchedSource)
        }
    }
}
