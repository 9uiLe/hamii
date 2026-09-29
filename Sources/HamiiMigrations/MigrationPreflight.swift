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
    public var notes: [String] = []
    public var canonicalFileCount: Int
    public var originalRepositoryUntouched: Bool
}

public enum MigrationPreflightError: Error, CustomStringConvertible {
    case missingManifest
    case invalidManifest
    public var description: String {
        switch self {
        case .missingManifest: return "hamii.json is missing"
        case .invalidManifest: return "hamii.json must contain matching numeric formatVersion and versions.document markers"
        }
    }
}

public enum MigrationPreflight {
    public static let currentDocumentFormatVersion = 2

    public static func plan(repository: URL) throws -> MigrationPlan {
        if FileManager.default.fileExists(atPath: repository.appendingPathComponent(".hamii/migration-publication.pending.json").path) {
            return MigrationPlan(sourceDocumentFormatVersion: 0, targetDocumentFormatVersion: currentDocumentFormatVersion,
                                 classification: nil, state: "pendingMigrationPublication",
                                 blockers: ["Recover the pending migration publication before inspecting a Ready project"],
                                 canonicalFileCount: 0, originalRepositoryUntouched: true)
        }
        let manifest = repository.appendingPathComponent("hamii.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { throw MigrationPreflightError.missingManifest }
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any],
              let version = object["formatVersion"] as? Int,
              let versions = object["versions"] as? [String: Any],
              let documentVersion = versions["document"] as? Int,
              version == documentVersion else { throw MigrationPreflightError.invalidManifest }
        let files = try MigrationRepositoryInput.load(from: repository)
        let count = files.files.count
        if ["transaction.prepare", "transaction.ready", "transaction.complete"].contains(where: {
            FileManager.default.fileExists(atPath: repository.appendingPathComponent(".hamii/\($0)").path)
        }) {
            return MigrationPlan(sourceDocumentFormatVersion: version, targetDocumentFormatVersion: currentDocumentFormatVersion, classification: nil, state: "pendingCanonicalTransaction", blockers: ["Recover the pending Canonical save before migration"], canonicalFileCount: count, originalRepositoryUntouched: true)
        }
        if version == currentDocumentFormatVersion {
            return MigrationPlan(sourceDocumentFormatVersion: version, targetDocumentFormatVersion: version, classification: nil, state: "current", blockers: [], canonicalFileCount: count, originalRepositoryUntouched: true)
        }
        if version == 1 {
            do {
                let analysis = try MigrationRegistry.analyze(files)
                return MigrationPlan(sourceDocumentFormatVersion: version, targetDocumentFormatVersion: currentDocumentFormatVersion,
                                     classification: analysis.classification,
                                     state: analysis.automaticCandidateEligible ? "migrationAvailable" : "requiresResolution",
                                     blockers: analysis.diagnostics.map(\.blocker),
                                     notes: analysis.automaticCandidateEligible ? ["The transformation edge is available; prepare an isolated review candidate before explicit publication"] : [],
                                     canonicalFileCount: count,
                                     originalRepositoryUntouched: true)
            } catch {
                return MigrationPlan(sourceDocumentFormatVersion: version, targetDocumentFormatVersion: currentDocumentFormatVersion,
                                     classification: .manual, state: "requiresResolution", blockers: [String(describing: error)],
                                     canonicalFileCount: count, originalRepositoryUntouched: true)
            }
        }
        return MigrationPlan(sourceDocumentFormatVersion: version, targetDocumentFormatVersion: currentDocumentFormatVersion, classification: .manual, state: "noMigrationEdge", blockers: ["No reviewed transformation edge is installed for format \(version)"], canonicalFileCount: count, originalRepositoryUntouched: true)
    }

}
