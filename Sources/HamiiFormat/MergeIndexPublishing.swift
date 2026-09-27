import Foundation
import HamiiCore

/// One complete published materialized view. Its ID identifies the build;
/// sourceCanonicalIdentity identifies the contents used to derive its rows;
/// Source binding records whether the build belongs to a coordinated writer
/// generation. An explicitly unbound build remains eligible for slow Git
/// verification, never for a generation-based witness.
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

public enum IndexSourceGenerationBinding: Equatable {
    case bound(CanonicalGeneration)
    case explicitlyUnbound

    public var serialized: String {
        switch self {
        case .bound(let generation): return "bound:\(generation.serialized)"
        case .explicitlyUnbound: return "unbound"
        }
    }

    public init?(serialized: String) {
        if serialized == "unbound" {
            self = .explicitlyUnbound
        } else if serialized.hasPrefix("bound:"),
                  let generation = CanonicalGeneration(serialized: String(serialized.dropFirst(6))) {
            self = .bound(generation)
        } else {
            return nil
        }
    }
}

public struct IndexGenerationDescriptor: Equatable {
    public let id: IndexGenerationID
    public let sourceCanonicalIdentity: CanonicalSnapshotIdentity
    public let sourceGenerationBinding: IndexSourceGenerationBinding
    public let documentID: EntityID
    public let documentRevision: Int

    public init(id: IndexGenerationID, sourceCanonicalIdentity: CanonicalSnapshotIdentity,
                documentID: EntityID, documentRevision: Int,
                sourceGenerationBinding: IndexSourceGenerationBinding) {
        self.id = id
        self.sourceCanonicalIdentity = sourceCanonicalIdentity
        self.sourceGenerationBinding = sourceGenerationBinding
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
