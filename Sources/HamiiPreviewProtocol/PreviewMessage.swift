import Foundation
import HamiiCore

public enum BuildBoundary: String, Codable {
    case instantPatch, runtimeReconciliation, componentBuild, fullBuild
}

public struct PreviewPatch: Codable, Equatable {
    public var documentID: EntityID
    public var surfaceID: EntityID
    public var revision: Int
    public var boundary: BuildBoundary
    public var changes: [PreviewChange]
    public init(documentID: EntityID, surfaceID: EntityID, revision: Int, boundary: BuildBoundary, changes: [PreviewChange]) {
        self.documentID = documentID; self.surfaceID = surfaceID; self.revision = revision
        self.boundary = boundary; self.changes = changes
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
    public var accepted: Bool
    public var diagnostics: [Diagnostic]
    public init(revision: Int, accepted: Bool, diagnostics: [Diagnostic] = []) {
        self.revision = revision; self.accepted = accepted; self.diagnostics = diagnostics
    }
}

public enum PreviewRevisionGate {
    public static func accept(_ patch: PreviewPatch, after appliedRevision: Int) -> PreviewAcknowledgement {
        guard patch.revision == appliedRevision + 1 else {
            return PreviewAcknowledgement(revision: appliedRevision, accepted: false, diagnostics: [Diagnostic("preview.revision", "Patch revision must follow the applied revision")])
        }
        guard patch.boundary == .instantPatch || patch.boundary == .runtimeReconciliation else {
            return PreviewAcknowledgement(revision: appliedRevision, accepted: false, diagnostics: [Diagnostic("preview.buildRequired", "This change requires a build")])
        }
        return PreviewAcknowledgement(revision: patch.revision, accepted: true)
    }
}
