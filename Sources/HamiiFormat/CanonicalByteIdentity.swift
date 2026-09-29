import CryptoKit
import Foundation

/// Identity of exact captured Canonical JSON bytes. The caller establishes the
/// coordinated snapshot boundary before invoking this pure function.
public enum CanonicalByteIdentity {
    public static func compute(files: [String: Data]) -> CanonicalSnapshotIdentity {
        var hash = SHA256()
        for path in files.keys.sorted() {
            append(Data(path.utf8), to: &hash)
            append(files[path]!, to: &hash)
        }
        return CanonicalSnapshotIdentity(rawValue: hash.finalize().map { String(format: "%02x", $0) }.joined())!
    }

    private static func append(_ value: Data, to hash: inout SHA256) {
        var length = UInt64(value.count).bigEndian
        withUnsafeBytes(of: &length) { hash.update(data: $0) }
        hash.update(data: value)
    }
}
