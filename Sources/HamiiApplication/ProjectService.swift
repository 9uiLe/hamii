import Foundation
import HamiiCore

public protocol ProjectRepository {
    func observe() throws -> ProjectObservation
    func commit(_ document: Document, expected: ProjectObservation) throws -> ProjectObservation
}

/// Verifies that an already validated observation is still the current
/// coordinated Canonical state. It does not create a new observation.
public protocol ProjectObservationVerifying {
    func verifyCurrent(_ expected: ClientPrecondition) throws
}

public struct ProjectObservation {
    public let document: Document
    public let statePrecondition: ClientPrecondition
    public init(document: Document, statePrecondition: ClientPrecondition) {
        self.document = document
        self.statePrecondition = statePrecondition
    }
}

public struct StoredBlob {
    public var relativePath: String
    public var sha256: String
    public init(relativePath: String, sha256: String) {
        self.relativePath = relativePath; self.sha256 = sha256
    }
}

public protocol BinaryObjectStore {
    func put(_ data: Data) throws -> StoredBlob
}

public final class ProjectService {
    private let repository: any ProjectRepository
    public init(repository: any ProjectRepository) { self.repository = repository }

    public func document() throws -> Document { try observe().document }
    public func observe() throws -> ProjectObservation { try repository.observe() }

    public func mutate(_ intent: AuthoringIntent, expectedState: ClientPrecondition, author: Author, agent: AgentHarness? = nil) throws -> MutationResult {
        try mutate([intent], expectedState: expectedState, author: author, agent: agent)
    }

    public func mutate(_ intents: [AuthoringIntent], expectedState: ClientPrecondition, author: Author, agent: AgentHarness? = nil) throws -> MutationResult {
        let observed = try repository.observe()
        guard observed.statePrecondition == expectedState else { throw AuthoringError.staleState }
        let (updated, originalResult) = try MutationEngine.apply(intents, to: observed.document, expectedRevision: observed.document.revision, author: author, agent: agent)
        var result = originalResult
        let current = updated == observed.document ? observed : try repository.commit(updated, expected: observed)
        result.statePrecondition = current.statePrecondition
        return result
    }

    public func availableComponents(for scopeID: EntityID) throws -> [ComponentDefinition] {
        ProjectResourceAvailability.components(in: try repository.observe().document, consumer: scopeID)
    }

    public func componentAvailability(for scopeID: EntityID, expectedState: ClientPrecondition,
                                      includeNonOwned: Bool = true) throws -> [ComponentAvailabilityItem] {
        let observed = try repository.observe()
        guard observed.statePrecondition == expectedState else { throw AuthoringError.staleState }
        guard observed.document.scopes.contains(where: { $0.id == scopeID }) else {
            throw AuthoringError.notFound(scopeID.rawValue)
        }
        return ProjectResourceAvailability.componentAvailability(in: observed.document, consumer: scopeID,
            includeNonOwned: includeNonOwned)
    }

    public func availableAssets(for scopeID: EntityID) throws -> [Asset] {
        ProjectResourceAvailability.assets(in: try repository.observe().document, consumer: scopeID)
    }

    public func availableTokens(for scopeID: EntityID, kind: TokenKind) throws -> [DesignToken] {
        ProjectResourceAvailability.tokens(in: try repository.observe().document, consumer: scopeID, kind: kind)
    }

    public func promotionCandidate(for consumerScopeIDs: [EntityID]) throws -> EntityID? {
        try ScopeEvaluator(repository.observe().document.scopes).leastCommonAncestor(consumerScopeIDs)
    }

    public func importRepositoryAsset(_ data: Data, name: String, scopeID: EntityID, mediaType: String, expectedState: ClientPrecondition, author: Author, agent: AgentHarness? = nil, blobs: any BinaryObjectStore) throws -> MutationResult {
        let current = try repository.observe()
        guard current.statePrecondition == expectedState else { throw AuthoringError.staleState }
        if author == .agent, (agent?.maximumMutations ?? 0) < 1 { throw AuthoringError.mutationLimit }
        guard current.document.scopes.contains(where: { $0.id == scopeID }) else { throw AuthoringError.notFound(scopeID.rawValue) }
        let stored = try blobs.put(data)
        return try mutate(.createRepositoryAsset(name: name, scopeID: scopeID, mediaType: mediaType, path: stored.relativePath, contentHash: stored.sha256), expectedState: expectedState, author: author, agent: agent)
    }
}
