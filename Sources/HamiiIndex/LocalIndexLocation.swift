import CryptoKit
import Foundation
import HamiiCore

/// Namespaces disposable index data by Document and physical worktree.
public enum LocalIndexLocation {
    public static func url(projectRoot: URL, documentID: EntityID, storageRoot: URL? = nil) -> URL {
        let base = storageRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("hamii/indexes", isDirectory: true)
        let documentKey = digest(documentID.rawValue)
        let worktreeKey = digest(projectRoot.resolvingSymlinksInPath().standardizedFileURL.path)
        return base.appendingPathComponent(documentKey, isDirectory: true)
            .appendingPathComponent(worktreeKey, isDirectory: true)
            .appendingPathComponent("index.sqlite")
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
