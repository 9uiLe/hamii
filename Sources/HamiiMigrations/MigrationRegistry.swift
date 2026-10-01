import Foundation

/// Exact bytes supplied by the caller. This type has no repository or Git access.
public struct MigrationFileSet {
    public let files: [String: Data]
    public init(files: [String: Data]) { self.files = files }
}

public struct MigrationDiagnostic: Codable, Equatable, Sendable {
    public let code: String
    public let path: String
    public let entityID: String?
    public let reason: String
    public init(code: String, path: String, entityID: String? = nil, reason: String) {
        self.code = code; self.path = path; self.entityID = entityID; self.reason = reason
    }
    public var blocker: String {
        "\(path)\(entityID.map { " [\($0)]" } ?? ""): \(code): \(reason)"
    }
}

public struct MigrationAnalysis {
    public let sourceVersion: Int
    public let targetVersion: Int
    public let classification: MigrationClassification?
    public let diagnostics: [MigrationDiagnostic]
    public let edgeAvailable: Bool
    public var automaticCandidateEligible: Bool { edgeAvailable && diagnostics.isEmpty }
}

public struct MigrationCandidate {
    public let files: MigrationFileSet
    public let sourceVersion: Int
    public let targetVersion: Int
    public let edgePath: [String]
    public let classification: MigrationClassification?
    public let diagnostics: [MigrationDiagnostic]
    public let resolutionDecisions: [MigrationResolutionDecision]
    public let losses: [MigrationResolutionLoss]
    public let remainingUnresolved: [MigrationResolutionItemID]
}

public enum MigrationEdgeFailure: Error, CustomStringConvertible {
    case invalidInput(String)
    case invalidCatalog(String)
    case invalidReceipt(String)
    case noPath(source: Int, target: Int)
    case requiresResolution([MigrationDiagnostic])

    public var description: String {
        switch self {
        case .invalidInput(let detail): "Invalid Canonical input: \(detail)"
        case .invalidCatalog(let detail): "Invalid migration edge catalog: \(detail)"
        case .invalidReceipt(let detail): "Invalid migration edge receipt: \(detail)"
        case .noPath(let source, let target): "No installed migration edge from \(source) to \(target)"
        case .requiresResolution(let diagnostics): diagnostics.map(\.blocker).joined(separator: "; ")
        }
    }
}

/// Production edge registry. Only Format v1 → Current Format v2 is installed.
public enum MigrationRegistry {
    public static let currentDocumentFormatVersion = 2
    private static let v1ToV2 = MigrationEdge(sourceVersion: 1, targetVersion: 2)
    public static let installedEdges = [v1ToV2]

    public static func route(from source: Int, to target: Int = currentDocumentFormatVersion) throws -> MigrationRoute {
        try MigrationRouteResolver.resolve(from: source, to: target, catalog: installedEdges)
    }

    public static func analyze(_ source: MigrationFileSet, to target: Int = currentDocumentFormatVersion) throws -> MigrationAnalysis {
        let version = try FormatV1.markers(in: source.files)
        let route = try route(from: version, to: target)
        if route.edges.isEmpty {
            return MigrationAnalysis(sourceVersion: version, targetVersion: target,
                                     classification: nil, diagnostics: [], edgeAvailable: false)
        }
        guard route.edges == [v1ToV2] else {
            throw MigrationEdgeFailure.noPath(source: version, target: target)
        }
        let diagnostics = try FormatV1.analyze(source.files)
        return MigrationAnalysis(sourceVersion: version, targetVersion: target,
            classification: diagnostics.isEmpty ? .losslessWithNormalization : .manual,
            diagnostics: diagnostics, edgeAvailable: true)
    }

    public static func transform(_ source: MigrationFileSet, to target: Int = currentDocumentFormatVersion) throws -> MigrationCandidate {
        let analysis = try analyze(source, to: target)
        guard analysis.diagnostics.isEmpty else { throw MigrationEdgeFailure.requiresResolution(analysis.diagnostics) }
        guard analysis.sourceVersion != target else {
            return MigrationCandidate(files: source, sourceVersion: target, targetVersion: target,
                                      edgePath: [], classification: nil, diagnostics: [],
                                      resolutionDecisions: [], losses: [], remainingUnresolved: [])
        }
        let route = try route(from: analysis.sourceVersion, to: target)
        let files = try FormatV1.upgrade(source.files)
        return MigrationCandidate(files: MigrationFileSet(files: files), sourceVersion: analysis.sourceVersion,
                                  targetVersion: target, edgePath: route.edgePath,
                                  classification: .losslessWithNormalization, diagnostics: [],
                                  resolutionDecisions: [], losses: [], remainingUnresolved: [])
    }
}
