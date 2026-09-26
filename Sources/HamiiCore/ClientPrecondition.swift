/// An opaque identifier for the Canonical observation on which a client acts.
/// It is neither a Document revision nor an Index generation.
public struct ClientPrecondition: Codable, Equatable, Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}
