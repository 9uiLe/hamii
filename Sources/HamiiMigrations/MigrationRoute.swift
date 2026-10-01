/// A format edge has one stable identity for its adjacent version pair.
public struct MigrationEdge: Codable, Equatable, Sendable {
    public let sourceVersion: Int
    public let targetVersion: Int

    public init(sourceVersion: Int, targetVersion: Int) {
        self.sourceVersion = sourceVersion
        self.targetVersion = targetVersion
    }

    public var id: String { "\(sourceVersion)->\(targetVersion)" }
}

public struct MigrationRoute: Equatable, Sendable {
    public let sourceVersion: Int
    public let targetVersion: Int
    public let edges: [MigrationEdge]

    public var edgePath: [String] { edges.map(\.id) }

    init(sourceVersion: Int, targetVersion: Int, edges: [MigrationEdge]) {
        self.sourceVersion = sourceVersion
        self.targetVersion = targetVersion
        self.edges = edges
    }
}

/// Rejects invalid catalogs before choosing a route. There is no graph search,
/// shortest-path rule, or implicit priority between installed transforms.
enum MigrationRouteResolver {
    static func resolve(from source: Int, to target: Int,
                        catalog: [MigrationEdge]) throws -> MigrationRoute {
        var installed: [Int: MigrationEdge] = [:]
        for edge in catalog {
            guard edge.sourceVersion >= 1,
                  edge.targetVersion > edge.sourceVersion,
                  edge.targetVersion - edge.sourceVersion == 1 else {
                throw MigrationEdgeFailure.invalidCatalog("Only forward adjacent format edges may be installed")
            }
            guard installed.updateValue(edge, forKey: edge.sourceVersion) == nil else {
                throw MigrationEdgeFailure.invalidCatalog("Duplicate installed edge \(edge.id)")
            }
        }
        guard source >= 1, target >= 1, source <= target else {
            throw MigrationEdgeFailure.noPath(source: source, target: target)
        }
        if source == target { return MigrationRoute(sourceVersion: source, targetVersion: target, edges: []) }
        guard target - source <= catalog.count else {
            throw MigrationEdgeFailure.noPath(source: source, target: target)
        }
        var edges: [MigrationEdge] = []
        for version in source..<target {
            guard let edge = installed[version] else {
                throw MigrationEdgeFailure.noPath(source: source, target: target)
            }
            edges.append(edge)
        }
        return MigrationRoute(sourceVersion: source, targetVersion: target, edges: edges)
    }
}
