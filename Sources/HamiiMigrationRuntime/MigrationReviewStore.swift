import Darwin
import Foundation
import HamiiMigrations

enum MigrationReviewStoreError: Error { case invalidID, invalidRecord }

/// Local review evidence is outside Canonical data and is never a substitute
/// for revalidating the immutable Git candidate at publication time.
struct MigrationReviewStore {
    let root: URL

    private func url(_ reviewID: String) throws -> URL {
        guard let uuid = UUID(uuidString: reviewID), uuid.uuidString.lowercased() == reviewID else {
            throw MigrationReviewStoreError.invalidID
        }
        return root.appendingPathComponent(".hamii/migration-reviews/\(reviewID).json")
    }

    func write(_ package: MigrationReviewPackage) throws {
        let destination = try url(package.reviewID)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw MigrationReviewStoreError.invalidRecord }
        try JSONEncoder().encode(package).write(to: destination, options: .atomic)
        try sync(destination)
        try sync(destination.deletingLastPathComponent())
    }

    func load(_ reviewID: String) throws -> MigrationReviewPackage {
        let bytes = try Data(contentsOf: url(reviewID))
        let result = try JSONDecoder().decode(MigrationReviewPackage.self, from: bytes)
        guard result.reviewID == reviewID,
              (result.recordFormatVersion == 1 && result.resolutionAudit == nil ||
               result.recordFormatVersion == 2 && result.resolutionAudit != nil) else {
            throw MigrationReviewStoreError.invalidRecord
        }
        if result.recordFormatVersion == 2 {
            guard let raw = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let audit = raw["resolutionAudit"] as? [String: Any],
                  Set(audit.keys) == ["manifest", "decisions", "losses"],
                  let manifest = audit["manifest"],
                  let strict = try? MigrationResolutionManifest.decodeStrict(
                    JSONSerialization.data(withJSONObject: manifest)),
                  strict == result.resolutionAudit?.manifest else {
                throw MigrationReviewStoreError.invalidRecord
            }
        }
        return result
    }

    func remove(_ reviewID: String) throws {
        let destination = try url(reviewID)
        try FileManager.default.removeItem(at: destination)
        try sync(destination.deletingLastPathComponent())
    }

    private func sync(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
