import CryptoKit
import Foundation
import HamiiApplication
import HamiiCore

public enum BlobError: Error, CustomStringConvertible {
    case integrity(String)
    public var description: String {
        switch self { case .integrity(let path): return "Blob integrity check failed: \(path)" }
    }
}

public struct CanonicalBlobStore: BinaryObjectStore {
    public let root: URL
    public init(root: URL) { self.root = root }

    public func put(_ data: Data) throws -> StoredBlob {
        let hash = Self.hash(data)
        let relativePath = "assets/blobs/\(hash)"
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            guard Self.hash(try Data(contentsOf: url)) == hash else { throw BlobError.integrity(relativePath) }
        } else {
            try data.write(to: url, options: .atomic)
        }
        return StoredBlob(relativePath: relativePath, sha256: hash)
    }

    public func verify(_ asset: Asset) -> Bool {
        guard case .repository(let relativePath) = asset.source,
              relativePath.hasPrefix("assets/blobs/"),
              !relativePath.contains(".."),
              let hash = asset.contentHash,
              let data = try? Data(contentsOf: root.appendingPathComponent(relativePath)) else { return false }
        return Self.hash(data) == hash && relativePath == "assets/blobs/\(hash)"
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
