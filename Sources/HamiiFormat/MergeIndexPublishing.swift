import Foundation
import HamiiCore

/// One complete published materialized view. Its ID identifies the build;
/// sourceCanonicalIdentity identifies the contents used to derive its rows.
public struct IndexGenerationID: Hashable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard let uuid = UUID(uuidString: rawValue) else { return nil }
        self.rawValue = uuid.uuidString.lowercased()
    }

    public static func new() -> IndexGenerationID {
        IndexGenerationID(rawValue: UUID().uuidString)!
    }
}

public struct IndexGenerationDescriptor: Equatable {
    public let id: IndexGenerationID
    public let sourceCanonicalIdentity: CanonicalSnapshotIdentity
    public let sourceCanonicalGeneration: CanonicalGeneration?
    public let documentID: EntityID
    public let documentRevision: Int

    public init(id: IndexGenerationID, sourceCanonicalIdentity: CanonicalSnapshotIdentity,
                documentID: EntityID, documentRevision: Int,
                sourceCanonicalGeneration: CanonicalGeneration? = nil) {
        self.id = id
        self.sourceCanonicalIdentity = sourceCanonicalIdentity
        self.sourceCanonicalGeneration = sourceCanonicalGeneration
        self.documentID = documentID
        self.documentRevision = documentRevision
    }
}

/// Infrastructure port used only while the publisher owns worktree coordination.
/// Implementations must not reacquire the source worktree lock.
public protocol MergeIndexPublishing {
    func validateCandidate(at root: URL, snapshot: CanonicalSnapshot) throws
    func rebuildPublished(at root: URL, snapshot: CanonicalSnapshot) throws -> IndexGenerationDescriptor
    func verifyPublished(at root: URL, snapshot: CanonicalSnapshot) throws -> IndexGenerationDescriptor
}
