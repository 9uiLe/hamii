import CryptoKit
import Foundation
import HamiiApplication
import HamiiCore
import HamiiFormat
import HamiiIntegration

public struct RepositoryProfilePlanResult {
    public let plan: IntegrationPlan
    public let receipt: RepositoryProfileReceipt
    /// Nil for Profile v1; one source assessment per required mapping for v2.
    public let repositoryMappingEvidence: [RepositorySourceEvidence]?

    public init(plan: IntegrationPlan, receipt: RepositoryProfileReceipt,
                repositoryMappingEvidence: [RepositorySourceEvidence]? = nil) {
        self.plan = plan
        self.receipt = receipt
        self.repositoryMappingEvidence = repositoryMappingEvidence
    }
}

/// Stable, machine-readable failure classification for the CLI projection.
public struct RepositoryProfileRuntimeError: Error, Equatable, CustomStringConvertible {
    public let category: String
    public let reason: String

    public init(category: String, reason: String) {
        self.category = category
        self.reason = reason
    }

    public var description: String { "Repository profile \(reason)" }
}

/// Plans from a committed Product profile blob and one exact hamii observation.
/// Product worktree bytes are never used as planning input. The two status checks
/// detect ordinary worktree changes, while the receipt pins the Git objects.
public enum RepositoryProfileRuntime {
    /// Replays the pinned inputs at an explicitly selected Product root.
    /// A clone at the same commit and blob is equivalent to the original root.
    public static func verify(
        receipt: RepositoryProfileReceipt,
        hamiiRoot: URL,
        productRoot: URL
    ) throws -> RepositoryProfilePlanResult {
        guard receipt.receiptFormatVersion == 1, [1, 2].contains(receipt.profileFormatVersion) else {
            throw issue("contract", "invalidReceipt")
        }
        let result = try plan(hamiiRoot: hamiiRoot, productRoot: productRoot,
                              profilePath: receipt.profilePath, screenID: receipt.screenID)
        guard result.receipt.productCommitOID == receipt.productCommitOID,
              result.receipt.profileBlobOID == receipt.profileBlobOID else {
            throw issue("conflict", "staleProduct")
        }
        guard result.receipt.hamiiStatePrecondition == receipt.hamiiStatePrecondition else {
            throw issue("conflict", "staleHamiiObservation")
        }
        guard result.receipt == receipt else { throw issue("contract", "invalidReceipt") }
        return result
    }

    public static func plan(
        hamiiRoot: URL,
        productRoot: URL,
        profilePath: String,
        screenID: EntityID
    ) throws -> RepositoryProfilePlanResult {
        try plan(hamiiRoot: hamiiRoot, productRoot: productRoot, profilePath: profilePath,
                 screenID: screenID, beforeFinalVerification: {})
    }

