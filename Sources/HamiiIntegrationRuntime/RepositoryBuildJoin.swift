import Foundation
import HamiiIntegration

// These normalized records are internal: only a trusted build acquisition
// adapter may supply them. An arbitrary caller-provided inventory must never
// become public authority for selectedBuildMember.
enum RepositoryBuildInputKind: String {
    case tracked, generated, untracked, external
}

struct RepositoryBuildInput {
    let kind: RepositoryBuildInputKind
    let path: String
    let blobOID: String?
}

struct RepositoryExecutedSwiftInvocation {
    let executed: Bool
    let ownerTarget: String
    let module: String
    let compilerExecutable: String
    let compilerVersion: String
    let normalizedArgumentsSHA256: String
    let invocationID: String
    let inventorySHA256: String
    let inputs: [RepositoryBuildInput]?
}

struct RepositoryExecutedBuildInventory {
    static let recognizedFormat = "xcode27-swiftdriver-v1"

    let formatIdentifier: String
    let productCommitOID: String
    let requestedSelection: RepositoryBuildSelection
    let resolvedSelection: RepositoryBuildSelection?
    let buildSucceeded: Bool
    let inventoryComplete: Bool
    let sourceMaterializationProtected: Bool
    let invocations: [RepositoryExecutedSwiftInvocation]
}

/// A pure classification step. Its caller first replays the Profile receipt and
/// obtains source evidence from RepositoryProfileRuntime.verify, then obtains
/// this inventory from a recognized, protected selected-build acquisition path.
enum RepositoryBuildJoin {
    static func evaluate(receipt: RepositoryProfileReceipt,
                         sourceEvidence: RepositorySourceEvidence,
                         selection: RepositoryBuildSelection,
                         inventory: RepositoryExecutedBuildInventory) -> RepositoryBuildEvidence {
        let key = sourceEvidence.mappingKey
        func result(_ status: RepositoryBuildEvidenceStatus, _ reason: String,
                    invocation: RepositoryExecutedSwiftInvocation? = nil) -> RepositoryBuildEvidence {
            let positive = status == .selectedBuildMember
            return RepositoryBuildEvidence(mappingKey: key, status: status,
                scope: positive ? "selectedBuildMember" : nil,
                reason: positive ? nil : reason,
                productCommitOID: receipt.productCommitOID,
                sourcePath: sourceEvidence.locator?.path,
                sourceBlobOID: sourceEvidence.sourceBlobOID,
                requestedSelection: selection,
                resolvedSelection: inventory.resolvedSelection,
                compilerExecutable: positive ? invocation?.compilerExecutable : nil,
                compilerVersion: positive ? invocation?.compilerVersion : nil,
                normalizedArgumentsSHA256: positive ? invocation?.normalizedArgumentsSHA256 : nil,
                invocationID: positive ? invocation?.invocationID : nil,
                inventorySHA256: positive ? invocation?.inventorySHA256 : nil)
        }

        // A changed Product generation takes precedence over a coincidentally
        // unchanged source blob or any other potential build classification.
        guard !receipt.productCommitOID.isEmpty, !inventory.productCommitOID.isEmpty else {
            return result(.unverifiable, "missingCommitIdentity")
        }
        guard receipt.productCommitOID == inventory.productCommitOID else {
            return result(.staleProduct, "commitMismatch")
        }
        guard receipt.receiptFormatVersion == 1, receipt.profileFormatVersion == 2,
              !key.isEmpty, sourceEvidence.status == .verified,
              sourceEvidence.scope == "pinnedSourceDeclaration",
              let path = sourceEvidence.locator?.path, !path.isEmpty,
              let blob = sourceEvidence.sourceBlobOID, !blob.isEmpty else {
            return result(.unverifiable, "sourceNotVerified")
        }
        guard inventory.formatIdentifier == RepositoryExecutedBuildInventory.recognizedFormat else {
            return result(.unverifiable, "unknownInventoryFormat")
        }
        guard inventory.requestedSelection == selection else {
            return result(.unverifiable, "requestedSelectionMismatch")
        }
        guard inventory.sourceMaterializationProtected else {
            return result(.unverifiable, "unprotectedSourceMaterialization")
        }
        guard inventory.buildSucceeded else {
            return result(.unverifiable, "buildNotSuccessful")
        }
        guard inventory.inventoryComplete else {
            return result(.unverifiable, "missingInventory")
        }
        guard !inventory.invocations.isEmpty else {
            return result(.unverifiable, "noExecutedInvocation")
        }

        // Target/module omission is never authority for absence. Multiple
        // matching invocations can be diagnosed as ambiguous, but even zero
        // matches remains unverifiable rather than missingFromSelection.
        guard complete(selection) else {
            if selection.ownerTarget.isEmpty || selection.module.isEmpty {
                let matching = inventory.invocations.filter { invocation in
                    invocation.executed && validIdentity(invocation) && invocation.inputs != nil &&
                    (selection.ownerTarget.isEmpty || invocation.ownerTarget == selection.ownerTarget) &&
                    (selection.module.isEmpty || invocation.module == selection.module) &&
                    (invocation.inputs?.contains { $0.path == path } ?? false)
                }
                if matching.count > 1 { return result(.ambiguous, "moduleOrTargetOmitted") }
            }
            return result(.unverifiable, "incompleteSelection")
        }
        guard let resolved = inventory.resolvedSelection, resolved == selection else {
            return result(.unverifiable, "resolvedSelectionMismatch")
        }
        let candidates = inventory.invocations.filter {
            $0.ownerTarget == selection.ownerTarget && $0.module == selection.module
        }
        guard !candidates.isEmpty else { return result(.unverifiable, "unknownOrUnselectedTarget") }
        guard candidates.count == 1 else { return result(.ambiguous, "multipleSelectedInvocations") }
        let invocation = candidates[0]
        guard invocation.executed else { return result(.unverifiable, "noExecutedInvocation") }
        guard let inputs = invocation.inputs else { return result(.unverifiable, "missingInventory") }
        guard validIdentity(invocation) else {
            return result(.unverifiable, "incompleteInvocationIdentity")
        }
        let matches = inputs.filter { $0.path == path }
        guard !matches.isEmpty else { return result(.missingFromSelection, "sourceAbsent") }
        guard matches.count == 1 else { return result(.ambiguous, "duplicateLogicalPath") }
        let input = matches[0]
        guard input.kind == .tracked else {
            return result(.unverifiable, "nonTrackedSourceInput")
        }
        guard input.blobOID == blob else { return result(.mismatchedSource, "blobMismatch") }
        return result(.selectedBuildMember, "exactTrackedInputObserved", invocation: invocation)
    }

    private static func complete(_ selection: RepositoryBuildSelection) -> Bool {
        let values = [selection.projectPath, selection.scheme, selection.rootTarget,
                      selection.ownerTarget, selection.module, selection.configuration,
                      selection.sdk, selection.destination, selection.architecture]
        guard values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return false
        }
        let path = selection.projectPath
        return !path.hasPrefix("/") && !path.contains("\\") && path.hasSuffix(".xcodeproj") &&
            path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".." && $0 != ".git"
            }
    }

    private static func sha256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) ||
            (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
        }
    }

    private static func validIdentity(_ invocation: RepositoryExecutedSwiftInvocation) -> Bool {
        !invocation.compilerExecutable.isEmpty && !invocation.compilerVersion.isEmpty &&
        !invocation.invocationID.isEmpty &&
        sha256(invocation.normalizedArgumentsSHA256) && sha256(invocation.inventorySHA256)
    }
}
