import Foundation

/// Identity of the current Canonical project data, independent of the index schema.
public struct CanonicalRevision: Equatable {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public protocol CanonicalRevisionCalculating {
    func current(at root: URL) throws -> CanonicalRevision
}
