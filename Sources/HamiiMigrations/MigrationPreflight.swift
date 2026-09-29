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
        let manifest = repository.appendingPathComponent("hamii.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { throw MigrationPreflightError.missingManifest }
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any],
              let version = object["formatVersion"] as? Int,
              let versions = object["versions"] as? [String: Any],
              let documentVersion = versions["document"] as? Int,
              version == documentVersion else { throw MigrationPreflightError.invalidManifest }
        let files = try canonicalFiles(at: repository)
        let count = files.count
        if FileManager.default.fileExists(atPath: repository.appendingPathComponent(".hamii/transaction.ready").path) {
            return MigrationPlan(sourceDocumentFormatVersion: version, targetDocumentFormatVersion: currentDocumentFormatVersion, classification: nil, state: "pendingCanonicalTransaction", blockers: ["Recover the pending Canonical save before migration"], canonicalFileCount: count, originalRepositoryUntouched: true)
        }
        if version == currentDocumentFormatVersion {
            return MigrationPlan(sourceDocumentFormatVersion: version, targetDocumentFormatVersion: version, classification: nil, state: "current", blockers: [], canonicalFileCount: count, originalRepositoryUntouched: true)
        }
        if version == 1 {
            do {
                let analysis = try MigrationRegistry.analyze(MigrationFileSet(files: files))
                return MigrationPlan(sourceDocumentFormatVersion: version, targetDocumentFormatVersion: currentDocumentFormatVersion,
                                     classification: analysis.classification,
                                     state: analysis.automaticCandidateEligible ? "migrationAvailable" : "requiresResolution",
                                     blockers: analysis.diagnostics.map(\.blocker),
                                     notes: analysis.automaticCandidateEligible ? ["The transformation edge is available; isolated candidate review and publication are not yet available"] : [],
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

    private static func canonicalFiles(at root: URL) throws -> [String: Data] {
        let manager = FileManager.default
        var files: [String: Data] = [:]
        for name in ["hamii.json", "hamii-agent-profiles.json"] {
            let url = root.appendingPathComponent(name)
            if manager.fileExists(atPath: url.path) { files[name] = try Data(contentsOf: url) }
        }
        for folder in ["pages", "screens", "scopes", "components", "tokens", "assets", "interactions", "motions", "fixtures", "targets"] {
            let directory = root.appendingPathComponent(folder, isDirectory: true)
            guard manager.fileExists(atPath: directory.path) else { continue }
            for url in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
                where url.pathExtension == "json" {
                guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                    throw MigrationEdgeFailure.invalidInput("Canonical symlink is not a migration input: \(url.path)")
                }
                files["\(folder)/\(url.lastPathComponent)"] = try Data(contentsOf: url)
            }
        }
        return files
    }
}
