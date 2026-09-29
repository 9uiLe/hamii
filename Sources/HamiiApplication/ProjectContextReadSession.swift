import Foundation
import HamiiCore

public enum ProjectContextSessionError: Error, Equatable {
    case invalidated
}

public struct ProjectContextSessionStart {
    public let session: ProjectContextReadSession
    public let initialSummary: ContextResponse<ContextProjectSummary>
}

/// Process-local reuse of one fully validated observation. The verifier owns
/// the coordinated filesystem boundary; this object holds no worktree lock
/// between calls and cannot authorize mutations.
public final class ProjectContextReadSession {
    private let observed: ProjectObservation
    private let verifier: any ProjectObservationVerifying
    private let lock = NSLock()
    private var active = true

    private init(observed: ProjectObservation, verifier: any ProjectObservationVerifying) {
        self.observed = observed
        self.verifier = verifier
    }

    /// The initial summary is projected immediately from the single initial
    /// observation, before the session can be returned to a caller.
    public static func start<Repository: ProjectRepository & ProjectObservationVerifying>(
        repository: Repository, selection: ContextSelection? = nil
    ) throws -> ProjectContextSessionStart {
        let observed = try repository.observe()
        let summary = try ProjectContextProjection.projectSummary(observed, selection: selection)
        return ProjectContextSessionStart(
            session: ProjectContextReadSession(observed: observed, verifier: repository),
            initialSummary: summary)
    }

    private func withVerified<Result>(_ project: (ProjectObservation) throws -> Result) throws -> Result {
        lock.lock()
        defer { lock.unlock() }
        guard active else { throw ProjectContextSessionError.invalidated }
        do {
            try verifier.verifyCurrent(observed.statePrecondition)
        } catch {
            active = false
            throw error
        }
        return try project(observed)
    }

    public func layerDetail(screenID: EntityID, layerID: EntityID) throws -> ContextResponse<ContextLayerDetail> {
        try withVerified { try ProjectContextProjection.layerDetail($0, screenID: screenID, layerID: layerID) }
    }

    public func resources(consumerScopeID: EntityID, kind: ContextResourceKind,
                          matching: String? = nil, limit: Int = 32) throws -> ContextResponse<ContextResourceList> {
        try withVerified {
            try ProjectContextProjection.resources($0, consumerScopeID: consumerScopeID,
                kind: kind, matching: matching, limit: limit)
        }
    }

    public func componentDetail(componentID: EntityID, consumerScopeID: EntityID) throws -> ContextResponse<ContextComponentDetail> {
        try withVerified {
            try ProjectContextProjection.componentDetail($0, componentID: componentID,
                consumerScopeID: consumerScopeID)
        }
    }

    public func tokenDetail(tokenID: EntityID, consumerScopeID: EntityID) throws -> ContextResponse<ContextTokenDetail> {
        try withVerified {
            try ProjectContextProjection.tokenDetail($0, tokenID: tokenID,
                consumerScopeID: consumerScopeID)
        }
    }
}
