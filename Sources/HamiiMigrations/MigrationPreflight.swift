import Foundation

public enum MigrationClassification: String, Codable {
    case lossless, losslessWithNormalization, potentiallyLossy, manual
}

public struct MigrationPlan: Codable {
    public var sourceDocumentFormatVersion: Int
    public var targetDocumentFormatVersion: Int
    public var classification: MigrationClassification?
    public var state: String
    public var blockers: [String]
    public var canonicalFileCount: Int
    public var originalRepositoryUntouched: Bool
}

public enum MigrationPreflightError: Error, CustomStringConvertible {
    case missingManifest
    case invalidManifest
    public var description: String {
        switch self {
        case .missingManifest: return "hamii.json is missing"
        case .invalidManifest: return "hamii.json has no numeric formatVersion"
        }
    }
}

public enum MigrationPreflight {
    public static let currentDocumentFormatVersion = 1

    public static func plan(repository: URL) throws -> MigrationPlan {
        let manifest = repository.appendingPathComponent("hamii.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { throw MigrationPreflightError.missingManifest }
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any],
              let version = object["formatVersion"] as? Int else { throw MigrationPreflightError.invalidManifest }
        let count = (FileManager.default.enumerator(at: repository, includingPropertiesForKeys: nil)?
            .allObjects as? [URL])?.filter { $0.pathExtension == "json" && !$0.path.contains("/.hamii/") }.count ?? 0
        if FileManager.default.fileExists(atPath: repository.appendingPathComponent(".hamii/transaction.ready").path) {
            return MigrationPlan(sourceDocumentFormatVersion: version, targetDocumentFormatVersion: currentDocumentFormatVersion, classification: nil, state: "pendingCanonicalTransaction", blockers: ["Recover the pending Canonical save before migration"], canonicalFileCount: count, originalRepositoryUntouched: true)
        }
        if version == currentDocumentFormatVersion {
            return MigrationPlan(sourceDocumentFormatVersion: version, targetDocumentFormatVersion: version, classification: nil, state: "current", blockers: [], canonicalFileCount: count, originalRepositoryUntouched: true)
        }
        return MigrationPlan(sourceDocumentFormatVersion: version, targetDocumentFormatVersion: currentDocumentFormatVersion, classification: .manual, state: "noMigrationEdge", blockers: ["No reviewed transformation edge is installed for format \(version)"], canonicalFileCount: count, originalRepositoryUntouched: true)
    }
}
