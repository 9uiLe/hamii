import Darwin
import Foundation

/// Unknown Git lock owners are never removed by hamii recovery.
package enum GitLockGuard {
    package static func requireAbsent(root: URL, sourceRef: String) throws {
        for path in ["index.lock", "\(sourceRef).lock"] {
            let result = try GitCommand.run(at: root, ["rev-parse", "--git-path", path])
            let url = result.hasPrefix("/") ? URL(fileURLWithPath: result) : root.appendingPathComponent(result)
            var info = stat()
            if lstat(url.path, &info) == 0 {
                throw MergePublicationError.gitLockOwnershipUnknown(url.path)
            }
            guard errno == ENOENT else { throw CocoaError(.fileReadUnknown) }
        }
    }
}