    // A seam for deterministic stale-source tests. Production always uses the public overload.
    static func plan(
        hamiiRoot: URL,
        productRoot: URL,
        profilePath: String,
        screenID: EntityID,
        beforeFinalVerification: () throws -> Void
    ) throws -> RepositoryProfilePlanResult {
        let repository = CanonicalRepository(root: hamiiRoot)
        let observation: ProjectObservation
        do { observation = try repository.observe() }
        catch { throw issue("storage", "hamiiObservationFailed") }

        guard observation.document.versions.integrationProfile == 1 else {
            throw issue("migrationRequired", "unsupportedDocumentProfileVersion")
        }
        let contract: IntegrationContract
        do { contract = try IntegrationContracts.make(screenID: screenID, document: observation.document) }
        catch { throw issue("contract", "invalidContract") }

        let source = try ProductSource(root: productRoot, profilePath: profilePath)
        let captured = try source.capture()
        let profile: IntegrationProfileDocument
        do { profile = try IntegrationProfileFile.decodeVersioned(data: captured.profileBytes) }
        catch IntegrationProfileFileError.unsupportedVersion(_) {
            throw issue("migrationRequired", "unsupportedProfileVersion")
        } catch {
            throw issue("contract", "invalidProfile")
        }

        let contractBytes: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            contractBytes = try encoder.encode(contract)
        } catch { throw issue("contract", "invalidContract") }
        let plan: IntegrationPlan
        let evidence: [RepositorySourceEvidence]?
        let profileFormatVersion: Int
        switch profile {
        case .v1(let v1):
            plan = IntegrationContracts.plan(contract, profile: v1)
            evidence = nil
            profileFormatVersion = 1
        case .v2(let v2):
            var assessments = IntegrationPlanner.assessments(for: contract, profile: v2.structuralProfile)
            var sourceEvidence: [RepositorySourceEvidence] = []
            for index in assessments.indices {
                let key = assessments[index].key
                let identifier = key.identifier
                let locator = v2.sourceLocators[identifier]
                let item: RepositorySourceEvidence
                switch (assessments[index].status, locator) {
                case (.missing, nil):
                    item = RepositorySourceEvidence(mappingKey: identifier, status: .unverifiable,
                        reason: "missingMappingAuthority")
                case (.empty, nil):
                    item = RepositorySourceEvidence(mappingKey: identifier, status: .unverifiable,
                        reason: "emptyStructuralMapping")
                case (.resolved, nil):
                    item = RepositorySourceEvidence(mappingKey: identifier, status: .unverifiable,
                        reason: "structuralValueWithoutLocator")
                    assessments[index].status = .invalid
                case (.missing, .some(let typedLocator)):
                    if key.kind == .input || key.kind == .event || key.kind == .source {
                        let expectedMember: SwiftDirectMemberKind = key.kind == .event ? .enumCase : .storedProperty
                        if typedLocator.memberKind == expectedMember {
                            item = RepositorySourceValidator.inspect(mappingKey: identifier, locator: typedLocator,
                                productRoot: source.root, commitOID: captured.commitOID)
                        } else {
                            item = RepositorySourceEvidence(mappingKey: identifier, status: .kindMismatch,
                                reason: "mappingKindMemberKindMismatch", locator: typedLocator)
                        }
                    } else {
                        item = RepositorySourceEvidence(mappingKey: identifier, status: .unverifiable,
                            reason: "unsupportedMappingKind", locator: typedLocator)
                    }
                    switch item.status {
                    case .verified:
                        assessments[index].status = .resolved(locatorLabel(typedLocator))
                    case .ambiguous: assessments[index].status = .ambiguous
                    default: assessments[index].status = .invalid
                    }
                case (_, .some(let typedLocator)):
                    item = RepositorySourceEvidence(mappingKey: identifier, status: .unverifiable,
                        reason: "duplicateMappingAuthority", locator: typedLocator)
                    assessments[index].status = .invalid
                case (.invalid, nil), (.ambiguous, nil), (.conflicting, nil):
                    item = RepositorySourceEvidence(mappingKey: identifier, status: .unverifiable,
                        reason: "invalidStructuralMapping")
                    assessments[index].status = .invalid
                }
                sourceEvidence.append(item)
            }
            plan = IntegrationPlanner.plan(contract, assessments: assessments)
            evidence = sourceEvidence.sorted { $0.mappingKey < $1.mappingKey }
            profileFormatVersion = 2
        }

        try beforeFinalVerification()
        try source.verifyUnchanged(captured)
        do { try repository.verifyCurrent(observation.statePrecondition) }
        catch { throw issue("conflict", "staleHamiiObservation") }

        let receipt = RepositoryProfileReceipt(
            productCommitOID: captured.commitOID,
            profilePath: profilePath,
            profileBlobOID: captured.blobOID,
            profileSHA256: digest(captured.profileBytes),
            profileFormatVersion: profileFormatVersion,
            hamiiDocumentID: observation.document.id,
            hamiiDocumentRevision: observation.document.revision,
            hamiiStatePrecondition: observation.statePrecondition,
            screenID: screenID,
            contractSHA256: digest(contractBytes)
        )
        return RepositoryProfilePlanResult(plan: plan, receipt: receipt,
            repositoryMappingEvidence: evidence)
    }
}

