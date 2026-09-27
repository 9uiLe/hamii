import Foundation
import HamiiCore

/// Identity of the exact canonical JSON paths and bytes observed under the
/// worktree coordination boundary. It is a content identity, not a transition
/// counter or a client precondition.
public struct CanonicalSnapshotIdentity: Hashable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.utf8.count == 64,
              rawValue.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) else { return nil }
        self.rawValue = rawValue
    }
}

/// One coordinated observation used as a single input to derived projections.
/// Only CanonicalRepository can create a production snapshot.
public struct CanonicalSnapshot {
    public let document: Document
    public let identity: CanonicalSnapshotIdentity

    init(document: Document, identity: CanonicalSnapshotIdentity) {
        self.document = document
        self.identity = identity
    }
}
