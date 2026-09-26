import Foundation
import HamiiCore

public protocol ProjectRepository {
    func load() throws -> Document
    func save(_ document: Document, expectedRevision: Int) throws
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

    public func document() throws -> Document { try repository.load() }

    public func mutate(_ intent: AuthoringIntent, expectedRevision: Int, author: Author, agent: AgentHarness? = nil) throws -> MutationResult {
        try mutate([intent], expectedRevision: expectedRevision, author: author, agent: agent)
    }

    public func mutate(_ intents: [AuthoringIntent], expectedRevision: Int, author: Author, agent: AgentHarness? = nil) throws -> MutationResult {
        let current = try repository.load()
        let (updated, result) = try MutationEngine.apply(intents, to: current, expectedRevision: expectedRevision, author: author, agent: agent)
        try repository.save(updated, expectedRevision: expectedRevision)
        return result
    }

    public func availableComponents(for scopeID: EntityID) throws -> [ComponentDefinition] {
        let document = try repository.load()
        let scopes = ScopeEvaluator(document.scopes)
        let definitions = Dictionary(document.components.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return document.components.filter { ComponentAvailability.reason($0, consumer: scopeID, scopes: scopes, definitions: definitions) == nil }
    }

    public func availableAssets(for scopeID: EntityID) throws -> [Asset] {
        let document = try repository.load()
        let scopes = ScopeEvaluator(document.scopes)
        return document.assets.filter { scopes.canUse(owner: $0.ownerScopeID, consumer: scopeID) }
    }

    public func availableTokens(for scopeID: EntityID, kind: TokenKind) throws -> [DesignToken] {
        let document = try repository.load()
        let scopes = ScopeEvaluator(document.scopes)
        return document.tokens.filter { $0.kind == kind && scopes.canUse(owner: $0.ownerScopeID, consumer: scopeID) }
    }

    public func promotionCandidate(for consumerScopeIDs: [EntityID]) throws -> EntityID? {
        try ScopeEvaluator(repository.load().scopes).leastCommonAncestor(consumerScopeIDs)
    }

    public func importRepositoryAsset(_ data: Data, name: String, scopeID: EntityID, mediaType: String, expectedRevision: Int, author: Author, agent: AgentHarness? = nil, blobs: any BinaryObjectStore) throws -> MutationResult {
        let current = try repository.load()
        guard current.revision == expectedRevision else {
            throw AuthoringError.staleRevision(expected: expectedRevision, actual: current.revision)
        }
        if author == .agent, (agent?.maximumMutations ?? 0) < 1 { throw AuthoringError.mutationLimit }
        guard current.scopes.contains(where: { $0.id == scopeID }) else { throw AuthoringError.notFound(scopeID.rawValue) }
        let stored = try blobs.put(data)
        return try mutate(.createRepositoryAsset(name: name, scopeID: scopeID, mediaType: mediaType, path: stored.relativePath, contentHash: stored.sha256), expectedRevision: expectedRevision, author: author, agent: agent)
    }
}