private func issue(_ category: String, _ reason: String) -> RepositoryProfileRuntimeError {
    RepositoryProfileRuntimeError(category: category, reason: reason)
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// A planner-only opaque marker; consumers must use typed locator evidence,
/// never parse this string as a Product source expression.
private func locatorLabel(_ locator: SwiftDirectDeclarationLocator) -> String {
    "locator:swiftDirectDeclaration:\(locator.path)#\(locator.enclosingKind.rawValue):\(locator.enclosingName)/\(locator.memberKind.rawValue):\(locator.memberName)"
}

private struct ProductCapture {
    let commitOID: String
    let blobOID: String
    let profileBytes: Data
}

private struct ProductSource {
    let root: URL
    let profilePath: String

    init(root: URL, profilePath: String) throws {
        guard Self.safePath(profilePath) else { throw issue("usage", "invalidProfilePath") }
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw issue("git", "invalidProductRoot")
        }
        let top: String
        do { top = try Self.gitText(canonical, ["rev-parse", "--show-toplevel"]) }
        catch { throw issue("git", "invalidProductRoot") }
        guard URL(fileURLWithPath: top).resolvingSymlinksInPath().standardizedFileURL == canonical else {
            throw issue("git", "invalidProductRoot")
        }
        self.root = canonical
        self.profilePath = profilePath
    }

    func capture() throws -> ProductCapture {
        let preIssue = try cleanIssue()
        let head = try commitOID()
        let blob = try profileBlobOID()
        if let preIssue { throw preIssue }
        let bytes: Data
        do { bytes = try GitCommand.runData(at: root, ["cat-file", "blob", blob]) }
        catch { throw issue("git", "gitFailure") }
        return ProductCapture(commitOID: head, blobOID: blob, profileBytes: bytes)
    }

    func verifyUnchanged(_ captured: ProductCapture) throws {
        try requireClean()
        guard try commitOID() == captured.commitOID,
              try profileBlobOID() == captured.blobOID else {
            throw issue("conflict", "staleProduct")
        }
    }

    private func requireClean() throws {
        if let issue = try cleanIssue() { throw issue }
    }

    private func cleanIssue() throws -> RepositoryProfileRuntimeError? {
        let status: Data
        let flags: Data
        do {
            status = try GitCommand.runData(at: root, ["status", "--porcelain=v2", "--untracked-files=all"])
            // Porcelain can hide assume-unchanged and skip-worktree changes.
            // Reject those index flags before accepting its clean result.
            flags = try GitCommand.runData(at: root, ["ls-files", "-v", "-z"])
        } catch { throw issue("git", "gitFailure") }
        if !status.isEmpty { return issue("conflict", "dirtyProduct") }
        let records = flags.split(separator: 0)
        guard records.allSatisfy({ $0.first == UInt8(ascii: "H") && $0.dropFirst().first == UInt8(ascii: " ") }) else {
            return issue("conflict", "unsafeGitMetadata")
        }
        return nil
    }

    private func commitOID() throws -> String {
        do { return try Self.gitText(root, ["rev-parse", "--verify", "HEAD^{commit}"]) }
        catch { throw issue("git", "gitFailure") }
    }

    private func profileBlobOID() throws -> String {
        let output: Data
        do { output = try GitCommand.runData(at: root, ["ls-tree", "-r", "--full-tree", "-z", "HEAD", "--", profilePath]) }
        catch { throw issue("git", "gitFailure") }
        let records = output.split(separator: 0)
        guard !records.isEmpty else { throw issue("contract", "missingProfile") }
        guard records.count == 1,
              let tab = records[0].firstIndex(of: UInt8(ascii: "\t")),
              let metadata = String(bytes: records[0][..<tab], encoding: .utf8),
              let path = String(bytes: records[0][records[0].index(after: tab)...], encoding: .utf8),
              path == profilePath else { throw issue("contract", "nonRegularProfile") }
        let fields = metadata.split(separator: " ")
        guard fields.count == 3, ["100644", "100755"].contains(String(fields[0])), fields[1] == "blob" else {
            throw issue("contract", "nonRegularProfile")
        }
        return String(fields[2])
    }

    private static func gitText(_ root: URL, _ arguments: [String]) throws -> String {
        let data = try GitCommand.runData(at: root, arguments)
        guard let value = String(data: data, encoding: .utf8), value.hasSuffix("\n") else {
            throw issue("git", "gitFailure")
        }
        return String(value.dropLast())
    }

    private static func safePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0 != ".git" }
    }
}
