import Darwin
import Foundation

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
        let result = try JSONDecoder().decode(MigrationReviewPackage.self, from: Data(contentsOf: url(reviewID)))
        guard result.recordFormatVersion == 1, result.reviewID == reviewID else {
            throw MigrationReviewStoreError.invalidRecord
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
