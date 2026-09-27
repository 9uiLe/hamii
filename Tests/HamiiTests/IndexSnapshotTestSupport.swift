import CryptoKit
import Foundation
import HamiiCore
@testable import HamiiFormat

/// Test-only input for isolated Index experiments that construct Documents in
/// memory. Production callers obtain snapshots from CanonicalRepository.
func testIndexSnapshot(_ document: Document) throws -> CanonicalSnapshot {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let bytes = try encoder.encode(document)
    let identity = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    return CanonicalSnapshot(document: document, identity: CanonicalSnapshotIdentity(rawValue: identity)!)
}
