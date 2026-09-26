import Foundation
import HamiiCore

public enum BuildBoundary: String, Codable {
    case instantPatch, runtimeReconciliation, componentBuild, fullBuild
}

public struct PreviewPatch: Codable, Equatable {
    public var documentID: EntityID
    public var surfaceID: EntityID
    public var baseRevision: Int
    public var revision: Int
    public var baseState: ClientPrecondition
    public var newState: ClientPrecondition
    public var boundary: BuildBoundary
    public var changes: [PreviewChange]
    public init(documentID: EntityID, surfaceID: EntityID, baseRevision: Int, revision: Int, baseState: ClientPrecondition, newState: ClientPrecondition, boundary: BuildBoundary, changes: [PreviewChange]) {
        self.documentID = documentID; self.surfaceID = surfaceID; self.baseRevision = baseRevision; self.revision = revision
        self.baseState = baseState; self.newState = newState
        self.boundary = boundary; self.changes = changes
    }
}

public struct PreviewSnapshot: Codable {
    public var document: Document
    public var surface: AppSurface
    public var statePrecondition: ClientPrecondition
    public init(document: Document, surface: AppSurface, statePrecondition: ClientPrecondition) {
        self.document = document; self.surface = surface; self.statePrecondition = statePrecondition
    }
}

public struct PreviewChange: Codable, Equatable {
    public var layerID: EntityID
    public var path: String
    public var value: String
    public init(layerID: EntityID, path: String, value: String) {
        self.layerID = layerID; self.path = path; self.value = value
    }
}

public struct PreviewAcknowledgement: Codable, Equatable {
    public var revision: Int
    public var statePrecondition: ClientPrecondition
    public var accepted: Bool
    public var diagnostics: [Diagnostic]
    public init(revision: Int, statePrecondition: ClientPrecondition, accepted: Bool, diagnostics: [Diagnostic] = []) {
        self.revision = revision; self.statePrecondition = statePrecondition; self.accepted = accepted; self.diagnostics = diagnostics
    }
}

public enum PreviewRevisionGate {
    public static func accept(_ patch: PreviewPatch, after appliedRevision: Int, state appliedState: ClientPrecondition) -> PreviewAcknowledgement {
        guard patch.baseState == appliedState, patch.newState != patch.baseState else {
            return PreviewAcknowledgement(revision: appliedRevision, statePrecondition: appliedState, accepted: false, diagnostics: [Diagnostic("preview.state", "Patch base state must match the applied Canonical observation")])
        }
        guard patch.baseRevision == appliedRevision, patch.revision == patch.baseRevision + 1 else {
            return PreviewAcknowledgement(revision: appliedRevision, statePrecondition: appliedState, accepted: false, diagnostics: [Diagnostic("preview.revision", "Patch base revision must match the applied revision and advance once")])
        }
        guard patch.boundary == .instantPatch || patch.boundary == .runtimeReconciliation else {
            return PreviewAcknowledgement(revision: appliedRevision, statePrecondition: appliedState, accepted: false, diagnostics: [Diagnostic("preview.buildRequired", "This change requires a build")])
        }
        return PreviewAcknowledgement(revision: patch.revision, statePrecondition: patch.newState, accepted: true)
    }
}
