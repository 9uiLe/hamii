import Foundation
import HamiiCore

/// Infrastructure port used only while the publisher owns worktree coordination.
/// Implementations must not reacquire the source worktree lock.
public protocol MergeIndexPublishing {
    func validateCandidate(at root: URL, document: Document) throws
    func rebuildPublished(at root: URL, document: Document) throws
    func verifyPublished(at root: URL, document: Document) throws
}
